create or replace function public.complete_parse_local_ready_and_enqueue_s3_check(
  p_job_id uuid,
  p_worker_id text,
  p_document_id uuid,
  p_document_version integer,
  p_processed_manifest_local_uri text,
  p_artifact_uuid uuid,
  p_manifest_hash text default null,
  p_chunk_count integer default null,
  p_metadata_json jsonb default '{}'::jsonb,
  p_s3_ready_payload_json jsonb default '{}'::jsonb
)
returns table (
  parse_job_id uuid,
  parse_job_status public.kb_job_status,
  s3_ready_job_id uuid,
  s3_ready_msg_id bigint,
  document_status public.kb_document_status
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_job record;
  v_s3_ready_job record;
  v_msg_id bigint;
  v_payload jsonb;
  v_parse_already_complete boolean := false;
begin
  if p_worker_id is null or p_worker_id = '' then
    raise exception 'worker_id is required';
  end if;

  if p_processed_manifest_local_uri is null or btrim(p_processed_manifest_local_uri) = '' then
    raise exception 'processed manifest local uri is required';
  end if;

  if p_artifact_uuid is null then
    raise exception 'artifact_uuid is required';
  end if;

  if p_chunk_count is not null and p_chunk_count < 0 then
    raise exception 'chunk_count cannot be negative';
  end if;

  if p_metadata_json is null or jsonb_typeof(p_metadata_json) <> 'object' then
    raise exception 'metadata_json must be a JSON object';
  end if;

  if p_s3_ready_payload_json is null or jsonb_typeof(p_s3_ready_payload_json) <> 'object' then
    raise exception 's3_ready_payload_json must be a JSON object';
  end if;

  select
    j.id,
    j.document_id,
    j.document_version,
    j.stage,
    j.status,
    j.locked_by,
    j.locked_until,
    d.status as document_status,
    d.metadata_json,
    d.deleted_at,
    d.processed_manifest_local_uri,
    d.processed_manifest_hash,
    d.processed_artifact_uuid
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
  for update of j, d;

  if not found
    or v_job.stage <> 'parse'::public.kb_job_stage
    or v_job.deleted_at is not null
  then
    return;
  end if;

  v_parse_already_complete :=
    v_job.status = 'succeeded'::public.kb_job_status
    and v_job.document_status in (
      's3_sync_pending'::public.kb_document_status,
      'processed_s3_ready'::public.kb_document_status
    )
    and v_job.processed_manifest_local_uri = p_processed_manifest_local_uri
    and v_job.processed_artifact_uuid = p_artifact_uuid
    and (
      p_manifest_hash is null
      or v_job.processed_manifest_hash = p_manifest_hash
    );

  if not v_parse_already_complete then
    if v_job.status <> 'running'::public.kb_job_status
      or v_job.locked_by <> p_worker_id
      or v_job.locked_until <= now()
    then
      return;
    end if;

    update public.kb_documents d
    set status = 's3_sync_pending',
        processed_manifest_local_uri = p_processed_manifest_local_uri,
        processed_manifest_hash = coalesce(p_manifest_hash, processed_manifest_hash),
        processed_artifact_uuid = p_artifact_uuid,
        chunk_count = coalesce(p_chunk_count, chunk_count),
        parse_time = coalesce(parse_time, now()),
        metadata_json = (
          coalesce(d.metadata_json, '{}'::jsonb) || coalesce(p_metadata_json, '{}'::jsonb)
        ) || jsonb_build_object(
          'processed',
          coalesce(
            (coalesce(d.metadata_json, '{}'::jsonb) || coalesce(p_metadata_json, '{}'::jsonb))->'processed',
            '{}'::jsonb
          ) || jsonb_build_object('local_ready', true)
        ),
        last_error = null,
        last_error_stage = null
    where d.id = p_document_id
      and d.document_version = p_document_version
      and d.deleted_at is null;

    update public.kb_jobs
    set status = 'succeeded',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = null
    where id = p_job_id;
  end if;

  v_payload := p_s3_ready_payload_json || jsonb_build_object(
    'trigger',
    coalesce(p_s3_ready_payload_json->>'trigger', 'parse_local_ready'),
    'manifest_local_uri',
    p_processed_manifest_local_uri,
    'manifest_hash',
    p_manifest_hash,
    'artifact_uuid',
    p_artifact_uuid,
    'chunk_count',
    p_chunk_count
  );

  select id, status, pgmq_msg_id
  into v_s3_ready_job
  from public.kb_jobs
  where document_id = p_document_id
    and document_version = p_document_version
    and stage = 's3_ready'::public.kb_job_stage
    and status in (
      'queued'::public.kb_job_status,
      'running'::public.kb_job_status,
      'failed'::public.kb_job_status,
      'succeeded'::public.kb_job_status
    )
  order by created_at desc
  limit 1
  for update;

  if v_s3_ready_job.id is null then
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
      p_document_version,
      's3_ready',
      'queued',
      'kb_s3_ready_queue',
      v_payload
    )
    returning id, status, pgmq_msg_id
    into v_s3_ready_job;
  elsif v_s3_ready_job.status not in (
    'running'::public.kb_job_status,
    'succeeded'::public.kb_job_status
  ) then
    update public.kb_jobs
    set status = 'queued',
        locked_by = null,
        locked_until = null,
        pgmq_queue = 'kb_s3_ready_queue',
        pgmq_msg_id = case
          when v_s3_ready_job.status = 'failed'::public.kb_job_status then null
          else public.kb_jobs.pgmq_msg_id
        end,
        payload_json = v_payload,
        last_error = null,
        updated_at = now()
    where id = v_s3_ready_job.id
    returning id, status, pgmq_msg_id
    into v_s3_ready_job;
  end if;

  v_msg_id := v_s3_ready_job.pgmq_msg_id;

  if v_msg_id is null
    and v_s3_ready_job.status in (
      'queued'::public.kb_job_status,
      'failed'::public.kb_job_status
    )
  then
    select sent.msg_id
    into v_msg_id
    from pgmq.send(
      'kb_s3_ready_queue',
      jsonb_build_object('job_id', v_s3_ready_job.id::text)
    ) as sent(msg_id)
    limit 1;

    update public.kb_jobs
    set pgmq_queue = 'kb_s3_ready_queue',
        pgmq_msg_id = v_msg_id
    where id = v_s3_ready_job.id;
  end if;

  if v_msg_id is null then
    return;
  end if;

  if not v_parse_already_complete then
    perform public.write_kb_audit_event(
      null,
      'kb.parse_local_ready',
      p_document_id,
      null,
      jsonb_build_object('stage', 'parse'),
      null,
      jsonb_build_object(
        'parse_job_id', p_job_id,
        's3_ready_job_id', v_s3_ready_job.id,
        's3_ready_msg_id', v_msg_id,
        'artifact_uuid', p_artifact_uuid,
        'chunk_count', p_chunk_count
      )
    );
  end if;

  return query
  select
    p_job_id,
    'succeeded'::public.kb_job_status,
    v_s3_ready_job.id,
    v_msg_id,
    case
      when v_parse_already_complete then v_job.document_status
      else 's3_sync_pending'::public.kb_document_status
    end;
end;
$$;
