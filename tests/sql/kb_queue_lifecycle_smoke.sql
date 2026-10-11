begin;

insert into kb_collections (name, path, content_type)
values ('F01 Queue Smoke', '/smoke/f01-queue', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
  document_id uuid;
  parse_job_id uuid;
  parse_msg_id bigint;
  parse_read_msg_id bigint;
  s3_ready_job_id uuid;
  s3_ready_msg_id bigint;
  queued_job_id uuid;
  queued_msg_id bigint;
  s3_ready_read_msg_id bigint;
  index_job_id uuid;
  index_msg_id bigint;
  index_read_msg_id bigint;
  delete_job_id uuid;
  delete_msg_id bigint;
  dead_document_id uuid;
  dead_job_id uuid;
  dead_msg_id bigint;
  claim_count integer;
  ok boolean;
  current_status kb_document_status;
  current_job_status kb_job_status;
  artifact_uuid uuid := gen_random_uuid();
  claim_row record;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f01-queue';

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
    collection_id::text || ':queue',
    'queue-smoke.pdf',
    '.pdf',
    128,
    repeat('b', 64),
    actor_id,
    actor_id
  )
  returning id into document_id;

  select job_id, msg_id
  into parse_job_id, parse_msg_id
  from mark_raw_ready_and_enqueue_parse(
    document_id,
    'nas://kb/raw/smoke/queue-smoke.pdf',
    128,
    repeat('b', 64),
    actor_id,
    'smoke-parse',
    jsonb_build_object('source', 'smoke')
  );

  if parse_job_id is null or parse_msg_id is null then
    raise exception 'parse enqueue did not return job/message ids';
  end if;

  select msg_id
  into parse_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', parse_job_id::text)
  )
  limit 1;

  if parse_read_msg_id is null then
    raise exception 'parse queue message was not readable';
  end if;

  select *
  into claim_row
  from start_job_from_pgmq_message(
    parse_job_id,
    'kb_parse_queue',
    parse_read_msg_id,
    'smoke-worker',
    1800
  );

  if claim_row.job_id is null then
    raise exception 'expected first parse claim to succeed';
  end if;

  if claim_row.raw_uri <> 'nas://kb/raw/smoke/queue-smoke.pdf'
     or claim_row.file_ext <> '.pdf'
     or claim_row.file_size <> 128
     or claim_row.sha256 <> repeat('b', 64)
     or claim_row.collection_path <> '/smoke/f01-queue' then
    raise exception 'parse claim snapshot did not include expected raw/document/collection fields: %', row_to_json(claim_row);
  end if;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    parse_job_id,
    'kb_parse_queue',
    parse_read_msg_id,
    'smoke-worker-2',
    1800
  );

  if claim_count <> 0 then
    raise exception 'duplicate parse claim unexpectedly succeeded';
  end if;

  select heartbeat_job(parse_job_id, 'smoke-worker', 1800, 1800)
  into ok;

  if not ok then
    raise exception 'heartbeat failed';
  end if;

  select c.s3_ready_job_id, c.s3_ready_msg_id
  into s3_ready_job_id, s3_ready_msg_id
  from complete_parse_local_ready_and_enqueue_s3_check(
    parse_job_id,
    'smoke-worker',
    document_id,
    1,
    'nas://kb/processed/smoke/queue-smoke/manifest.json',
    artifact_uuid,
    repeat('c', 64),
    7,
    jsonb_build_object('parser_profile', 'smoke'),
    jsonb_build_object('source', 'smoke')
  ) c;

  if s3_ready_job_id is null or s3_ready_msg_id is null then
    raise exception 'complete_parse_local_ready_and_enqueue_s3_check did not enqueue s3_ready';
  end if;

  select c.s3_ready_job_id, c.s3_ready_msg_id
  into queued_job_id, queued_msg_id
  from complete_parse_local_ready_and_enqueue_s3_check(
    parse_job_id,
    'smoke-worker',
    document_id,
    1,
    'nas://kb/processed/smoke/queue-smoke/manifest.json',
    artifact_uuid,
    repeat('c', 64),
    7,
    jsonb_build_object('parser_profile', 'smoke'),
    jsonb_build_object('source', 'smoke')
  ) c;

  if queued_job_id <> s3_ready_job_id or queued_msg_id <> s3_ready_msg_id then
    raise exception 'parse local-ready retry was not idempotent';
  end if;

  select status
  into current_status
  from kb_documents
  where id = document_id;

  if current_status <> 's3_sync_pending' then
    raise exception 'expected s3_sync_pending after local ready, got %', current_status;
  end if;

  select status
  into current_job_status
  from kb_jobs
  where id = parse_job_id;

  if current_job_status <> 'succeeded' then
    raise exception 'expected parse job succeeded after local ready handoff, got %', current_job_status;
  end if;

  select archive_job_message(parse_job_id)
  into ok;

  if not ok then
    raise exception 'archive parse message failed';
  end if;

  select msg_id
  into s3_ready_read_msg_id
  from pgmq.read(
    'kb_s3_ready_queue',
    1800,
    1,
    jsonb_build_object('job_id', s3_ready_job_id::text)
  )
  limit 1;

  if s3_ready_read_msg_id is null then
    raise exception 's3_ready queue message was not readable';
  end if;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    s3_ready_job_id,
    'kb_s3_ready_queue',
    s3_ready_read_msg_id,
    'smoke-s3-ready-worker',
    1800
  );

  if claim_count <> 1 then
    raise exception 'expected s3_ready claim to succeed, got %', claim_count;
  end if;

  select complete_s3_ready_check(
    s3_ready_job_id,
    'smoke-s3-ready-worker',
    document_id,
    1,
    'processed/smoke/queue-smoke/manifest.json',
    repeat('c', 64),
    artifact_uuid,
    'nas://kb/processed/smoke/queue-smoke/manifest.json',
    7
  )
  into ok;

  if not ok then
    raise exception 'complete_s3_ready_check failed';
  end if;

  select complete_s3_ready_check(
    s3_ready_job_id,
    'smoke-s3-ready-worker',
    document_id,
    1,
    'processed/smoke/queue-smoke/manifest.json',
    repeat('c', 64),
    artifact_uuid,
    'nas://kb/processed/smoke/queue-smoke/manifest.json',
    7
  )
  into ok;

  if not ok then
    raise exception 'complete_s3_ready_check replay was not idempotent';
  end if;

  select status
  into current_status
  from kb_documents
  where id = document_id;

  if current_status <> 'processed_s3_ready' then
    raise exception 'expected processed_s3_ready, got %', current_status;
  end if;

  select archive_job_message(s3_ready_job_id)
  into ok;

  if not ok then
    raise exception 'archive s3_ready message failed';
  end if;

  select job_id, msg_id
  into index_job_id, index_msg_id
  from enqueue_index_from_processed_s3_ready(
    document_id,
    actor_id,
    'smoke-index',
    jsonb_build_object('source', 'smoke')
  );

  if index_job_id is null or index_msg_id is null then
    raise exception 'index enqueue did not return job/message ids';
  end if;

  select msg_id
  into index_read_msg_id
  from pgmq.read(
    'kb_index_queue',
    1800,
    1,
    jsonb_build_object('job_id', index_job_id::text)
  )
  limit 1;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    index_job_id,
    'kb_index_queue',
    index_read_msg_id,
    'smoke-index-worker',
    1800
  );

  if claim_count <> 1 then
    raise exception 'expected index claim to succeed, got %', claim_count;
  end if;

  select complete_index(index_job_id, 'smoke-index-worker', document_id, 1)
  into ok;

  if not ok then
    raise exception 'complete_index failed';
  end if;

  select status
  into current_status
  from kb_documents
  where id = document_id;

  if current_status <> 'completed' then
    raise exception 'expected completed, got %', current_status;
  end if;

  perform archive_job_message(index_job_id);

  perform create_kb_grant(
    actor_id,
    'document',
    document_id,
    'user',
    actor_id,
    array['delete'::kb_grant_action],
    null,
    'smoke-delete-grant'
  );

  select job_id, msg_id
  into delete_job_id, delete_msg_id
  from request_delete(document_id, actor_id, 'smoke delete', 'smoke-delete');

  if delete_job_id is null or delete_msg_id is null then
    raise exception 'delete request did not return job/message ids';
  end if;

  select status
  into current_status
  from kb_documents
  where id = document_id;

  if current_status <> 'delete_queued' then
    raise exception 'expected delete_queued, got %', current_status;
  end if;

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
    collection_id::text || ':dead',
    'dead-smoke.pdf',
    '.pdf',
    128,
    repeat('d', 64),
    actor_id,
    actor_id
  )
  returning id into dead_document_id;

  select job_id, msg_id
  into dead_job_id, dead_msg_id
  from mark_raw_ready_and_enqueue_parse(
    dead_document_id,
    'nas://kb/raw/smoke/dead-smoke.pdf',
    128,
    repeat('d', 64),
    actor_id,
    'smoke-dead',
    '{}'::jsonb
  );

  update kb_jobs
  set max_attempts = 1
  where id = dead_job_id;

  select msg_id
  into dead_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', dead_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    dead_job_id,
    'kb_parse_queue',
    dead_msg_id,
    'smoke-dead-worker',
    1800
  );

  perform *
  from fail_job(
    dead_job_id,
    'smoke-dead-worker',
    true,
    'smoke terminal parse failure',
    'parse'
  );

  select status
  into current_job_status
  from kb_jobs
  where id = dead_job_id;

  if current_job_status <> 'dead' then
    raise exception 'expected dead job, got %', current_job_status;
  end if;
end $$;

rollback;
