alter table public.kb_jobs
  add column if not exists retry_wakeup_msg_id bigint;

create index if not exists kb_jobs_retry_wakeup_idx
on public.kb_jobs (retry_wakeup_msg_id)
where retry_wakeup_msg_id is not null;

alter table public.kb_index_records
  add column if not exists opensearch_write_alias text,
  add column if not exists opensearch_concrete_index text,
  add column if not exists index_schema_version text,
  add column if not exists embedding_model text,
  add column if not exists write_job_id uuid references public.kb_jobs(id) on delete set null,
  add column if not exists target_facts_history jsonb not null default '[]'::jsonb;

update public.kb_index_records r
set opensearch_write_alias = coalesce(
      r.opensearch_write_alias,
      r.opensearch_index_name,
      (
        select p.opensearch_write_alias
        from public.kb_search_partitions p
        where p.id = r.search_partition_id
      )
    ),
    opensearch_concrete_index = coalesce(
      r.opensearch_concrete_index,
      (
        select p.opensearch_concrete_index
        from public.kb_search_partitions p
        where p.id = r.search_partition_id
      )
    ),
    index_schema_version = coalesce(
      r.index_schema_version,
      (
        select p.index_schema_version
        from public.kb_search_partitions p
        where p.id = r.search_partition_id
      )
    ),
    embedding_model = coalesce(
      r.embedding_model,
      (
        select p.embedding_model
        from public.kb_search_partitions p
        where p.id = r.search_partition_id
      )
    ),
    write_job_id = coalesce(r.write_job_id, r.job_id)
where r.opensearch_write_alias is null
   or r.opensearch_concrete_index is null
   or r.index_schema_version is null
   or r.embedding_model is null
   or r.write_job_id is null;

create index if not exists kb_index_records_active_document_target_idx
on public.kb_index_records (
  document_id,
  document_version,
  search_partition_id,
  opensearch_write_alias,
  opensearch_concrete_index,
  pinecone_index_name,
  pinecone_namespace
)
where deleted_at is null;

drop index if exists public.kb_index_records_record_id_idx;

create unique index if not exists kb_index_records_active_target_record_idx
on public.kb_index_records (
  document_id,
  document_version,
  record_id,
  search_partition_id,
  opensearch_concrete_index,
  pinecone_index_name,
  pinecone_namespace
)
where deleted_at is null
  and search_partition_id is not null
  and opensearch_concrete_index is not null
  and pinecone_index_name is not null
  and pinecone_namespace is not null;

