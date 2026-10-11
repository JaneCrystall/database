create table if not exists public.kb_index_records (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references public.kb_jobs(id) on delete set null,
  document_id uuid not null references public.kb_documents(id) on delete cascade,
  document_version integer not null check (document_version > 0),
  chunk_id text not null,
  record_id text not null,
  opensearch_index_name text,
  pinecone_index_name text,
  pinecone_namespace text,
  indexed_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (chunk_id <> ''),
  check (record_id <> '')
);

create unique index if not exists kb_index_records_record_id_idx
on public.kb_index_records (record_id);

create index if not exists kb_index_records_document_idx
on public.kb_index_records (document_id, document_version, deleted_at);

drop trigger if exists kb_index_records_set_updated_at on public.kb_index_records;
create trigger kb_index_records_set_updated_at
before update on public.kb_index_records
for each row execute function public.kb_set_updated_at();

drop function if exists public.request_delete(uuid, uuid, text, text);
drop function if exists public.request_reindex(uuid, uuid, text, text);

create or replace function public.kb_archive_job_message_by_id(
  p_queue text,
  p_msg_id bigint
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_archived boolean;
begin
  if p_queue is null or p_msg_id is null then
    return false;
  end if;

  select pgmq.archive(p_queue, p_msg_id)
  into v_archived;

  return coalesce(v_archived, false);
exception
  when others then
    return false;
end;
$$;

create or replace function public.request_delete(
  p_document_id uuid,
  p_actor_id uuid,
  p_reason text default null,
  p_request_id text default null
)
returns table (
  document_id uuid,
  job_id uuid,
  msg_id bigint,
  delete_generation integer,
  already_applied boolean,
  result_code text,
  status public.kb_document_status
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_existing_job record;
  v_job_id uuid;
  v_msg_id bigint;
  v_cancelled record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'delete reason is required';
  end if;

  if not public.can_document_action(p_actor_id, p_document_id, 'delete') then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.auth_denied',
      p_document_id,
      null,
      jsonb_build_object(
        'resource_type', 'document',
        'resource_id', p_document_id,
        'requested_action', 'delete'
      ),
      p_request_id,
      jsonb_build_object('reason', 'missing delete or manage grant')
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

  if v_document.status = 'deleted'::public.kb_document_status then
    return query
    select
      v_document.id,
      null::uuid,
      null::bigint,
      v_document.delete_generation,
      true,
      'already_deleted'::text,
      v_document.status;
    return;
  end if;

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
  returning *
  into v_document;

  for v_cancelled in
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = 'cancelled by delete request'
    where document_id = p_document_id
      and stage in ('parse', 'index')
      and status in ('queued', 'running', 'failed')
    returning id, pgmq_queue, pgmq_msg_id
  loop
    perform public.kb_archive_job_message_by_id(v_cancelled.pgmq_queue, v_cancelled.pgmq_msg_id);
  end loop;

  select id, pgmq_queue, pgmq_msg_id
  into v_existing_job
  from public.kb_jobs
  where document_id = p_document_id
    and document_version = v_document.document_version
    and stage = 'delete'
    and status in ('queued', 'running', 'failed')
  order by created_at desc
  limit 1
  for update;

  if found then
    v_job_id := v_existing_job.id;
    perform public.kb_archive_job_message_by_id(v_existing_job.pgmq_queue, v_existing_job.pgmq_msg_id);
    update public.kb_jobs
    set status = case when status = 'running' then status else 'queued'::public.kb_job_status end,
        locked_by = case when status = 'running' then locked_by else null end,
        locked_until = case when status = 'running' then locked_until else null end,
        payload_json = coalesce(payload_json, '{}'::jsonb) || jsonb_build_object(
          'reason',
          p_reason,
          'delete_generation',
          v_document.delete_generation
        )
    where id = v_job_id;
  else
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
    returning id
    into v_job_id;
  end if;

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

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.delete_requested',
    p_document_id,
    null,
    jsonb_build_object('delete_generation', v_document.delete_generation),
    p_request_id,
    jsonb_build_object(
      'job_id', v_job_id,
      'msg_id', v_msg_id,
      'reason', p_reason,
      'delete_generation', v_document.delete_generation
    )
  );

  return query
  select
    p_document_id,
    v_job_id,
    v_msg_id,
    v_document.delete_generation,
    false,
    'delete_queued'::text,
    'delete_queued'::public.kb_document_status;
end;
$$;

create or replace function public.complete_delete(
  p_job_id uuid,
  p_worker_id text,
  p_document_id uuid,
  p_document_version integer,
  p_delete_generation integer,
  p_cleanup_json jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_actor_id uuid;
begin
  if p_cleanup_json is null or jsonb_typeof(p_cleanup_json) <> 'object' then
    raise exception 'cleanup_json must be a JSON object';
  end if;

  update public.kb_jobs j
  set status = 'succeeded',
      locked_by = null,
      locked_until = null,
      finished_at = now(),
      last_error = null,
      payload_json = coalesce(j.payload_json, '{}'::jsonb) || jsonb_build_object(
        'cleanup',
        p_cleanup_json
      )
  from public.kb_documents d
  where j.id = p_job_id
    and j.document_id = p_document_id
    and j.document_version = p_document_version
    and j.stage = 'delete'
    and j.status = 'running'
    and j.locked_by = p_worker_id
    and d.id = j.document_id
    and d.document_version = j.document_version
    and d.delete_generation = p_delete_generation
    and d.deleted_at is not null;

  if not found then
    return false;
  end if;

  update public.kb_documents
  set status = 'deleted',
      delete_completed_at = now(),
      opensearch_indexed = false,
      pinecone_indexed = false,
      last_error = null,
      last_error_stage = null
  where id = p_document_id
    and document_version = p_document_version
    and delete_generation = p_delete_generation
    and deleted_at is not null
  returning deleted_by
  into v_actor_id;

  update public.kb_index_records
  set deleted_at = coalesce(deleted_at, now())
  where document_id = p_document_id
    and document_version = p_document_version
    and deleted_at is null;

  perform public.write_kb_audit_event(
    v_actor_id,
    'kb.delete_completed',
    p_document_id,
    null,
    jsonb_build_object('delete_generation', p_delete_generation),
    null,
    jsonb_build_object(
      'job_id', p_job_id,
      'worker_id', p_worker_id,
      'cleanup', p_cleanup_json
    )
  );

  return found;
end;
$$;

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

  if p_stage not in ('parse'::public.kb_job_stage, 'index'::public.kb_job_stage, 'delete'::public.kb_job_stage) then
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

create or replace function public.request_reindex(
  p_document_id uuid,
  p_actor_id uuid default null,
  p_reason text default null,
  p_request_id text default null
)
returns table (
  document_id uuid,
  job_id uuid,
  msg_id bigint,
  already_applied boolean,
  result_code text,
  status public.kb_document_status
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_job record;
  v_job_id uuid;
  v_msg_id bigint;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reindex reason is required';
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
        'requested_action', 'reindex'
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

  if v_document.deleted_at is not null then
    raise exception 'deleted document % cannot be reindexed', p_document_id;
  end if;

  if v_document.status not in ('processed_s3_ready'::public.kb_document_status, 'completed'::public.kb_document_status, 'index_queued'::public.kb_document_status, 'indexing'::public.kb_document_status) then
    raise exception 'document % is not ready for reindex from status %', p_document_id, v_document.status;
  end if;

  if v_document.processed_manifest_s3_key is null then
    raise exception 'document % is missing processed manifest for reindex', p_document_id;
  end if;

  select *
  into v_job
  from public.kb_jobs
  where document_id = p_document_id
    and document_version = v_document.document_version
    and stage = 'index'
    and status in ('queued', 'running', 'failed')
  order by created_at desc
  limit 1
  for update;

  if found and v_job.status in ('queued', 'running') then
    return query
    select
      p_document_id,
      v_job.id,
      v_job.pgmq_msg_id,
      true,
      'already_active'::text,
      v_document.status;
    return;
  end if;

  update public.kb_documents
  set status = 'index_queued',
      last_error = null,
      last_error_stage = null
  where id = p_document_id
  returning status
  into v_document.status;

  if found and v_job.status = 'failed'::public.kb_job_status then
    v_job_id := v_job.id;
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
          'request_reindex'
        )
    where id = v_job_id;
  else
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
      'index',
      'queued',
      'kb_index_queue',
      jsonb_build_object('reason', p_reason, 'trigger', 'request_reindex')
    )
    on conflict (document_id, document_version, stage)
    where status in ('queued', 'running', 'failed')
    do update
    set updated_at = now()
    returning id
    into v_job_id;
  end if;

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

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.reindex_requested',
    p_document_id,
    null,
    '{}'::jsonb,
    p_request_id,
    jsonb_build_object('job_id', v_job_id, 'msg_id', v_msg_id, 'reason', p_reason)
  );

  return query
  select
    p_document_id,
    v_job_id,
    v_msg_id,
    false,
    'reindex_queued'::text,
    'index_queued'::public.kb_document_status;
