begin;

insert into public.kb_collections (name, path, content_type)
values ('Retry Wakeup Ledger Smoke', '/smoke/retry-wakeup-ledger', 'course')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
declare
  collection_id uuid;
  partition_id uuid;
  actor_id uuid := gen_random_uuid();
  document_id uuid;
  max_attempt_document_id uuid;
  smoke_job_id uuid;
  max_attempt_job_id uuid;
  smoke_msg_id bigint;
  max_attempt_msg_id bigint;
  read_msg_id bigint;
  wakeup_msg_id bigint;
  replay_wakeup_msg_id bigint;
  result_count integer;
  active_count integer;
  observed_job_status public.kb_job_status;
  observed_document_status public.kb_document_status;
begin
  select id into collection_id
  from public.kb_collections
  where path = '/smoke/retry-wakeup-ledger';

  select id into partition_id
  from public.kb_search_partitions
  where key = 'course';

  insert into public.kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    created_by,
    owner_user_id
  )
  values (
    collection_id,
    collection_id::text || ':retry-wakeup-ledger',
    'retry-wakeup-ledger.pdf',
    '.pdf',
    128,
    repeat('a', 64),
    actor_id,
    actor_id
  )
  returning id into document_id;

  select queued.job_id, queued.msg_id
  into smoke_job_id, smoke_msg_id
  from public.mark_raw_ready_and_enqueue_parse(
    document_id,
    'nas://kb/raw/smoke/retry-wakeup-ledger.pdf',
    128,
    repeat('a', 64),
    actor_id,
    'retry-wakeup-ledger',
    '{}'::jsonb
  ) as queued;

  select q.msg_id
  into read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', smoke_job_id::text)
  ) as q
  limit 1;

  if read_msg_id is null then
    raise exception 'parse queue did not return a message for retry smoke';
  end if;

  select count(*)
  into result_count
  from public.claim_job_from_pgmq_message(
    smoke_job_id,
    'kb_parse_queue',
    read_msg_id,
    'retry-contract-worker',
    1800
  ) as claimed
  where claimed.claim_status = 'claimed'
    and claimed.archive_current_message = false;

  if result_count <> 1 then
    raise exception 'v2 claim did not return claimed disposition';
  end if;

  select count(*)
  into result_count
  from public.claim_job_from_pgmq_message(
    smoke_job_id,
    'kb_parse_queue',
    read_msg_id + 1000000,
    'retry-contract-duplicate-worker',
    1800
  ) as duplicate
  where duplicate.claim_status = 'duplicate_running'
    and duplicate.archive_current_message = true;

  if result_count <> 1 then
    raise exception 'v2 claim did not return duplicate_running disposition';
  end if;

  select failed.retry_wakeup_msg_id
  into wakeup_msg_id
  from public.fail_job_v2(
    smoke_job_id,
    'retry-contract-worker',
    true,
    'retry contract smoke',
    'parse'
  ) as failed
  where failed.job_status = 'failed'
    and failed.next_retry_at is not null;

  if wakeup_msg_id is null then
    raise exception 'retryable fail_job did not enqueue retry wake-up';
  end if;

  select failed.retry_wakeup_msg_id
  into replay_wakeup_msg_id
  from public.fail_job_v2(
    smoke_job_id,
    'retry-contract-worker',
    true,
    'retry contract smoke',
    'parse'
  ) as failed
  where failed.job_status = 'failed'
    and failed.next_retry_at is not null;

  if replay_wakeup_msg_id <> wakeup_msg_id then
    raise exception 'fail_job_v2 replay did not return existing retry wake-up';
  end if;

  if not public.archive_job_message_by_id('kb_parse_queue', read_msg_id) then
    raise exception 'archive_job_message_by_id failed for current retry message';
  end if;

  select count(*)
  into result_count
  from public.claim_job_from_pgmq_message(
    smoke_job_id,
    'kb_parse_queue',
    read_msg_id,
    'retry-contract-too-early',
    1800
  ) as skipped
  where skipped.claim_status in ('backoff_not_due', 'retry_waiting')
    and skipped.archive_current_message = true;

  if result_count <> 1 then
    raise exception 'v2 claim did not return backoff_not_due/retry_waiting disposition';
  end if;

  update public.kb_jobs
  set next_retry_at = now() - interval '1 second',
      retry_wakeup_msg_id = null
  where id = smoke_job_id;

  select count(*)
  into result_count
  from public.enqueue_due_retry_wakeups(10) as enqueued
  where enqueued.job_id = smoke_job_id
    and enqueued.retry_wakeup_msg_id is not null;

  if result_count <> 1 then
    raise exception 'due retry reconciler did not enqueue wake-up';
  end if;

  insert into public.kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    created_by,
    owner_user_id
  )
  values (
    collection_id,
    collection_id::text || ':retry-wakeup-ledger-max-attempt',
    'retry-wakeup-ledger-max-attempt.pdf',
    '.pdf',
    256,
    repeat('b', 64),
    actor_id,
    actor_id
  )
  returning id into max_attempt_document_id;

  select queued.job_id, queued.msg_id
  into max_attempt_job_id, max_attempt_msg_id
  from public.mark_raw_ready_and_enqueue_parse(
    max_attempt_document_id,
    'nas://kb/raw/smoke/retry-wakeup-ledger-max-attempt.pdf',
    256,
    repeat('b', 64),
    actor_id,
    'retry-wakeup-ledger-max-attempt',
    '{}'::jsonb
  ) as queued;

  update public.kb_jobs
  set attempt_count = max_attempts
  where id = max_attempt_job_id;

  select count(*)
  into result_count
  from public.claim_job_from_pgmq_message(
    max_attempt_job_id,
    'kb_parse_queue',
    max_attempt_msg_id,
    'retry-contract-max-attempt-worker',
    1800
  ) as terminal
  where terminal.claim_status = 'max_attempts_reached'
    and terminal.archive_current_message = true;

  if result_count <> 1 then
    raise exception 'v2 claim did not return max_attempts_reached disposition';
  end if;

  select j.status, d.status
  into observed_job_status, observed_document_status
  from public.kb_jobs j
  join public.kb_documents d on d.id = j.document_id
  where j.id = max_attempt_job_id;

  if observed_job_status <> 'dead'::public.kb_job_status then
    raise exception 'max-attempt claim did not mark job dead';
  end if;

  if observed_document_status <> 'failed'::public.kb_document_status then
    raise exception 'max-attempt claim did not mark document failed';
  end if;

  update public.kb_documents
  set status = 'completed',
      processed_manifest_s3_key = 'processed/smoke/retry-wakeup-ledger/manifest.json'
  where id = document_id;

  active_count := public.upsert_kb_index_records(
    smoke_job_id,
    document_id,
    1,
    jsonb_build_array(
      jsonb_build_object(
        'record_id', document_id::text || '_0',
        'chunk_id', 'chunk_0',
        'chunk_index', 0,
        'search_partition_id', partition_id::text,
        'opensearch_write_alias', 'kb_course_write',
        'opensearch_concrete_index', 'kb_course_v1',
        'pinecone_index_name', 'tiangong-kb-course',
        'pinecone_namespace', 'kb_course_v1',
        'index_schema_version', 'v1',
        'embedding_model', 'text-embedding-3-small'
      )
    )
  );

  if active_count <> 1 then
    raise exception 'upsert_kb_index_records should return one inserted record';
  end if;

  active_count := public.upsert_kb_index_records(
    smoke_job_id,
    document_id,
    1,
    jsonb_build_array(
      jsonb_build_object(
        'record_id', document_id::text || '_0',
        'chunk_id', 'chunk_0',
        'chunk_index', 0,
        'search_partition_id', partition_id::text,
        'opensearch_write_alias', 'kb_course_write',
        'opensearch_concrete_index', 'kb_course_v2',
        'pinecone_index_name', 'tiangong-kb-course',
        'pinecone_namespace', 'kb_course_v2',
        'index_schema_version', 'v1',
        'embedding_model', 'text-embedding-3-small'
      )
    )
  );

  if public.count_active_kb_index_records(document_id, 1) <> 2 then
    raise exception 'ledger should preserve old target facts until cleanup succeeds';
  end if;

  active_count := public.mark_kb_index_records_deleted(
    document_id,
    array[document_id::text || '_0'],
    1,
    smoke_job_id,
    jsonb_build_array(
      jsonb_build_object(
        'record_id', document_id::text || '_0',
        'opensearch_concrete_index', 'kb_course_v1',
        'pinecone_index_name', 'tiangong-kb-course',
        'pinecone_namespace', 'kb_course_v1'
      )
    )
  );

  if active_count <> 1 then
    raise exception 'target-scoped mark deleted should delete exactly one stale record';
  end if;

  if public.count_active_kb_index_records(document_id, 1) <> 1 then
    raise exception 'target-scoped mark deleted removed the current active record';
  end if;
end $$;

rollback;
