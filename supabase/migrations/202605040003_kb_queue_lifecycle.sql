create extension if not exists pgmq;

alter type kb_document_status add value if not exists 'parsed_local';
alter type kb_document_status add value if not exists 's3_sync_pending';
alter type kb_document_status add value if not exists 's3_ready_check_failed';
alter type kb_document_status add value if not exists 'processed_s3_ready';

alter table public.kb_documents
  add column if not exists processed_manifest_hash text,
  add column if not exists processed_artifact_uuid uuid,
  add column if not exists processed_s3_ready_at timestamptz;

do $$
begin
  if not exists (select 1 from pgmq.meta where queue_name = 'kb_parse_queue') then
    perform pgmq.create('kb_parse_queue');
  end if;

  if not exists (select 1 from pgmq.meta where queue_name = 'kb_index_queue') then
    perform pgmq.create('kb_index_queue');
  end if;

  if not exists (select 1 from pgmq.meta where queue_name = 'kb_delete_queue') then
    perform pgmq.create('kb_delete_queue');
  end if;
end $$;

alter table if exists pgmq.q_kb_parse_queue enable row level security;
alter table if exists pgmq.a_kb_parse_queue enable row level security;
alter table if exists pgmq.q_kb_index_queue enable row level security;
alter table if exists pgmq.a_kb_index_queue enable row level security;
alter table if exists pgmq.q_kb_delete_queue enable row level security;
alter table if exists pgmq.a_kb_delete_queue enable row level security;

create or replace function public.kb_queue_for_stage(p_stage public.kb_job_stage)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select case p_stage
    when 'parse'::public.kb_job_stage then 'kb_parse_queue'
    when 'index'::public.kb_job_stage then 'kb_index_queue'
    when 'delete'::public.kb_job_stage then 'kb_delete_queue'
    when 'archive_raw'::public.kb_job_stage then 'kb_archive_queue'
  end
$$;

create or replace function public.mark_raw_ready_and_enqueue_parse(
  p_document_id uuid,
  p_raw_uri text,
  p_file_size bigint,
  p_sha256 text,
  p_actor_id uuid default null,
  p_request_id text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns table (document_id uuid, job_id uuid, msg_id bigint)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document_version integer;
  v_job_id uuid;
  v_msg_id bigint;
begin
  if p_payload_json is null or jsonb_typeof(p_payload_json) <> 'object' then
    raise exception 'payload_json must be a JSON object';
  end if;

  update public.kb_documents d
  set status = 'parse_queued',
      raw_uri = p_raw_uri,
      file_size = p_file_size,
      sha256 = p_sha256,
      last_error = null,
      last_error_stage = null
  where d.id = p_document_id
    and d.deleted_at is null
    and d.status in ('received', 'raw_stored', 'failed')
  returning d.document_version
  into v_document_version;

  if not found then
    raise exception 'document % is not ready for parse enqueue', p_document_id;
  end if;

  insert into public.kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    pgmq_queue,
    payload_json
  )
  values (
    p_document_id,
    v_document_version,
    'parse',
    'queued',
    'kb_parse_queue',
    p_payload_json
  )
  on conflict (document_id, document_version, stage)
  where status in ('queued', 'running', 'failed')
  do update
  set updated_at = now()
  returning id
  into v_job_id;

  select sent.msg_id
  into v_msg_id
  from pgmq.send(
    'kb_parse_queue',
    jsonb_build_object('job_id', v_job_id::text)
  ) as sent(msg_id)
  limit 1;

  update public.kb_jobs
  set pgmq_queue = 'kb_parse_queue',
      pgmq_msg_id = v_msg_id
  where id = v_job_id;

  if p_actor_id is not null then
    insert into public.kb_audit_events (
      actor_id,
      action,
      document_id,
      request_id,
      payload_json
    )
    values (
      p_actor_id,
      'kb.parse_enqueued',
      p_document_id,
      p_request_id,
      jsonb_build_object('job_id', v_job_id, 'msg_id', v_msg_id)
    );
  end if;

  return query select p_document_id, v_job_id, v_msg_id;
end;
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
  payload_json jsonb
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

  select j.*, d.deleted_at, d.status as current_document_status
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = p_job_id
  for update of j, d;

  if not found then
    return;
  end if;

  if public.kb_queue_for_stage(v_job.stage) <> p_queue then
    raise exception 'job % stage % does not match queue %', p_job_id, v_job.stage, p_queue;
  end if;

  if v_job.stage in ('parse', 'index') and v_job.deleted_at is not null then
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = 'document was deleted before claim'
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
      v_job.stage = 'delete'
      or deleted_at is null
    );

  return query
  select
    j.id,
    j.document_id,
    j.document_version,
    j.stage,
    j.status,
    j.payload_json
  from public.kb_jobs j
  where j.id = p_job_id;
end;
$$;