create or replace function public.archive_job_message_by_id(
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
  if p_queue is null or p_queue = '' or p_msg_id is null then
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
      'already_running'::text,
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

    update public.kb_documents
    set status = case v_job.stage
          when 'delete'::public.kb_job_stage then 'delete_queued'::public.kb_document_status
          else 'failed'::public.kb_document_status
        end,
        last_error = coalesce(v_job.last_error, 'max attempts reached before claim'),
        last_error_stage = v_job.stage
    where id = v_job.document_id
      and document_version = v_job.document_version;

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
language sql
security definer
set search_path = public, pgmq, pg_temp
as $$
  select
    c.job_id,
    c.document_id,
    c.document_version,
    c.stage,
    c.status,
    c.payload_json,
    c.raw_uri,
    c.file_ext,
    c.file_size,
    c.sha256,
    c.collection_path
  from public.claim_job_from_pgmq_message(
    p_job_id,
    p_queue,
    p_msg_id,
    p_worker_id,
    p_lock_seconds
  ) c
  where c.claim_status = 'claimed'
$$;

drop function if exists public.fail_job(uuid, text, boolean, text, public.kb_job_stage);

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

create or replace function public.fail_job(
  p_job_id uuid,
  p_worker_id text,
  p_retryable boolean,
  p_error text,
  p_error_stage public.kb_job_stage default null
)
returns table (job_id uuid, job_status public.kb_job_status, document_status public.kb_document_status)
language sql
security definer
set search_path = public, pgmq, pg_temp
as $$
  select f.job_id, f.job_status, f.document_status
  from public.fail_job_v2(p_job_id, p_worker_id, p_retryable, p_error, p_error_stage) f
$$;

create or replace function public.enqueue_due_retry_wakeups(p_limit integer default 100)
returns table (
  job_id uuid,
  pgmq_queue text,
  next_retry_at timestamptz,
  retry_wakeup_msg_id bigint,
  enqueued boolean
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_job record;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_queue text;
  v_msg_id bigint;
  v_message_exists boolean;
begin
  for v_job in
    select j.*
    from public.kb_jobs j
    where j.status = 'failed'::public.kb_job_status
      and j.next_retry_at is not null
      and j.next_retry_at <= now()
    order by j.next_retry_at, j.priority desc, j.created_at
    limit v_limit
    for update skip locked
  loop
    v_queue := public.kb_queue_for_stage(v_job.stage);
    v_message_exists := false;

    if v_job.retry_wakeup_msg_id is not null and v_queue is not null then
      begin
        execute format(
          'select exists (select 1 from pgmq.%I where msg_id = $1)',
          'q_' || v_queue
        )
        using v_job.retry_wakeup_msg_id
        into v_message_exists;
      exception
        when undefined_table then
          v_message_exists := false;
      end;
    end if;

    if v_queue is null then
      v_msg_id := null;
    elsif v_job.retry_wakeup_msg_id is null or not v_message_exists then
      select pgmq.send(
        v_queue,
        jsonb_build_object(
          'job_id', v_job.id::text,
          'message_kind', 'retry_wakeup',
          'next_retry_at', v_job.next_retry_at
        ),
        0
      )
      into v_msg_id;

      update public.kb_jobs
      set retry_wakeup_msg_id = v_msg_id
      where id = v_job.id;
    else
      v_msg_id := v_job.retry_wakeup_msg_id;
    end if;

    job_id := v_job.id;
    pgmq_queue := v_queue;
    next_retry_at := v_job.next_retry_at;
    retry_wakeup_msg_id := v_msg_id;
    enqueued := v_queue is not null and (v_job.retry_wakeup_msg_id is null or not v_message_exists);
    return next;
  end loop;
end;
$$;

create or replace function public.upsert_kb_index_records(
  p_job_id uuid,
  p_document_id uuid,
  p_document_version integer,
  p_records jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array' then
    raise exception 'p_records must be a JSON array';
  end if;

  if jsonb_array_length(p_records) > 1000 then
    raise exception 'p_records exceeds maximum batch size of 1000';
  end if;

  with parsed as (
    select
      p_job_id as job_id,
      p_job_id as write_job_id,
      p_document_id as document_id,
      p_document_version as document_version,
      item->>'chunk_id' as chunk_id,
      (item->>'chunk_index')::integer as chunk_index,
      item->>'record_id' as record_id,
      (item->>'search_partition_id')::uuid as search_partition_id,
      coalesce(item->>'opensearch_write_alias', item->>'opensearch_index_name') as opensearch_write_alias,
      coalesce(item->>'opensearch_concrete_index', item->>'opensearch_index_name') as opensearch_concrete_index,
      coalesce(item->>'opensearch_index_name', item->>'opensearch_write_alias') as opensearch_index_name,
      item->>'pinecone_index_name' as pinecone_index_name,
      item->>'pinecone_namespace' as pinecone_namespace,
      coalesce(item->>'index_schema_version', 'v1') as index_schema_version,
      item->>'embedding_model' as embedding_model
    from jsonb_array_elements(p_records) as item
  ),
  validated as (
    select *
    from parsed
    where chunk_id is not null and chunk_id <> ''
      and chunk_index is not null and chunk_index >= 0
      and record_id is not null and record_id <> ''
      and search_partition_id is not null
      and opensearch_write_alias is not null and opensearch_write_alias <> ''
      and opensearch_concrete_index is not null and opensearch_concrete_index <> ''
      and pinecone_index_name is not null and pinecone_index_name <> ''
      and pinecone_namespace is not null and pinecone_namespace <> ''
  ),
  inserted as (
    insert into public.kb_index_records (
      job_id,
      write_job_id,
      document_id,
      document_version,
      chunk_id,
      chunk_index,
      record_id,
      search_partition_id,
      opensearch_index_name,
      opensearch_write_alias,
      opensearch_concrete_index,
      pinecone_index_name,
      pinecone_namespace,
      index_schema_version,
      embedding_model,
      indexed_at,
      deleted_at
    )
    select
      job_id,
      write_job_id,
      document_id,
      document_version,
      chunk_id,
      chunk_index,
      record_id,
      search_partition_id,
      opensearch_index_name,
      opensearch_write_alias,
      opensearch_concrete_index,
      pinecone_index_name,
      pinecone_namespace,
      index_schema_version,
      embedding_model,
      now(),
      null
    from validated
    on conflict (
      document_id,
      document_version,
      record_id,
      search_partition_id,
      opensearch_concrete_index,
      pinecone_index_name,
      pinecone_namespace
    )
    where deleted_at is null
      and search_partition_id is not null
      and opensearch_concrete_index is not null
      and pinecone_index_name is not null
      and pinecone_namespace is not null
    do update
    set job_id = excluded.job_id,
        write_job_id = excluded.write_job_id,
        chunk_id = excluded.chunk_id,
        chunk_index = excluded.chunk_index,
        opensearch_index_name = excluded.opensearch_index_name,
        opensearch_write_alias = excluded.opensearch_write_alias,
        index_schema_version = excluded.index_schema_version,
        embedding_model = excluded.embedding_model,
        indexed_at = now(),
        deleted_at = null
    returning 1
  )
  select count(*) into v_count from inserted;

  if v_count <> jsonb_array_length(p_records) then
    raise exception 'one or more index records were invalid';
  end if;

  return v_count;
end;
$$;

create or replace function public.list_active_kb_index_records(
  p_document_id uuid,
  p_document_version integer default null
)
returns table (
  record_id text,
  chunk_id text,
  chunk_index integer,
  document_id uuid,
  document_version integer,
  search_partition_id uuid,
  opensearch_index_name text,
  opensearch_write_alias text,
  opensearch_concrete_index text,
  pinecone_index_name text,
  pinecone_namespace text,
  index_schema_version text,
  embedding_model text,
  indexed_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    r.record_id,
    r.chunk_id,
    r.chunk_index,
    r.document_id,
    r.document_version,
    r.search_partition_id,
    r.opensearch_index_name,
    r.opensearch_write_alias,
    r.opensearch_concrete_index,
    r.pinecone_index_name,
    r.pinecone_namespace,
    r.index_schema_version,
    r.embedding_model,
    r.indexed_at
  from public.kb_index_records r
  where r.document_id = p_document_id
    and (p_document_version is null or r.document_version = p_document_version)
    and r.deleted_at is null
  order by r.document_version desc, r.chunk_index, r.record_id;
$$;

create or replace function public.mark_kb_index_records_deleted(
  p_document_id uuid,
  p_record_ids text[],
  p_document_version integer default null,
  p_job_id uuid default null,
  p_record_refs jsonb default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  if p_record_ids is null or array_length(p_record_ids, 1) is null then
    return 0;
  end if;

  if p_record_refs is not null then
    if jsonb_typeof(p_record_refs) <> 'array' then
      raise exception 'p_record_refs must be a JSON array when provided';
    end if;

    with refs as (
      select
        item->>'record_id' as record_id,
        nullif(item->>'opensearch_concrete_index', '') as opensearch_concrete_index,
        nullif(item->>'pinecone_index_name', '') as pinecone_index_name,
        nullif(item->>'pinecone_namespace', '') as pinecone_namespace
      from jsonb_array_elements(p_record_refs) as item
    )
    update public.kb_index_records r
    set deleted_at = coalesce(r.deleted_at, now()),
        job_id = coalesce(p_job_id, r.job_id)
    from refs
    where r.document_id = p_document_id
      and r.record_id = refs.record_id
      and (p_document_version is null or r.document_version = p_document_version)
      and (refs.opensearch_concrete_index is null or r.opensearch_concrete_index = refs.opensearch_concrete_index)
      and (refs.pinecone_index_name is null or r.pinecone_index_name = refs.pinecone_index_name)
      and (refs.pinecone_namespace is null or r.pinecone_namespace = refs.pinecone_namespace)
      and r.deleted_at is null;

    get diagnostics v_count = row_count;
    return v_count;
  end if;

  update public.kb_index_records
  set deleted_at = coalesce(deleted_at, now()),
      job_id = coalesce(p_job_id, job_id)
  where document_id = p_document_id
    and record_id = any(p_record_ids)
    and (p_document_version is null or document_version = p_document_version)
    and deleted_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.count_active_kb_index_records(
  p_document_id uuid,
  p_document_version integer default null
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.kb_index_records r
  where r.document_id = p_document_id
    and (p_document_version is null or r.document_version = p_document_version)
    and r.deleted_at is null;
$$;

create or replace function public.get_kb_admin_health(p_actor_id uuid)
returns table (health_json jsonb)
language plpgsql
stable
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_caps record;
begin
  select *
  into v_caps
  from public.get_kb_admin_capabilities(p_actor_id)
  limit 1;

  if coalesce(v_caps.can_view_health, false) is false then
    return;
  end if;

  return query
  select jsonb_build_object(
    'checked_at', now(),
    'documents_by_status', coalesce((
      select jsonb_object_agg(status::text, count)
      from (
        select status, count(*)::bigint
        from public.kb_documents
        group by status
      ) s
    ), '{}'::jsonb),
    'jobs_by_stage_status', coalesce((
      select jsonb_agg(jsonb_build_object('stage', stage, 'status', status, 'count', count))
      from (
        select stage, status, count(*)::bigint
        from public.kb_jobs
        group by stage, status
        order by stage, status
      ) s
    ), '[]'::jsonb),
    'failed_jobs_24h', (
      select count(*)::bigint
      from public.kb_jobs
      where status in ('failed'::public.kb_job_status, 'dead'::public.kb_job_status)
        and updated_at >= now() - interval '24 hours'
    ),
    'stale_running_jobs', (
      select count(*)::bigint
      from public.kb_jobs
      where status = 'running'::public.kb_job_status
        and locked_until < now()
    ),
    'retry_backlog', jsonb_build_object(
      'due_count', (
        select count(*)::bigint
        from public.kb_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at <= now()
      ),
      'future_count', (
        select count(*)::bigint
        from public.kb_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at > now()
      ),
      'dead_job_count', (
        select count(*)::bigint
        from public.kb_jobs
        where status = 'dead'::public.kb_job_status
      ),
      'oldest_due_retry_at', (
        select min(next_retry_at)
        from public.kb_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at <= now()
      ),
      'by_stage', coalesce((
        select jsonb_object_agg(stage::text, jsonb_build_object('due', due_count, 'future', future_count, 'dead', dead_count))
        from (
          select
            stage,
            count(*) filter (where status = 'failed'::public.kb_job_status and next_retry_at <= now())::bigint as due_count,
            count(*) filter (where status = 'failed'::public.kb_job_status and next_retry_at > now())::bigint as future_count,
            count(*) filter (where status = 'dead'::public.kb_job_status)::bigint as dead_count
          from public.kb_jobs
          group by stage
        ) s
      ), '{}'::jsonb)
    ),
    'queue_depths', jsonb_build_object(
      'kb_parse_queue', public.kb_queue_depth('kb_parse_queue'),
      'kb_s3_ready_queue', public.kb_queue_depth('kb_s3_ready_queue'),
      'kb_index_queue', public.kb_queue_depth('kb_index_queue'),
      'kb_delete_queue', public.kb_queue_depth('kb_delete_queue')
    ),
    'latest_job_activity', coalesce((
      select jsonb_object_agg(stage::text, latest_updated_at)
      from (
        select stage, max(updated_at) as latest_updated_at
        from public.kb_jobs
        group by stage
      ) s
    ), '{}'::jsonb)
  ) as health_json;
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
        'archive_job_message_by_id',
        'claim_job_from_pgmq_message',
        'fail_job',
        'enqueue_due_retry_wakeups',
        'upsert_kb_index_records',
        'list_active_kb_index_records',
        'mark_kb_index_records_deleted',
        'count_active_kb_index_records',
        'get_kb_admin_health'
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