end;
$$;

create or replace function public.request_reparse(
  p_document_id uuid,
  p_actor_id uuid,
  p_reason text,
  p_request_id text default null
)
returns table (
  document_id uuid,
  job_id uuid,
  msg_id bigint,
  document_version integer,
  previous_document_version integer,
  already_applied boolean,
  result_code text,
  status public.kb_document_status
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_previous_version integer;
  v_job_id uuid;
  v_msg_id bigint;
  v_cancelled record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reparse reason is required';
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
        'requested_action', 'reparse'
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

  if v_document.deleted_at is not null then
    raise exception 'deleted document % cannot be reparsed', p_document_id;
  end if;

  if v_document.raw_uri is null then
    raise exception 'document % is missing raw_uri for reparse', p_document_id;
  end if;

  for v_cancelled in
    update public.kb_jobs
    set status = 'cancelled',
        locked_by = null,
        locked_until = null,
        finished_at = now(),
        last_error = 'cancelled by reparse request'
    where document_id = p_document_id
      and stage in ('parse', 'index')
      and status in ('queued', 'running', 'failed')
    returning id, pgmq_queue, pgmq_msg_id
  loop
    perform public.kb_archive_job_message_by_id(v_cancelled.pgmq_queue, v_cancelled.pgmq_msg_id);
  end loop;

  v_previous_version := v_document.document_version;

  update public.kb_documents
  set document_version = document_version + 1,
      status = 'parse_queued',
      processed_manifest_local_uri = null,
      processed_manifest_s3_key = null,
      processed_manifest_hash = null,
      processed_artifact_uuid = null,
      processed_s3_ready_at = null,
      chunk_count = null,
      parse_time = null,
      index_time = null,
      opensearch_indexed = false,
      pinecone_indexed = false,
      last_error = null,
      last_error_stage = null,
      metadata_json = coalesce(metadata_json, '{}'::jsonb) || jsonb_build_object(
        'reparse',
        jsonb_build_object(
          'requested_at',
          now(),
          'previous_document_version',
          v_previous_version,
          'reason',
          p_reason
        )
      )
  where id = p_document_id
  returning *
  into v_document;

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
    'parse',
    'queued',
    'kb_parse_queue',
    jsonb_build_object(
      'reason',
      p_reason,
      'trigger',
      'request_reparse',
      'previous_document_version',
      v_previous_version,
      'raw_uri',
      v_document.raw_uri
    )
  )
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

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.reparse_requested',
    p_document_id,
    null,
    jsonb_build_object(
      'document_version',
      v_document.document_version,
      'previous_document_version',
      v_previous_version
    ),
    p_request_id,
    jsonb_build_object('job_id', v_job_id, 'msg_id', v_msg_id, 'reason', p_reason)
  );

  return query
  select
    p_document_id,
    v_job_id,
    v_msg_id,
    v_document.document_version,
    v_previous_version,
    false,
    'reparse_queued'::text,
    'parse_queued'::public.kb_document_status;
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
        'kb_archive_job_message_by_id',
        'request_delete',
        'complete_delete',
        'request_retry',
        'request_reindex',
        'request_reparse'
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
