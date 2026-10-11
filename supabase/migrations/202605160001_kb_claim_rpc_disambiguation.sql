create or replace function public.claim_job_from_pgmq_message(
  p_job_id uuid,
  p_queue text,
  p_msg_id bigint,
  p_worker_id text,
  p_lock_seconds integer default 1800
)
returns table (
  claim_status text,
  archive_current_message boolean,
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
  collection_path text,
  next_retry_at timestamptz,
  retry_wakeup_msg_id bigint
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
    return query select
      'missing'::text,
      true,
      p_job_id,
      null::uuid,
      null::integer,
      null::public.kb_job_stage,
      null::public.kb_job_status,
      null::jsonb,
      null::text,
      null::text,
      null::bigint,
      null::text,
      null::text,
      null::timestamptz,
      null::bigint;
    return;
  end if;

  if public.kb_queue_for_stage(v_job.stage) <> p_queue then
    return query select
      'wrong_queue'::text,
      true,
      v_job.id,
      v_job.document_id,
      v_job.document_version,
      v_job.stage,
      v_job.status,
      v_job.payload_json,
      v_job.raw_uri,
      v_job.file_ext,
      v_job.file_size,
      v_job.sha256,
      v_job.collection_path,
      v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
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
        retry_wakeup_msg_id = null,
        finished_at = now(),
        last_error = 'document was deleted before claim'
    where id = p_job_id
    returning * into v_job;

    return query select
      'cancelled'::text,
      true,
      v_job.id,
      v_job.document_id,
      v_job.document_version,
      v_job.stage,
      v_job.status,
      v_job.payload_json,
      null::text,
      null::text,
      null::bigint,
      null::text,
      null::text,
      v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if v_job.document_version <> v_job.current_document_version then
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        next_retry_at = null,
        retry_wakeup_msg_id = null,
        finished_at = now(),
        last_error = 'document version changed before claim'
    where id = p_job_id
    returning * into v_job;

    return query select
      'cancelled'::text,
      true,
      v_job.id,
      v_job.document_id,
      v_job.document_version,
      v_job.stage,
      v_job.status,
      v_job.payload_json,
      null::text,
      null::text,
      null::bigint,
      null::text,
      null::text,
      v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if v_job.status = 'dead' then
    return query select
      'dead'::text, true, v_job.id, v_job.document_id, v_job.document_version,
      v_job.stage, v_job.status, v_job.payload_json, v_job.raw_uri, v_job.file_ext,
      v_job.file_size, v_job.sha256, v_job.collection_path, v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if v_job.status = 'cancelled' then
    return query select
      'cancelled'::text, true, v_job.id, v_job.document_id, v_job.document_version,
      v_job.stage, v_job.status, v_job.payload_json, v_job.raw_uri, v_job.file_ext,
      v_job.file_size, v_job.sha256, v_job.collection_path, v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if v_job.status = 'failed'
     and v_job.next_retry_at is not null
     and v_job.next_retry_at > now() then
    return query select
      'backoff_not_due'::text,
      v_job.retry_wakeup_msg_id is not null and p_msg_id is distinct from v_job.retry_wakeup_msg_id,
      v_job.id, v_job.document_id, v_job.document_version,
      v_job.stage, v_job.status, v_job.payload_json, v_job.raw_uri, v_job.file_ext,
      v_job.file_size, v_job.sha256, v_job.collection_path, v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if not (
    v_job.status in ('queued', 'failed')
    or (v_job.status = 'running' and v_job.locked_until < now())
  ) then
    return query select
      'duplicate_running'::text,
      p_msg_id is not null and v_job.pgmq_msg_id is not null and p_msg_id is distinct from v_job.pgmq_msg_id,
      v_job.id, v_job.document_id, v_job.document_version,
      v_job.stage, v_job.status, v_job.payload_json, v_job.raw_uri, v_job.file_ext,
      v_job.file_size, v_job.sha256, v_job.collection_path, v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
    return;
  end if;

  if v_job.attempt_count >= v_job.max_attempts then
    update public.kb_jobs
    set status = 'dead',
        locked_by = null,
        locked_until = null,
        next_retry_at = null,
        retry_wakeup_msg_id = null,
        finished_at = now(),
        last_error = coalesce(last_error, 'max attempts reached before claim')
    where id = p_job_id
    returning * into v_job;

    update public.kb_documents as d
    set status = case v_job.stage
          when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
          else 'failed'::public.kb_document_status
        end,
        last_error = coalesce(v_job.last_error, 'max attempts reached before claim'),
        last_error_stage = v_job.stage
    where d.id = v_job.document_id
      and d.document_version = v_job.document_version;

    return query select
      'max_attempts_reached'::text, true, v_job.id, v_job.document_id, v_job.document_version,
      v_job.stage, v_job.status, v_job.payload_json, null::text, null::text,
      null::bigint, null::text, null::text, v_job.next_retry_at,
      v_job.retry_wakeup_msg_id;
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
      retry_wakeup_msg_id = null,
      pgmq_queue = p_queue,
      pgmq_msg_id = p_msg_id,
      last_error = null,
      started_at = coalesce(started_at, now())
  where id = p_job_id;

  update public.kb_documents as d
  set status = v_document_status,
      last_error = null,
      last_error_stage = null
  where d.id = v_job.document_id
    and (
      v_job.stage = 'delete'::public.kb_job_stage
      or d.deleted_at is null
    );

  return query
  select
    'claimed'::text,
    false,
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
    c.path,
    j.next_retry_at,
    j.retry_wakeup_msg_id
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  join public.kb_collections c on c.id = d.primary_collection_id
  where j.id = p_job_id;
end;
$$;

create or replace function public.fail_job_v2(
  p_job_id uuid,
  p_worker_id text,
  p_retryable boolean,
  p_error text,
  p_error_stage public.kb_job_stage default null
)
returns table (
  job_id uuid,
  job_status public.kb_job_status,
  document_status public.kb_document_status,
  next_retry_at timestamptz,
  retry_wakeup_msg_id bigint
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_job record;
  v_job_status public.kb_job_status;
  v_document_status public.kb_document_status;
  v_next_retry_at timestamptz;
  v_retry_delay_seconds integer;
  v_retry_wakeup_msg_id bigint;
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
    d.processed_manifest_local_uri is not null
    and d.processed_artifact_uuid is not null
  )
  into v_has_parse_local_ready
  from public.kb_documents as d
  where d.id = v_job.document_id
    and d.document_version = v_job.document_version;

  if p_retryable and v_job.attempt_count < v_job.max_attempts then
    v_job_status := 'failed';
    v_next_retry_at := now() + public.kb_job_retry_backoff(v_job.attempt_count);
    v_retry_delay_seconds := greatest(0, ceil(extract(epoch from (v_next_retry_at - now())))::integer);

    select pgmq.send(
      public.kb_queue_for_stage(v_job.stage),
      jsonb_build_object('job_id', p_job_id::text),
      v_retry_delay_seconds
    )
    into v_retry_wakeup_msg_id;

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
    v_retry_wakeup_msg_id := null;
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
      retry_wakeup_msg_id = v_retry_wakeup_msg_id,
      finished_at = case when v_job_status = 'dead' then now() else finished_at end,
      last_error = p_error
  where id = p_job_id;

  update public.kb_documents as d
  set status = v_document_status,
      last_error = p_error,
      last_error_stage = coalesce(p_error_stage, v_job.stage)
  where d.id = v_job.document_id
    and d.document_version = v_job.document_version;

  return query select p_job_id, v_job_status, v_document_status, v_next_retry_at, v_retry_wakeup_msg_id;
end;
$$;