create or replace function public.heartbeat_job(
  p_job_id uuid,
  p_worker_id text,
  p_lock_seconds integer default 1800,
  p_vt_seconds integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_queue text;
  v_msg_id bigint;
begin
  if p_lock_seconds is null or p_lock_seconds <= 0 then
    raise exception 'lock_seconds must be positive';
  end if;

  update public.kb_jobs
  set locked_until = now() + make_interval(secs => p_lock_seconds)
  where id = p_job_id
    and status = 'running'
    and locked_by = p_worker_id
  returning pgmq_queue, pgmq_msg_id
  into v_queue, v_msg_id;

  if not found then
    return false;
  end if;

  if p_vt_seconds is not null and v_queue is not null and v_msg_id is not null then
    perform *
    from pgmq.set_vt(v_queue, v_msg_id, p_vt_seconds);
  end if;

  return true;
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

  if p_retryable and v_job.attempt_count < v_job.max_attempts then
    v_job_status := 'failed';
    v_document_status := case v_job.stage
      when 'parse'::public.kb_job_stage then 'parse_queued'::public.kb_document_status
      when 'index'::public.kb_job_stage then 'index_queued'::public.kb_document_status
      when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
      else 'failed'::public.kb_document_status
    end;
  else
    v_job_status := 'dead';
    v_document_status := case v_job.stage
      when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
      else 'failed'::public.kb_document_status
    end;
  end if;

  update public.kb_jobs
  set status = v_job_status,
      locked_by = null,
      locked_until = null,
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

create or replace function public.mark_processed_s3_ready(
  p_job_id uuid,
  p_document_id uuid,
  p_document_version integer,
  p_manifest_s3_key text,
  p_manifest_hash text default null,
  p_artifact_uuid uuid default null,
  p_manifest_local_uri text default null,
  p_chunk_count integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
begin
  update public.kb_jobs j
  set status = 'succeeded',
      locked_by = null,
      locked_until = null,
      finished_at = now(),
      last_error = null
  from public.kb_documents d
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
    and j.stage = 'parse'
    and j.status = 'running'
    and d.id = j.document_id
    and d.document_version = j.document_version
    and d.deleted_at is null;

  if not found then
    return false;
  end if;

  update public.kb_documents
  set status = 'processed_s3_ready',
      processed_manifest_s3_key = p_manifest_s3_key,
      processed_manifest_hash = p_manifest_hash,
      processed_artifact_uuid = p_artifact_uuid,
      processed_manifest_local_uri = coalesce(p_manifest_local_uri, processed_manifest_local_uri),
      processed_s3_ready_at = now(),
      chunk_count = coalesce(p_chunk_count, chunk_count),
      parse_time = coalesce(parse_time, now()),
      last_error = null,
      last_error_stage = null
  where id = p_document_id
    and document_version = p_document_version
    and deleted_at is null;

  return found;
end;
$$;

create or replace function public.enqueue_index_from_processed_s3_ready(
  p_document_id uuid,
  p_actor_id uuid default null,
  p_request_id text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns table (document_id uuid, job_id uuid, msg_id bigint)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document_version integer;
  v_job_id uuid;
  v_msg_id bigint;
begin
  if p_payload_json is null or jsonb_typeof(p_payload_json) <> 'object' then
    raise exception 'payload_json must be a JSON object';
  end if;

  update public.kb_documents d
  set status = 'index_queued',
      last_error = null,
      last_error_stage = null
  where d.id = p_document_id
    and d.deleted_at is null
    and d.status in ('processed_s3_ready', 'completed')
    and d.processed_manifest_s3_key is not null
  returning d.document_version
  into v_document_version;

  if not found then
    raise exception 'document % is not ready for index enqueue', p_document_id;
  end if;

  insert into public.kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    pgmq_queue,
    payload_json
  )
  values (
    p_document_id,
    v_document_version,
    'index',
    'queued',
    'kb_index_queue',
    p_payload_json
  )
  on conflict (document_id, document_version, stage)
  where status in ('queued', 'running', 'failed')
  do update
  set updated_at = now()
  returning id
  into v_job_id;

  select sent.msg_id
  into v_msg_id
  from pgmq.send(
    'kb_index_queue',
    jsonb_build_object('job_id', v_job_id::text)
  ) as sent(msg_id)
  limit 1;

  update public.kb_jobs
  set pgmq_queue = 'kb_index_queue',
      pgmq_msg_id = v_msg_id
  where id = v_job_id;

  if p_actor_id is not null then
    insert into public.kb_audit_events (
      actor_id,
      action,
      document_id,
      request_id,
      payload_json
    )
    values (
      p_actor_id,
      'kb.index_enqueued',
      p_document_id,
      p_request_id,
      jsonb_build_object('job_id', v_job_id, 'msg_id', v_msg_id)
    );
  end if;

  return query select p_document_id, v_job_id, v_msg_id;
end;
$$;

create or replace function public.complete_index(
  p_job_id uuid,
  p_worker_id text,
  p_document_id uuid,
  p_document_version integer,
  p_opensearch_indexed boolean default true,
  p_pinecone_indexed boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
begin
  update public.kb_jobs j
  set status = 'succeeded',
      locked_by = null,
      locked_until = null,
      finished_at = now(),
      last_error = null
  from public.kb_documents d
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
    and j.stage = 'index'
    and j.status = 'running'
    and j.locked_by = p_worker_id
    and d.id = j.document_id
    and d.document_version = j.document_version
    and d.deleted_at is null;

  if not found then
    return false;
  end if;

  update public.kb_documents
  set status = 'completed',
      index_time = now(),
      opensearch_indexed = p_opensearch_indexed,
      pinecone_indexed = p_pinecone_indexed,
      last_error = null,
      last_error_stage = null
  where id = p_document_id
    and document_version = p_document_version
    and deleted_at is null;

  return found;
end;
$$;

create or replace function public.archive_job_message(
  p_job_id uuid,
  p_worker_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_queue text;
  v_msg_id bigint;
  v_archived boolean;
begin
  select pgmq_queue, pgmq_msg_id
  into v_queue, v_msg_id
  from public.kb_jobs
  where id = p_job_id
    and status in ('succeeded', 'dead', 'cancelled')
    and (
      p_worker_id is null
      or locked_by is null
      or locked_by = p_worker_id
    );

  if not found or v_queue is null or v_msg_id is null then
    return false;
  end if;

  select pgmq.archive(v_queue, v_msg_id)
  into v_archived;

  return coalesce(v_archived, false);
end;
$$;

create or replace function public.request_delete(
  p_document_id uuid,
  p_actor_id uuid,
  p_reason text default null,
  p_request_id text default null
)
returns table (document_id uuid, job_id uuid, msg_id bigint, delete_generation integer)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_job_id uuid;
  v_msg_id bigint;
begin
  update public.kb_documents d
  set status = 'delete_queued',
      deleted_at = coalesce(deleted_at, now()),
      deleted_by = coalesce(deleted_by, p_actor_id),
      delete_requested_at = coalesce(delete_requested_at, now()),
      delete_generation = case
        when deleted_at is null then delete_generation + 1
        else delete_generation
      end,
      last_error = null,
      last_error_stage = null
  where d.id = p_document_id
    and d.status <> 'deleted'
  returning d.id, d.document_version, d.delete_generation
  into v_document;

  if not found then
    raise exception 'document % is not available for delete', p_document_id;
  end if;

  update public.kb_jobs
  set status = 'cancelled',
      locked_by = null,
      locked_until = null,
      finished_at = now(),
      last_error = 'cancelled by delete request'
  where document_id = p_document_id
    and stage in ('parse', 'index')
    and status in ('queued', 'running', 'failed');

  insert into public.kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    pgmq_queue,
    payload_json
  )
  values (
    p_document_id,
    v_document.document_version,
    'delete',
    'queued',
    'kb_delete_queue',
    jsonb_build_object('reason', p_reason, 'delete_generation', v_document.delete_generation)
  )
  on conflict (document_id, document_version, stage)
  where status in ('queued', 'running', 'failed')
  do update
  set updated_at = now()
  returning id
  into v_job_id;

  select sent.msg_id
  into v_msg_id
  from pgmq.send(
    'kb_delete_queue',
    jsonb_build_object('job_id', v_job_id::text)
  ) as sent(msg_id)
  limit 1;

  update public.kb_jobs
  set pgmq_queue = 'kb_delete_queue',
      pgmq_msg_id = v_msg_id
  where id = v_job_id;

  insert into public.kb_audit_events (
    actor_id,
    action,
    document_id,
    request_id,
    payload_json
  )
  values (
    p_actor_id,
    'kb.delete_requested',
    p_document_id,
    p_request_id,
    jsonb_build_object(
      'job_id',
      v_job_id,
      'msg_id',
      v_msg_id,
      'reason',
      p_reason,
      'delete_generation',
      v_document.delete_generation
    )
  );

  return query select p_document_id, v_job_id, v_msg_id, v_document.delete_generation;
end;
$$;

create or replace function public.request_reindex(
  p_document_id uuid,
  p_actor_id uuid default null,
  p_reason text default null,
  p_request_id text default null
)
returns table (document_id uuid, job_id uuid, msg_id bigint)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
begin
  return query
  select *
  from public.enqueue_index_from_processed_s3_ready(
    p_document_id,
    p_actor_id,
    p_request_id,
    jsonb_build_object('reason', p_reason, 'trigger', 'request_reindex')
  );
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
        'kb_queue_for_stage',
        'mark_raw_ready_and_enqueue_parse',
        'start_job_from_pgmq_message',
        'heartbeat_job',
        'fail_job',
        'mark_processed_s3_ready',
        'enqueue_index_from_processed_s3_ready',
        'complete_index',
        'archive_job_message',
        'request_delete',
        'request_reindex'
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

  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke usage on schema pgmq from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke usage on schema pgmq from authenticated;
  end if;
end $$;
