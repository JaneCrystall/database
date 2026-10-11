alter table public.kb_jobs
  add column if not exists next_retry_at timestamptz;

create index if not exists kb_jobs_retry_ready_idx
on public.kb_jobs (stage, priority, next_retry_at, created_at)
where status in ('queued', 'failed');

create index if not exists kb_jobs_dead_status_idx
on public.kb_jobs (stage, updated_at desc)
where status = 'dead';

create or replace function public.kb_job_retry_backoff(p_attempt_count integer)
returns interval
language sql
immutable
as $$
  select case
    when coalesce(p_attempt_count, 0) <= 1 then interval '1 minute'
    when p_attempt_count = 2 then interval '5 minutes'
    when p_attempt_count = 3 then interval '15 minutes'
    else interval '1 hour'
  end
$$;

create or replace function public.start_job_from_pgmq_message(
  p_job_id uuid,
  p_queue text,
  p_msg_id bigint,
  p_worker_id text,
  p_lock_seconds integer default 1800
)
returns table (
  job_id uuid,
  document_id uuid,
  document_version integer,
  stage public.kb_job_stage,
  status public.kb_job_status,
  payload_json jsonb,
  raw_uri text,
  file_ext text,
  file_size bigint,
  sha256 text,
  collection_path text
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_job record;
  v_document_status public.kb_document_status;
begin
  if p_worker_id is null or p_worker_id = '' then
    raise exception 'worker_id is required';
  end if;

  if p_lock_seconds is null or p_lock_seconds <= 0 then
    raise exception 'lock_seconds must be positive';
  end if;

  select
    j.*,
    d.deleted_at,
    d.status as current_document_status,
    d.document_version as current_document_version,
    d.raw_uri,
    d.file_ext,
    d.file_size,
    d.sha256,
    c.path as collection_path
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  join public.kb_collections c on c.id = d.primary_collection_id
  where j.id = p_job_id
  for update of j, d;

  if not found then
    return;
  end if;

  if public.kb_queue_for_stage(v_job.stage) <> p_queue then
    raise exception 'job % stage % does not match queue %', p_job_id, v_job.stage, p_queue;
  end if;

  if v_job.stage in (
    'parse'::public.kb_job_stage,
    's3_ready'::public.kb_job_stage,
    'index'::public.kb_job_stage
  ) and v_job.deleted_at is not null then
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        next_retry_at = null,
        finished_at = now(),
        last_error = 'document was deleted before claim'
    where id = p_job_id;
    return;
  end if;

  if v_job.document_version <> v_job.current_document_version then
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        next_retry_at = null,
        finished_at = now(),
        last_error = 'document version changed before claim'
    where id = p_job_id;
    return;
  end if;

  if not (
    v_job.status in ('queued', 'failed')
    or (v_job.status = 'running' and v_job.locked_until < now())
  ) then
    return;
  end if;

  if v_job.status = 'failed'
     and v_job.next_retry_at is not null
     and v_job.next_retry_at > now() then
    return;
  end if;

  if v_job.attempt_count >= v_job.max_attempts then
    update public.kb_jobs
    set status = 'dead',
        locked_by = null,
        locked_until = null,
        next_retry_at = null,
        finished_at = now(),
        last_error = coalesce(last_error, 'max attempts reached before claim')
    where id = p_job_id;

    update public.kb_documents
    set status = case v_job.stage
          when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
          else 'failed'::public.kb_document_status
        end,
        last_error = coalesce(v_job.last_error, 'max attempts reached before claim'),
        last_error_stage = v_job.stage
    where id = v_job.document_id
      and document_version = v_job.document_version;
    return;
  end if;

  v_document_status := case v_job.stage
    when 'parse'::public.kb_job_stage then 'parsing'::public.kb_document_status
    when 'index'::public.kb_job_stage then 'indexing'::public.kb_document_status
    when 'delete'::public.kb_job_stage then 'deleting'::public.kb_document_status
    else v_job.current_document_status
  end;

  update public.kb_jobs
  set status = 'running',
      attempt_count = attempt_count + 1,
      locked_by = p_worker_id,
      locked_until = now() + make_interval(secs => p_lock_seconds),
      next_retry_at = null,
      pgmq_queue = p_queue,
      pgmq_msg_id = p_msg_id,
      last_error = null,
      started_at = coalesce(started_at, now())
  where id = p_job_id;

  update public.kb_documents
  set status = v_document_status,
      last_error = null,
      last_error_stage = null
  where id = v_job.document_id
    and (
      v_job.stage = 'delete'::public.kb_job_stage
      or deleted_at is null
    );

  return query
  select
    j.id,
    j.document_id,
    j.document_version,
    j.stage,
    j.status,
    j.payload_json,
    d.raw_uri,
    d.file_ext,
    d.file_size,
    d.sha256,
    c.path
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  join public.kb_collections c on c.id = d.primary_collection_id
  where j.id = p_job_id;
end;
$$;

create or replace function public.fail_job(
  p_job_id uuid,
  p_worker_id text,
  p_retryable boolean,
  p_error text,
  p_error_stage public.kb_job_stage default null
)
returns table (job_id uuid, job_status public.kb_job_status, document_status public.kb_document_status)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_job record;
  v_job_status public.kb_job_status;
  v_document_status public.kb_document_status;
  v_next_retry_at timestamptz;
  v_has_parse_local_ready boolean;
begin
  select *
  into v_job
  from public.kb_jobs
  where id = p_job_id
    and status = 'running'
    and locked_by = p_worker_id
  for update;

  if not found then
    return;
  end if;

  select (
    processed_manifest_local_uri is not null
    and processed_artifact_uuid is not null
  )
  into v_has_parse_local_ready
  from public.kb_documents
  where id = v_job.document_id
    and document_version = v_job.document_version;

  if p_retryable and v_job.attempt_count < v_job.max_attempts then
    v_job_status := 'failed';
    v_next_retry_at := now() + public.kb_job_retry_backoff(v_job.attempt_count);
    v_document_status := case
      when v_job.stage = 'parse'::public.kb_job_stage and v_has_parse_local_ready then
        's3_ready_check_failed'::public.kb_document_status
      when v_job.stage = 'parse'::public.kb_job_stage then
        'parse_queued'::public.kb_document_status
      when v_job.stage = 's3_ready'::public.kb_job_stage then
        's3_ready_check_failed'::public.kb_document_status
      when v_job.stage = 'index'::public.kb_job_stage then
        'index_queued'::public.kb_document_status
      when v_job.stage = 'delete'::public.kb_job_stage then
        'delete_queued'::public.kb_document_status
      else
        'failed'::public.kb_document_status
    end;
  else
    v_job_status := 'dead';
    v_next_retry_at := null;
    v_document_status := case v_job.stage
      when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
      else 'failed'::public.kb_document_status
    end;
  end if;

  update public.kb_jobs
  set status = v_job_status,
      locked_by = null,
      locked_until = null,
      next_retry_at = v_next_retry_at,
      finished_at = case when v_job_status = 'dead' then now() else finished_at end,
      last_error = p_error
  where id = p_job_id;

  update public.kb_documents
  set status = v_document_status,
      last_error = p_error,
      last_error_stage = coalesce(p_error_stage, v_job.stage)
  where id = v_job.document_id
    and document_version = v_job.document_version;

  return query select p_job_id, v_job_status, v_document_status;
end;
$$;

create or replace function public.list_kb_dead_letter_jobs(
  p_actor_id uuid,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table (
  job_id uuid,
  document_id uuid,
  document_version integer,
  document_filename text,
  collection_path text,
  stage public.kb_job_stage,
  last_error text,
  attempt_count integer,
  max_attempts integer,
  finished_at timestamptz,
  updated_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  return query
  with scoped as (
    select
      j.id,
      j.document_id,
      j.document_version,
      d.original_filename,
      c.path as collection_path,
      j.stage,
      j.last_error,
      j.attempt_count,
      j.max_attempts,
      j.finished_at,
      j.updated_at,
      count(*) over() as total_count
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    join public.kb_collections c on c.id = d.primary_collection_id
    where j.status = 'dead'::public.kb_job_status
      and public.kb_actor_can_access_admin_document(p_actor_id, d.id)
  )
  select
    scoped.id,
    scoped.document_id,
    scoped.document_version,
    scoped.original_filename,
    scoped.collection_path,
    scoped.stage,
    scoped.last_error,
    scoped.attempt_count,
    scoped.max_attempts,
    scoped.finished_at,
    scoped.updated_at,
    scoped.total_count
  from scoped
  order by scoped.updated_at desc, scoped.id
  limit v_limit
  offset v_offset;
end;
$$;

drop function if exists public.list_kb_admin_jobs(uuid, jsonb, integer, integer, text, text);

create or replace function public.list_kb_admin_jobs(
  p_actor_id uuid,
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 25,
  p_offset integer default 0,
  p_sort text default 'updated_at',
  p_dir text default 'desc'
)
returns table (
  id uuid,
  document_id uuid,
  document_version integer,
  document_filename text,
  collection_path text,
  stage public.kb_job_stage,
  status public.kb_job_status,
  priority integer,
  attempt_count integer,
  max_attempts integer,
  locked_by text,
  locked_until timestamptz,
  next_retry_at timestamptz,
  pgmq_queue text,
  pgmq_msg_id bigint,
  last_error text,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_sort text := coalesce(nullif(p_sort, ''), 'updated_at');
  v_dir text := lower(coalesce(nullif(p_dir, ''), 'desc'));
  v_failed_only boolean := coalesce((v_filters->>'failed_only')::boolean, false);
  v_stale_running boolean := coalesce((v_filters->>'stale_running')::boolean, false);
begin
  if jsonb_typeof(v_filters) <> 'object' then
    raise exception 'filters must be a JSON object';
  end if;

  if v_dir not in ('asc', 'desc') then
    raise exception 'sort direction must be asc or desc';
  end if;

  return query
  with scoped as (
    select
      j.*,
      d.original_filename as document_filename,
      c.path as collection_path,
      count(*) over() as total_count
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    join public.kb_collections c on c.id = d.primary_collection_id
    where public.kb_actor_can_access_admin_document(p_actor_id, d.id)
      and (
        not (v_filters ? 'stage')
        or j.stage = (v_filters->>'stage')::public.kb_job_stage
      )
      and (
        not (v_filters ? 'status')
        or j.status = (v_filters->>'status')::public.kb_job_status
      )
      and (
        not (v_filters ? 'document_id')
        or j.document_id = (v_filters->>'document_id')::uuid
      )
      and (
        not (v_filters ? 'locked_by')
        or j.locked_by = v_filters->>'locked_by'
      )
      and (
        not v_failed_only
        or j.status in ('failed'::public.kb_job_status, 'dead'::public.kb_job_status)
      )
      and (
        not v_stale_running
        or (j.status = 'running'::public.kb_job_status and j.locked_until < now())
      )
  )
  select
    scoped.id,
    scoped.document_id,
    scoped.document_version,
    scoped.document_filename,
    scoped.collection_path,
    scoped.stage,
    scoped.status,
    scoped.priority,
    scoped.attempt_count,
    scoped.max_attempts,
    scoped.locked_by,
    scoped.locked_until,
    scoped.next_retry_at,
    scoped.pgmq_queue,
    scoped.pgmq_msg_id,
    scoped.last_error,
    scoped.created_at,
    scoped.started_at,
    scoped.finished_at,
    scoped.updated_at,
    scoped.total_count
  from scoped
  order by
    case when v_sort = 'created_at' and v_dir = 'asc' then scoped.created_at end asc nulls last,
    case when v_sort = 'created_at' and v_dir = 'desc' then scoped.created_at end desc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'asc' then scoped.updated_at end asc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'desc' then scoped.updated_at end desc nulls last,
    case when v_sort = 'locked_until' and v_dir = 'asc' then scoped.locked_until end asc nulls last,
    case when v_sort = 'locked_until' and v_dir = 'desc' then scoped.locked_until end desc nulls last,
    case when v_sort = 'next_retry_at' and v_dir = 'asc' then scoped.next_retry_at end asc nulls last,
    case when v_sort = 'next_retry_at' and v_dir = 'desc' then scoped.next_retry_at end desc nulls last,
    case when v_sort = 'attempt_count' and v_dir = 'asc' then scoped.attempt_count end asc nulls last,
    case when v_sort = 'attempt_count' and v_dir = 'desc' then scoped.attempt_count end desc nulls last,
    scoped.updated_at desc,
    scoped.id
  limit v_limit
  offset v_offset;
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'kb_job_retry_backoff',
        'start_job_from_pgmq_message',
        'fail_job',
        'list_kb_dead_letter_jobs',
        'list_kb_admin_jobs'
      )
  loop
    execute format('revoke all on function %I.%I(%s) from public', r.nspname, r.proname, r.args);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %I.%I(%s) from anon', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on function %I.%I(%s) from authenticated', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %I.%I(%s) to service_role', r.nspname, r.proname, r.args);
    end if;
  end loop;
end $$;
