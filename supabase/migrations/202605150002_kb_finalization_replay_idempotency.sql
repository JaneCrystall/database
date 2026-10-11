create or replace function public.complete_s3_ready_check(
  p_job_id uuid,
  p_worker_id text,
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
declare
  v_job record;
  v_already_complete boolean := false;
begin
  if p_worker_id is null or p_worker_id = '' then
    raise exception 'worker_id is required';
  end if;

  if p_manifest_s3_key is null or btrim(p_manifest_s3_key) = '' then
    raise exception 'manifest_s3_key is required';
  end if;

  if p_artifact_uuid is null then
    raise exception 'artifact_uuid is required';
  end if;

  if p_chunk_count is not null and p_chunk_count < 0 then
    raise exception 'chunk_count cannot be negative';
  end if;

  select
    j.id,
    j.stage,
    j.status,
    j.locked_by,
    j.locked_until,
    d.status as document_status,
    d.deleted_at,
    d.processed_manifest_s3_key,
    d.processed_manifest_local_uri,
    d.processed_manifest_hash,
    d.processed_artifact_uuid
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
    and d.document_version = j.document_version
  for update of j, d;

  if not found
    or v_job.stage <> 's3_ready'::public.kb_job_stage
    or v_job.deleted_at is not null
  then
    return false;
  end if;

  v_already_complete :=
    v_job.status = 'succeeded'::public.kb_job_status
    and v_job.document_status = 'processed_s3_ready'::public.kb_document_status
    and v_job.processed_manifest_s3_key = p_manifest_s3_key
    and v_job.processed_artifact_uuid = p_artifact_uuid
    and (
      p_manifest_hash is null
      or v_job.processed_manifest_hash = p_manifest_hash
    )
    and (
      p_manifest_local_uri is null
      or v_job.processed_manifest_local_uri = p_manifest_local_uri
    );

  if not v_already_complete then
    if v_job.status <> 'running'::public.kb_job_status
      or v_job.locked_by <> p_worker_id
      or v_job.locked_until <= now()
    then
      return false;
    end if;

    if v_job.document_status not in (
      's3_sync_pending'::public.kb_document_status,
      's3_ready_check_failed'::public.kb_document_status,
      'processed_s3_ready'::public.kb_document_status
    ) then
      return false;
    end if;

    if v_job.processed_artifact_uuid is not null and v_job.processed_artifact_uuid <> p_artifact_uuid then
      return false;
    end if;

    if p_manifest_hash is not null
      and v_job.processed_manifest_hash is not null
      and v_job.processed_manifest_hash <> p_manifest_hash
    then
      return false;
    end if;

    update public.kb_jobs
    set status = 'succeeded',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = null
    where id = p_job_id;

    update public.kb_documents d
    set status = 'processed_s3_ready',
        processed_manifest_s3_key = p_manifest_s3_key,
        processed_manifest_hash = coalesce(p_manifest_hash, processed_manifest_hash),
        processed_artifact_uuid = coalesce(p_artifact_uuid, processed_artifact_uuid),
        processed_manifest_local_uri = coalesce(p_manifest_local_uri, processed_manifest_local_uri),
        processed_s3_ready_at = now(),
        chunk_count = coalesce(p_chunk_count, chunk_count),
        parse_time = coalesce(parse_time, now()),
        metadata_json = coalesce(d.metadata_json, '{}'::jsonb) || jsonb_build_object(
          'processed',
          coalesce(d.metadata_json->'processed', '{}'::jsonb) || jsonb_build_object('s3_ready', true)
        ),
        last_error = null,
        last_error_stage = null
    where id = p_document_id
      and document_version = p_document_version
      and deleted_at is null;

    perform public.write_kb_audit_event(
      null,
      'kb.processed_s3_ready',
      p_document_id,
      null,
      jsonb_build_object('stage', 's3_ready'),
      null,
      jsonb_build_object(
        'job_id', p_job_id,
        'manifest_s3_key', p_manifest_s3_key,
        'artifact_uuid', p_artifact_uuid,
        'chunk_count', p_chunk_count
      )
    );
  end if;

  return true;
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
  v_replayed_job record;
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
    select
      j.id,
      j.status,
      j.next_retry_at,
      j.retry_wakeup_msg_id,
      d.status as document_status
    into v_replayed_job
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
      and d.document_version = j.document_version
    where j.id = p_job_id
      and j.status in (
        'failed'::public.kb_job_status,
        'dead'::public.kb_job_status
      )
      and j.last_error is not distinct from p_error;

    if found then
      return query
      select
        v_replayed_job.id,
        v_replayed_job.status,
        v_replayed_job.document_status,
        v_replayed_job.next_retry_at,
        v_replayed_job.retry_wakeup_msg_id;
    end if;

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

  update public.kb_documents
  set status = v_document_status,
      last_error = p_error,
      last_error_stage = coalesce(p_error_stage, v_job.stage)
  where id = v_job.document_id
    and document_version = v_job.document_version;

  return query select p_job_id, v_job_status, v_document_status, v_next_retry_at, v_retry_wakeup_msg_id;
end;
$$;
