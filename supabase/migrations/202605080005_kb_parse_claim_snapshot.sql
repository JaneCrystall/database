drop function if exists public.start_job_from_pgmq_message(uuid, text, bigint, text, integer);

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

  if v_job.attempt_count >= v_job.max_attempts then
    update public.kb_jobs
    set status = 'dead',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = coalesce(last_error, 'max attempts reached before claim')
    where id = p_job_id;
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

do $$
declare
  r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'start_job_from_pgmq_message'
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
