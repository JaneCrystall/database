create or replace function public.register_parse_two_stage_task(
  p_job_id uuid,
  p_worker_id text,
  p_task_id text,
  p_task_url text,
  p_status_url text,
  p_queue_name text,
  p_msg_id bigint,
  p_lock_seconds integer default 1800,
  p_backlog_json jsonb default '{}'::jsonb
)
returns table (
  job_id uuid,
  document_id uuid,
  document_version integer,
  task_id text,
  document_status public.kb_document_status
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_job record;
  v_two_stage jsonb;
  v_archived boolean;
begin
  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception 'worker_id is required';
  end if;

  if p_task_id is null or btrim(p_task_id) = '' then
    raise exception 'task_id is required';
  end if;

  if p_backlog_json is null or jsonb_typeof(p_backlog_json) <> 'object' then
    raise exception 'backlog_json must be a JSON object';
  end if;

  select
    j.id,
    j.document_id,
    j.document_version,
    j.stage,
    j.status,
    j.locked_by,
    j.locked_until,
    j.payload_json,
    d.status as document_status,
    d.deleted_at
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = p_job_id
  for update of j, d;

  if not found
    or v_job.stage <> 'parse'::public.kb_job_stage
    or v_job.status <> 'running'::public.kb_job_status
    or v_job.locked_by <> p_worker_id
    or v_job.locked_until <= now()
    or v_job.deleted_at is not null
  then
    return;
  end if;

  v_two_stage := jsonb_build_object(
    'task_id', p_task_id,
    'task_url', p_task_url,
    'status_url', p_status_url,
    'state', 'SUBMITTED',
    'submitted_at', now(),
    'last_checked_at', null,
    'backlog', p_backlog_json
  );

  update public.kb_jobs
  set payload_json = jsonb_set(
        coalesce(payload_json, '{}'::jsonb),
        '{two_stage}',
        v_two_stage,
        true
      ),
      -- The PGMQ transport message is archived below. Expire the submitter
      -- lock immediately so a parse finalizer can take over without waiting
      -- for the normal parse job timeout.
      locked_until = now(),
      updated_at = now()
  where id = p_job_id;

  select public.archive_job_message_by_id(p_queue_name, p_msg_id)
  into v_archived;

  if not coalesce(v_archived, false) then
    raise exception 'failed to archive parse queue message % from %', p_msg_id, p_queue_name;
  end if;

  return query
  select
    v_job.id,
    v_job.document_id,
    v_job.document_version,
    p_task_id,
    v_job.document_status;
end;
$$;

create or replace function public.claim_parse_two_stage_task(
  p_worker_id text,
  p_lock_seconds integer default 1800
)
returns table (
  job_id uuid,
  document_id uuid,
  document_version integer,
  task_id text,
  task_url text,
  status_url text,
  state text,
  submitted_at timestamptz,
  payload_json jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_job record;
begin
  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception 'worker_id is required';
  end if;

  select
    j.id,
    j.document_id,
    j.document_version,
    j.payload_json,
    j.payload_json #>> '{two_stage,task_id}' as task_id,
    j.payload_json #>> '{two_stage,task_url}' as task_url,
    j.payload_json #>> '{two_stage,status_url}' as status_url,
    j.payload_json #>> '{two_stage,state}' as state,
    (j.payload_json #>> '{two_stage,submitted_at}')::timestamptz as submitted_at
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.stage = 'parse'::public.kb_job_stage
    and j.status = 'running'::public.kb_job_status
    and d.deleted_at is null
    and j.payload_json #>> '{two_stage,task_id}' is not null
    and (
      j.locked_until is null
      or j.locked_until <= now()
    )
  order by j.updated_at, j.created_at
  limit 1
  for update of j skip locked;

  if not found then
    return;
  end if;

  update public.kb_jobs
  set locked_by = p_worker_id,
      locked_until = now() + (greatest(coalesce(p_lock_seconds, 1), 1) * interval '1 second'),
      updated_at = now()
  where id = v_job.id;

  return query
  select
    v_job.id,
    v_job.document_id,
    v_job.document_version,
    v_job.task_id,
    v_job.task_url,
    v_job.status_url,
    v_job.state,
    v_job.submitted_at,
    v_job.payload_json;
end;
$$;

create or replace function public.mark_parse_two_stage_task_state(
  p_job_id uuid,
  p_worker_id text,
  p_state text,
  p_error text default null,
  p_lock_seconds integer default 1800
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_two_stage jsonb;
begin
  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception 'worker_id is required';
  end if;

  if p_state is null or btrim(p_state) = '' then
    raise exception 'state is required';
  end if;

  select coalesce(payload_json->'two_stage', '{}'::jsonb)
  into v_two_stage
  from public.kb_jobs
  where id = p_job_id
    and stage = 'parse'::public.kb_job_stage
    and status = 'running'::public.kb_job_status
    and locked_by = p_worker_id
    and locked_until > now()
  for update;

  if not found then
    return false;
  end if;

  v_two_stage := v_two_stage || jsonb_build_object(
    'state', p_state,
    'last_checked_at', now()
  );

  if p_error is not null then
    v_two_stage := v_two_stage || jsonb_build_object('error', p_error);
  end if;

  update public.kb_jobs
  set payload_json = jsonb_set(
        coalesce(payload_json, '{}'::jsonb),
        '{two_stage}',
        v_two_stage,
        true
      ),
      locked_until = now() + (greatest(coalesce(p_lock_seconds, 1), 1) * interval '1 second'),
      updated_at = now()
  where id = p_job_id;

  return true;
end;
$$;
