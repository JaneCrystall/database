begin;

insert into kb_collections (name, path, content_type)
values ('F01 Race Smoke', '/smoke/f01-race', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
#variable_conflict use_variable
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
  other_actor_id uuid := gen_random_uuid();
  claim_count integer;
  result_count integer;
  row_count integer;
  ok boolean;

  race_document_id uuid;
  race_job_id uuid;
  race_msg_id bigint;
  race_duplicate_msg_id bigint;
  race_read_msg_id bigint;

  stale_parse_document_id uuid;
  stale_parse_job_id uuid;
  stale_parse_msg_id bigint;
  stale_parse_read_msg_id bigint;

  stale_claim_document_id uuid;
  stale_claim_job_id uuid;
  stale_claim_msg_id bigint;
  stale_claim_read_msg_id bigint;

  deleted_claim_document_id uuid;
  deleted_claim_job_id uuid;
  deleted_claim_msg_id bigint;
  deleted_claim_read_msg_id bigint;

  deleted_parse_document_id uuid;
  deleted_parse_job_id uuid;
  deleted_parse_msg_id bigint;
  deleted_parse_read_msg_id bigint;

  stale_index_document_id uuid;
  stale_index_job_id uuid;
  stale_index_msg_id bigint;
  stale_index_read_msg_id bigint;

  delete_document_id uuid;
  delete_parse_job_id uuid;
  delete_index_job_id uuid;
  delete_job_id uuid;
  delete_msg_id bigint;

  denied_document_id uuid;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f01-race';

  -- Duplicate queue messages cannot claim the same job while the first worker
  -- owns a valid lock. After the lock expires, another worker can reclaim it.
  insert into kb_documents (
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
    collection_id::text || ':duplicate-claim',
    'duplicate-claim.pdf',
    '.pdf',
    128,
    repeat('a', 64),
    actor_id,
    actor_id
  )
  returning id into race_document_id;

  select job_id, msg_id
  into race_job_id, race_msg_id
  from mark_raw_ready_and_enqueue_parse(
    race_document_id,
    'nas://kb/raw/smoke/race/duplicate-claim.pdf',
    128,
    repeat('a', 64),
    actor_id,
    'race-parse',
    '{}'::jsonb
  );

  select sent.msg_id
  into race_duplicate_msg_id
  from pgmq.send(
    'kb_parse_queue',
    jsonb_build_object('job_id', race_job_id::text)
  ) as sent(msg_id)
  limit 1;

  select msg_id
  into race_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', race_job_id::text)
  )
  limit 1;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    race_job_id,
    'kb_parse_queue',
    race_read_msg_id,
    'race-worker-a',
    1800
  );

  if claim_count <> 1 then
    raise exception 'expected first worker claim to succeed, got %', claim_count;
  end if;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    race_job_id,
    'kb_parse_queue',
    race_duplicate_msg_id,
    'race-worker-b',
    1800
  );

  if claim_count <> 0 then
    raise exception 'duplicate message should not claim while lock is valid';
  end if;

  if (
    select attempt_count
    from kb_jobs
    where id = race_job_id
  ) <> 1 then
    raise exception 'duplicate failed claim should not increment attempt_count';
  end if;

  update kb_jobs
  set locked_until = now() - interval '1 minute'
  where id = race_job_id;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    race_job_id,
    'kb_parse_queue',
    race_duplicate_msg_id,
    'race-worker-b',
    1800
  );

  if claim_count <> 1 then
    raise exception 'expired lock should allow reclaim, got %', claim_count;
  end if;

  if not exists (
    select 1
    from kb_jobs
    where id = race_job_id
      and locked_by = 'race-worker-b'
      and attempt_count = 2
  ) then
    raise exception 'reclaimed job did not record new worker and attempt_count';
  end if;

  if heartbeat_job(race_job_id, 'race-worker-a', 1800, 1800) then
    raise exception 'previous worker heartbeat should fail after reclaim';
  end if;

  if not heartbeat_job(race_job_id, 'race-worker-b', 1800, 1800) then
    raise exception 'current worker heartbeat should succeed';
  end if;

  select count(*)
  into result_count
  from fail_job(
    race_job_id,
    'race-worker-b',
    true,
    'race retryable failure',
    'parse'
  ) as failed
  where failed.job_status = 'failed'
    and failed.document_status = 'parse_queued';

  if result_count <> 1 then
    raise exception 'retryable fail should move job to failed and document to parse_queued';
  end if;

  update kb_jobs
  set next_retry_at = now() - interval '1 second'
  where id = race_job_id;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    race_job_id,
    'kb_parse_queue',
    race_duplicate_msg_id,
    'race-worker-c',
    1800
  );

  if claim_count <> 1 then
    raise exception 'failed job should be claimable for retry, got %', claim_count;
  end if;

  select count(*)
  into result_count
  from fail_job(
    race_job_id,
    'race-worker-c',
    true,
    'race terminal failure',
    'parse'
  ) as failed
  where failed.job_status = 'dead';

  if result_count <> 1 then
    raise exception 'retryable fail at max_attempts should move job to dead';
  end if;

  -- Claim must reject stale document versions before exposing a worker snapshot.
  insert into kb_documents (
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
    collection_id::text || ':stale-claim',
    'stale-claim.pdf',
    '.pdf',
    128,
    repeat('1', 64),
    actor_id,
    actor_id
  )
  returning id into stale_claim_document_id;

  select job_id, msg_id
  into stale_claim_job_id, stale_claim_msg_id
  from mark_raw_ready_and_enqueue_parse(
    stale_claim_document_id,
    'nas://kb/raw/smoke/race/stale-claim.pdf',
    128,
    repeat('1', 64),
    actor_id,
    'race-stale-claim',
    '{}'::jsonb
  );

  update kb_documents
  set document_version = document_version + 1
  where id = stale_claim_document_id;

  select msg_id
  into stale_claim_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', stale_claim_job_id::text)
  )
  limit 1;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    stale_claim_job_id,
    'kb_parse_queue',
    stale_claim_read_msg_id,
    'race-stale-claim-worker',
    1800
  );

  if claim_count <> 0 then
    raise exception 'stale document version should not return a parse claim snapshot';
  end if;

  if not exists (
    select 1
    from kb_jobs
    where id = stale_claim_job_id
      and status = 'cancelled'
      and last_error = 'document version changed before claim'
  ) then
    raise exception 'stale document version should cancel job before claim';
  end if;

  -- Claim must reject deleted parse documents before exposing a worker snapshot.
  insert into kb_documents (
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
    collection_id::text || ':deleted-claim',
    'deleted-claim.pdf',
    '.pdf',
    128,
    repeat('2', 64),
    actor_id,
    actor_id
  )
  returning id into deleted_claim_document_id;

  select job_id, msg_id
  into deleted_claim_job_id, deleted_claim_msg_id
  from mark_raw_ready_and_enqueue_parse(
    deleted_claim_document_id,
    'nas://kb/raw/smoke/race/deleted-claim.pdf',
    128,
    repeat('2', 64),
    actor_id,
    'race-deleted-claim',
    '{}'::jsonb
  );

  update kb_documents
  set deleted_at = now()
  where id = deleted_claim_document_id;

  select msg_id
  into deleted_claim_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', deleted_claim_job_id::text)
  )
  limit 1;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    deleted_claim_job_id,
    'kb_parse_queue',
    deleted_claim_read_msg_id,
    'race-deleted-claim-worker',
    1800
  );

  if claim_count <> 0 then
    raise exception 'deleted parse document should not return a claim snapshot';
  end if;

  if not exists (
    select 1
    from kb_jobs
    where id = deleted_claim_job_id
      and status = 'cancelled'
      and last_error = 'document was deleted before claim'
  ) then
    raise exception 'deleted parse document should cancel job before claim';
  end if;

  -- Parse completion must reject stale document_version.
  insert into kb_documents (
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
    collection_id::text || ':stale-parse',
    'stale-parse.pdf',
    '.pdf',
    128,
    repeat('b', 64),
    actor_id,
    actor_id
  )
  returning id into stale_parse_document_id;

  select job_id, msg_id
  into stale_parse_job_id, stale_parse_msg_id
  from mark_raw_ready_and_enqueue_parse(
    stale_parse_document_id,
    'nas://kb/raw/smoke/race/stale-parse.pdf',
    128,
    repeat('b', 64),
    actor_id,
    'race-stale-parse',
    '{}'::jsonb
  );

  select msg_id
  into stale_parse_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', stale_parse_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    stale_parse_job_id,
    'kb_parse_queue',
    stale_parse_read_msg_id,
    'race-stale-parse-worker',
    1800
  );

  if mark_parse_local_ready(
    stale_parse_job_id,
    'wrong-worker',
    stale_parse_document_id,
    1,
    'nas://kb/processed/smoke/race/stale-parse/manifest.json',
    gen_random_uuid(),
    repeat('c', 64),
    1,
    '{}'::jsonb
  ) then
    raise exception 'local ready should reject wrong worker';
  end if;

  if mark_processed_s3_ready(
    stale_parse_job_id,
    'wrong-worker',
    stale_parse_document_id,
    1,
    'processed/smoke/race/stale-parse/manifest.json',
    repeat('c', 64),
    gen_random_uuid(),
    'nas://kb/processed/smoke/race/stale-parse/manifest.json',
    1
  ) then
    raise exception 'processed s3 ready should reject wrong worker';
  end if;

  if mark_processed_s3_ready(
    stale_parse_job_id,
    'race-stale-parse-worker',
    stale_parse_document_id,
    999,
    'processed/smoke/race/stale-parse/manifest.json',
    repeat('c', 64),
    gen_random_uuid(),
    'nas://kb/processed/smoke/race/stale-parse/manifest.json',
    1
  ) then
    raise exception 'stale parse document_version should be rejected';
  end if;

  if exists (
    select 1
    from kb_documents
    where id = stale_parse_document_id
      and status = 'processed_s3_ready'
  ) then
    raise exception 'stale parse completion should not mark processed_s3_ready';
  end if;

  -- Parse completion must reject documents deleted after claim.
  insert into kb_documents (
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
    collection_id::text || ':deleted-parse',
    'deleted-parse.pdf',
    '.pdf',
    128,
    repeat('d', 64),
    actor_id,
    actor_id
  )
  returning id into deleted_parse_document_id;

  select job_id, msg_id
  into deleted_parse_job_id, deleted_parse_msg_id
  from mark_raw_ready_and_enqueue_parse(
    deleted_parse_document_id,
    'nas://kb/raw/smoke/race/deleted-parse.pdf',
    128,
    repeat('d', 64),
    actor_id,
    'race-deleted-parse',
    '{}'::jsonb
  );

  select msg_id
  into deleted_parse_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', deleted_parse_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    deleted_parse_job_id,
    'kb_parse_queue',
    deleted_parse_read_msg_id,
    'race-deleted-parse-worker',
    1800
  );

  update kb_documents
  set deleted_at = now()
  where id = deleted_parse_document_id;

  if mark_processed_s3_ready(
    deleted_parse_job_id,
    'race-deleted-parse-worker',
    deleted_parse_document_id,
    1,
    'processed/smoke/race/deleted-parse/manifest.json',
    repeat('e', 64),
    gen_random_uuid(),
    'nas://kb/processed/smoke/race/deleted-parse/manifest.json',
    1
  ) then
    raise exception 'deleted parse document should reject processed completion';
  end if;

  -- Index completion must reject stale versions and deleted documents.
  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    processed_manifest_s3_key,
    created_by,
    owner_user_id
  )
  values (
    collection_id,
    collection_id::text || ':stale-index',
    'stale-index.pdf',
    '.pdf',
    128,
    repeat('f', 64),
    'processed_s3_ready',
    'processed/smoke/race/stale-index/manifest.json',
    actor_id,
    actor_id
  )
  returning id into stale_index_document_id;

  select job_id, msg_id
  into stale_index_job_id, stale_index_msg_id
  from enqueue_index_from_processed_s3_ready(
    stale_index_document_id,
    actor_id,
    'race-index',
    '{}'::jsonb
  );

  select msg_id
  into stale_index_read_msg_id
  from pgmq.read(
    'kb_index_queue',
    1800,
    1,
    jsonb_build_object('job_id', stale_index_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    stale_index_job_id,
    'kb_index_queue',
    stale_index_read_msg_id,
    'race-index-worker',
    1800
  );

  if complete_index(stale_index_job_id, 'race-index-worker', stale_index_document_id, 999) then
    raise exception 'stale index document_version should be rejected';
  end if;

  if exists (
    select 1
    from kb_documents
    where id = stale_index_document_id
      and status = 'completed'
  ) then
    raise exception 'stale index completion should not mark completed';
  end if;

  update kb_documents
  set deleted_at = now()
  where id = stale_index_document_id;

  if complete_index(stale_index_job_id, 'race-index-worker', stale_index_document_id, 1) then
    raise exception 'deleted index document should reject completion';
  end if;

  if exists (
    select 1
    from kb_documents
    where id = stale_index_document_id
      and status = 'completed'
  ) then
    raise exception 'deleted index document should not be completed';
  end if;

  -- Delete must synchronously tombstone the document and cancel pending or
  -- running parse/index work before old workers can write completion.
  insert into kb_documents (
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
    collection_id::text || ':delete-cancel',
    'delete-cancel.pdf',
    '.pdf',
    128,
    repeat('9', 64),
    other_actor_id,
    other_actor_id
  )
  returning id into delete_document_id;

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    locked_by,
    locked_until
  )
  values (
    delete_document_id,
    1,
    'parse',
    'running',
    'old-parse-worker',
    now() + interval '30 minutes'
  )
  returning id into delete_parse_job_id;

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status
  )
  values (
    delete_document_id,
    1,
    'index',
    'queued'
  )
  returning id into delete_index_job_id;

  select count(*)
  into result_count
  from request_delete(
    delete_document_id,
    actor_id,
    'denied delete race',
    'race-delete-denied'
  );

  if result_count <> 0 then
    raise exception 'unauthorized delete should return no rows';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where kb_audit_events.actor_id = actor_id
      and kb_audit_events.action = 'kb.auth_denied'
      and kb_audit_events.document_id = delete_document_id
      and kb_audit_events.request_id = 'race-delete-denied'
  ) then
    raise exception 'unauthorized delete should write auth_denied audit';
  end if;

  perform create_kb_grant(
    actor_id,
    'document',
    delete_document_id,
    'user',
    actor_id,
    array['delete'::kb_grant_action],
    null,
    'race-delete-grant'
  );

  select job_id, msg_id
  into delete_job_id, delete_msg_id
  from request_delete(
    delete_document_id,
    actor_id,
    'allowed delete race',
    'race-delete-allowed'
  );

  if delete_job_id is null or delete_msg_id is null then
    raise exception 'authorized delete should enqueue delete job';
  end if;

  if not exists (
    select 1
    from kb_documents
    where id = delete_document_id
      and status = 'delete_queued'
      and deleted_at is not null
  ) then
    raise exception 'delete should tombstone document synchronously';
  end if;

  if exists (
    select 1
    from kb_jobs
    where id in (delete_parse_job_id, delete_index_job_id)
      and status <> 'cancelled'
  ) then
    raise exception 'delete should cancel pending/running parse and index jobs';
  end if;

  if mark_processed_s3_ready(
    delete_parse_job_id,
    'old-parse-worker',
    delete_document_id,
    1,
    'processed/smoke/race/delete-cancel/manifest.json',
    repeat('7', 64),
    gen_random_uuid(),
    'nas://kb/processed/smoke/race/delete-cancel/manifest.json',
    1
  ) then
    raise exception 'cancelled parse job should not complete after delete';
  end if;

  if complete_index(delete_index_job_id, 'old-index-worker', delete_document_id, 1) then
    raise exception 'cancelled index job should not complete after delete';
  end if;

  select count(*)
  into row_count
  from fail_job(
    delete_parse_job_id,
    'old-parse-worker',
    true,
    'old worker failure after delete',
    'parse'
  );

  if row_count <> 0 then
    raise exception 'cancelled old parse job should not accept fail_job updates';
  end if;
end $$;

rollback;
