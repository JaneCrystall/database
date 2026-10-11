create or replace function public.kb_queue_for_stage(p_stage public.kb_job_stage)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select case p_stage
    when 'parse'::public.kb_job_stage then 'kb_parse_queue'
    when 's3_ready'::public.kb_job_stage then 'kb_s3_ready_queue'
    when 'index'::public.kb_job_stage then 'kb_index_queue'
    when 'delete'::public.kb_job_stage then 'kb_delete_queue'
    when 'archive_raw'::public.kb_job_stage then 'kb_archive_queue'
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
    j.payload_json
  from public.kb_jobs j
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
    d.metadata_json,
    d.deleted_at
  into v_job
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
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
  on conflict (document_id, document_version, stage)
  where status in ('queued', 'running', 'failed')
  do update
  set status = case
        when public.kb_jobs.status = 'running'::public.kb_job_status then public.kb_jobs.status
        else 'queued'::public.kb_job_status
      end,
      locked_by = case
        when public.kb_jobs.status = 'running'::public.kb_job_status then public.kb_jobs.locked_by
        else null
      end,
      locked_until = case
        when public.kb_jobs.status = 'running'::public.kb_job_status then public.kb_jobs.locked_until
        else null
      end,
      pgmq_queue = 'kb_s3_ready_queue',
      payload_json = excluded.payload_json,
      last_error = null,
      updated_at = now()
  returning id, status
  into v_s3_ready_job;

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

  return query
  select
    p_job_id,
    'succeeded'::public.kb_job_status,
    v_s3_ready_job.id,
    v_msg_id,
    's3_sync_pending'::public.kb_document_status;
end;
$$;

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
    or v_job.status <> 'running'::public.kb_job_status
    or v_job.locked_by <> p_worker_id
    or v_job.locked_until <= now()
    or v_job.deleted_at is not null
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

  return found;
end;
$$;

create or replace function public.kb_cancel_jobs_on_document_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = 'cancelled by document delete tombstone'
    where document_id = new.id
      and stage in (
        'parse'::public.kb_job_stage,
        's3_ready'::public.kb_job_stage,
        'index'::public.kb_job_stage
      )
      and status in ('queued', 'running', 'failed');
  end if;

  return new;
end;
$$;

drop trigger if exists kb_documents_cancel_jobs_on_delete on public.kb_documents;
create trigger kb_documents_cancel_jobs_on_delete
after update of deleted_at on public.kb_documents
for each row execute function public.kb_cancel_jobs_on_document_delete();

create or replace function public.request_retry(
  p_document_id uuid,
  p_actor_id uuid,
  p_stage public.kb_job_stage,
  p_reason text,
  p_request_id text default null
)
returns table (
  document_id uuid,
  job_id uuid,
  msg_id bigint,
  stage public.kb_job_stage,
  status public.kb_document_status,
  already_applied boolean,
  result_code text
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_job record;
  v_new_job_id uuid;
  v_msg_id bigint;
  v_queue text;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'retry reason is required';
  end if;

  if p_stage not in (
    'parse'::public.kb_job_stage,
    's3_ready'::public.kb_job_stage,
    'index'::public.kb_job_stage,
    'delete'::public.kb_job_stage
  ) then
    raise exception 'stage % is not retryable', p_stage;
  end if;

  if not public.can_document_action(p_actor_id, p_document_id, 'reindex') then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.auth_denied',
      p_document_id,
      null,
      jsonb_build_object(
        'resource_type', 'document',
        'resource_id', p_document_id,
        'requested_action', 'retry',
        'stage', p_stage
      ),
      p_request_id,
      jsonb_build_object('reason', 'missing reindex or manage grant')
    );
    return;
  end if;

  select *
  into v_document
  from public.kb_documents
  where id = p_document_id
  for update;

  if not found then
    raise exception 'document % was not found', p_document_id;
  end if;

  if p_stage <> 'delete'::public.kb_job_stage and v_document.deleted_at is not null then
    raise exception 'deleted document % cannot retry %', p_document_id, p_stage;
  end if;

  if p_stage = 'index'::public.kb_job_stage and v_document.processed_manifest_s3_key is null then
    raise exception 'document % is missing processed manifest for index retry', p_document_id;
  end if;

  if p_stage = 's3_ready'::public.kb_job_stage and v_document.processed_manifest_local_uri is null then
    raise exception 'document % is missing local processed manifest for s3 ready retry', p_document_id;
  end if;

  select *
  into v_job
  from public.kb_jobs
  where document_id = p_document_id
    and stage = p_stage
    and (
      document_version = v_document.document_version
      or p_stage = 'delete'::public.kb_job_stage
    )
  order by created_at desc
  limit 1
  for update;

  if not found then
    raise exception 'document % has no % job to retry', p_document_id, p_stage;
  end if;

  if v_job.status in ('queued', 'running') then
    return query
    select
      p_document_id,
      v_job.id,
      v_job.pgmq_msg_id,
      p_stage,
      v_document.status,
      true,
      'already_active'::text;
    return;
  end if;

  if v_job.status = 'failed'::public.kb_job_status then
    v_new_job_id := v_job.id;
    perform public.kb_archive_job_message_by_id(v_job.pgmq_queue, v_job.pgmq_msg_id);
    update public.kb_jobs
    set status = 'queued',
        locked_by = null,
        locked_until = null,
        last_error = null,
        payload_json = coalesce(payload_json, '{}'::jsonb) || jsonb_build_object(
          'reason',
          p_reason,
          'trigger',
          'request_retry'
        )
    where id = v_new_job_id;
  elsif v_job.status = 'dead'::public.kb_job_status then
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
      p_stage,
      'queued',
      public.kb_queue_for_stage(p_stage),
      jsonb_build_object(
        'reason',
        p_reason,
        'trigger',
        'request_retry',
        'retry_of_job_id',
        v_job.id
      )
    )
    returning id
    into v_new_job_id;
  else
    raise exception 'job % with status % cannot be retried', v_job.id, v_job.status;
  end if;

  v_queue := public.kb_queue_for_stage(p_stage);

  select sent.msg_id
  into v_msg_id
  from pgmq.send(
    v_queue,
    jsonb_build_object('job_id', v_new_job_id::text)
  ) as sent(msg_id)
  limit 1;

  update public.kb_jobs
  set pgmq_queue = v_queue,
      pgmq_msg_id = v_msg_id
  where id = v_new_job_id;

  update public.kb_documents
  set status = case
        when p_stage = 'parse'::public.kb_job_stage then 'parse_queued'::public.kb_document_status
        when p_stage = 's3_ready'::public.kb_job_stage then 's3_sync_pending'::public.kb_document_status
        when p_stage = 'index'::public.kb_job_stage then 'index_queued'::public.kb_document_status
        when p_stage = 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
      end,
      last_error = null,
      last_error_stage = null
  where id = p_document_id;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.retry_requested',
    p_document_id,
    null,
    jsonb_build_object('stage', p_stage),
    p_request_id,
    jsonb_build_object(
      'job_id', v_new_job_id,
      'msg_id', v_msg_id,
      'reason', p_reason,
      'retry_of_job_id', v_job.id
    )
  );

  select status
  into v_document.status
  from public.kb_documents
  where id = p_document_id;

  return query
  select
    p_document_id,
    v_new_job_id,
    v_msg_id,
    p_stage,
    v_document.status,
    false,
    'retry_queued'::text;
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
        'start_job_from_pgmq_message',
        'fail_job',
        'complete_parse_local_ready_and_enqueue_s3_check',
        'complete_s3_ready_check',
        'kb_cancel_jobs_on_document_delete',
        'request_retry'
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
