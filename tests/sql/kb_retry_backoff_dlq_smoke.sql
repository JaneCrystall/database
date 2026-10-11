begin;

insert into kb_collections (name, path, content_type)
values ('F01 Retry Smoke', '/smoke/f01-retry', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
  retry_document_id uuid;
  retry_job_id uuid;
  retry_msg_id bigint;
  retry_read_msg_id bigint;
  terminal_document_id uuid;
  terminal_job_id uuid;
  terminal_msg_id bigint;
  terminal_read_msg_id bigint;
  max_document_id uuid;
  max_job_id uuid;
  max_msg_id bigint;
  max_read_msg_id bigint;
  claim_count integer;
  result_count integer;
  current_job_status kb_job_status;
  current_document_status kb_document_status;
  retry_at timestamptz;
  ok boolean;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f01-retry';

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
    collection_id::text || ':retry-backoff',
    'retry-backoff.pdf',
    '.pdf',
    128,
    repeat('e', 64),
    actor_id,
    actor_id
  )
  returning id into retry_document_id;

  perform create_kb_grant(
    actor_id,
    'document',
    retry_document_id,
    'user',
    actor_id,
    array['read'::kb_grant_action, 'reindex'::kb_grant_action],
    null,
    'retry-backoff-smoke'
  );

  select job_id, msg_id
  into retry_job_id, retry_msg_id
  from mark_raw_ready_and_enqueue_parse(
    retry_document_id,
    'nas://kb/raw/smoke/retry-backoff.pdf',
    128,
    repeat('e', 64),
    actor_id,
    'retry-backoff-smoke',
    '{}'::jsonb
  );

  update kb_jobs
  set max_attempts = 3
  where id = retry_job_id;

  select msg_id
  into retry_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', retry_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    retry_job_id,
    'kb_parse_queue',
    retry_read_msg_id,
    'retry-worker-a',
    1800
  );

  select count(*)
  into result_count
  from fail_job(
    retry_job_id,
    'retry-worker-a',
    true,
    'retryable parse smoke failure',
    'parse'
  ) as failed
  where failed.job_status = 'failed'
    and failed.document_status = 'parse_queued';

  if result_count <> 1 then
    raise exception 'retryable failure should move job to failed and document to parse_queued';
  end if;

  select status, next_retry_at
  into current_job_status, retry_at
  from kb_jobs
  where id = retry_job_id;

  if current_job_status <> 'failed' or retry_at is null or retry_at <= now() then
    raise exception 'retryable failure did not write future next_retry_at: status %, retry_at %', current_job_status, retry_at;
  end if;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    retry_job_id,
    'kb_parse_queue',
    retry_read_msg_id,
    'retry-worker-too-early',
    1800
  );

  if claim_count <> 0 then
    raise exception 'job should not be claimable before next_retry_at, got %', claim_count;
  end if;

  update kb_jobs
  set next_retry_at = now() - interval '1 second'
  where id = retry_job_id;

  select count(*)
  into claim_count
  from start_job_from_pgmq_message(
    retry_job_id,
    'kb_parse_queue',
    retry_read_msg_id,
    'retry-worker-b',
    1800
  );

  if claim_count <> 1 then
    raise exception 'job should be claimable after next_retry_at, got %', claim_count;
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
    collection_id::text || ':terminal-dead',
    'terminal-dead.pdf',
    '.pdf',
    128,
    repeat('f', 64),
    actor_id,
    actor_id
  )
  returning id into terminal_document_id;

  perform create_kb_grant(
    actor_id,
    'document',
    terminal_document_id,
    'user',
    actor_id,
    array['read'::kb_grant_action, 'reindex'::kb_grant_action],
    null,
    'terminal-dead-smoke'
  );

  select job_id, msg_id
  into terminal_job_id, terminal_msg_id
  from mark_raw_ready_and_enqueue_parse(
    terminal_document_id,
    'nas://kb/raw/smoke/terminal-dead.pdf',
    128,
    repeat('f', 64),
    actor_id,
    'terminal-dead-smoke',
    '{}'::jsonb
  );

  select msg_id
  into terminal_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', terminal_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    terminal_job_id,
    'kb_parse_queue',
    terminal_read_msg_id,
    'terminal-worker',
    1800
  );

  select count(*)
  into result_count
  from fail_job(
    terminal_job_id,
    'terminal-worker',
    false,
    'terminal parse smoke failure',
    'parse'
  ) as failed
  where failed.job_status = 'dead'
    and failed.document_status = 'failed';

  if result_count <> 1 then
    raise exception 'terminal failure should move job to dead and document to failed';
  end if;

  select status, next_retry_at
  into current_job_status, retry_at
  from kb_jobs
  where id = terminal_job_id;

  if current_job_status <> 'dead' or retry_at is not null then
    raise exception 'terminal dead job should not have next_retry_at: status %, retry_at %', current_job_status, retry_at;
  end if;

  select status
  into current_document_status
  from kb_documents
  where id = terminal_document_id;

  if current_document_status <> 'failed' then
    raise exception 'terminal document status should be failed, got %', current_document_status;
  end if;

  select archive_job_message(terminal_job_id)
  into ok;

  if not ok then
    raise exception 'archive_job_message should archive dead terminal job';
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
    collection_id::text || ':max-dead',
    'max-dead.pdf',
    '.pdf',
    128,
    repeat('a', 64),
    actor_id,
    actor_id
  )
  returning id into max_document_id;

  perform create_kb_grant(
    actor_id,
    'document',
    max_document_id,
    'user',
    actor_id,
    array['read'::kb_grant_action, 'reindex'::kb_grant_action],
    null,
    'max-dead-smoke'
  );

  select job_id, msg_id
  into max_job_id, max_msg_id
  from mark_raw_ready_and_enqueue_parse(
    max_document_id,
    'nas://kb/raw/smoke/max-dead.pdf',
    128,
    repeat('a', 64),
    actor_id,
    'max-dead-smoke',
    '{}'::jsonb
  );

  update kb_jobs
  set max_attempts = 1
  where id = max_job_id;

  select msg_id
  into max_read_msg_id
  from pgmq.read(
    'kb_parse_queue',
    1800,
    1,
    jsonb_build_object('job_id', max_job_id::text)
  )
  limit 1;

  perform *
  from start_job_from_pgmq_message(
    max_job_id,
    'kb_parse_queue',
    max_read_msg_id,
    'max-worker',
    1800
  );

  select count(*)
  into result_count
  from fail_job(
    max_job_id,
    'max-worker',
    true,
    'max attempts smoke failure',
    'parse'
  ) as failed
  where failed.job_status = 'dead'
    and failed.document_status = 'failed';

  if result_count <> 1 then
    raise exception 'retryable failure at max attempts should move job to dead';
  end if;

  select count(*)
  into result_count
  from list_kb_dead_letter_jobs(actor_id, 10, 0)
  where document_id in (terminal_document_id, max_document_id)
    and stage = 'parse'
    and last_error is not null
    and attempt_count > 0
    and max_attempts > 0;

  if result_count <> 2 then
    raise exception 'dead-letter RPC did not expose expected dead jobs, got %', result_count;
  end if;

  select count(*)
  into result_count
  from list_kb_admin_jobs(
    actor_id,
    jsonb_build_object('status', 'dead'),
    10,
    0,
    'next_retry_at',
    'desc'
  )
  where document_id in (terminal_document_id, max_document_id)
    and next_retry_at is null
    and last_error is not null;

  if result_count <> 2 then
    raise exception 'admin jobs RPC did not expose expected dead jobs, got %', result_count;
  end if;
end $$;

rollback;
