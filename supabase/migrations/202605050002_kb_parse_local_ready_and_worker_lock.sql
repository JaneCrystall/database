drop function if exists public.mark_processed_s3_ready(
  uuid,
  uuid,
  integer,
  text,
  text,
  uuid,
  text,
  integer
);

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
    v_document_status := case
      when v_job.stage = 'parse'::public.kb_job_stage and v_has_parse_local_ready then
        's3_ready_check_failed'::public.kb_document_status
      when v_job.stage = 'parse'::public.kb_job_stage then
        'parse_queued'::public.kb_document_status
      when v_job.stage = 'index'::public.kb_job_stage then
        'index_queued'::public.kb_document_status
      when v_job.stage = 'delete'::public.kb_job_stage then
        'delete_queued'::public.kb_document_status
      else
        'failed'::public.kb_document_status
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

create or replace function public.mark_parse_local_ready(
  p_job_id uuid,
  p_worker_id text,
  p_document_id uuid,
  p_document_version integer,
  p_processed_manifest_local_uri text,
  p_artifact_uuid uuid,
  p_manifest_hash text default null,
  p_chunk_count integer default null,
  p_metadata_json jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
begin
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
  from public.kb_jobs j
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
    and j.stage = 'parse'
    and j.status = 'running'
    and j.locked_by = p_worker_id
    and j.locked_until > now()
    and d.id = j.document_id
    and d.document_version = j.document_version
    and d.deleted_at is null;

  return found;
end;
$$;

create or replace function public.mark_processed_s3_ready(
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
    and j.locked_by = p_worker_id
    and j.locked_until > now()
    and d.id = j.document_id
    and d.document_version = j.document_version
    and d.deleted_at is null;

  if not found then
    return false;
  end if;

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

  return found;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.mark_parse_local_ready(
      uuid,
      text,
      uuid,
      integer,
      text,
      uuid,
      text,
      integer,
      jsonb
    ) to service_role;

    grant execute on function public.mark_processed_s3_ready(
      uuid,
      text,
      uuid,
      integer,
      text,
      text,
      uuid,
      text,
      integer
    ) to service_role;
  end if;
end;
$$;
