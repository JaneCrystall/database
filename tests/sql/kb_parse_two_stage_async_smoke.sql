begin;

insert into kb_collections (name, path, content_type)
values ('F03 Two Stage Async Smoke', '/smoke/f03-two-stage-async', 'papers')
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
  claim_row record;
  registered record;
  finalizer_claim record;
  ok boolean;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f03-two-stage-async';

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
    collection_id::text || ':two-stage-async',
    'two-stage-async.pdf',
    '.pdf',
    128,
    repeat('a', 64),
    actor_id,
    actor_id
  )
  returning id into document_id;

  select job_id, msg_id
  into parse_job_id, parse_msg_id
  from mark_raw_ready_and_enqueue_parse(
    document_id,
    'nas://kb/raw/smoke/two-stage-async.pdf',
    128,
    repeat('a', 64),
    actor_id,
    'smoke-two-stage-async',
    '{}'::jsonb
  );

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
  from claim_job_from_pgmq_message(
    parse_job_id,
    'kb_parse_queue',
    parse_read_msg_id,
    'smoke-submitter',
    1800
  );

  if claim_row.claim_status <> 'claimed' then
    raise exception 'expected parse claim, got %', row_to_json(claim_row);
  end if;

  select *
  into registered
  from register_parse_two_stage_task(
    parse_job_id,
    'smoke-submitter',
    'celery-task-1',
    'http://unstructure.test/two_stage/task',
    'http://unstructure.test/two_stage/task/celery-task-1',
    'kb_parse_queue',
    parse_read_msg_id,
    1800,
    jsonb_build_object(
      'queues', jsonb_build_object('queue_parse_gpu', 0),
      'unacked', jsonb_build_object('queue_parse_gpu', 0)
    )
  );

  if registered.task_id <> 'celery-task-1' then
    raise exception 'two-stage task registration failed: %', row_to_json(registered);
  end if;

  select *
  into finalizer_claim
  from claim_parse_two_stage_task('smoke-finalizer', 1800);

  if finalizer_claim.job_id <> parse_job_id
     or finalizer_claim.task_id <> 'celery-task-1' then
    raise exception 'two-stage finalizer claim failed: %', row_to_json(finalizer_claim);
  end if;

  select mark_parse_two_stage_task_state(
    parse_job_id,
    'smoke-finalizer',
    'STARTED',
    null,
    1800
  )
  into ok;

  if not ok then
    raise exception 'mark_parse_two_stage_task_state returned false';
  end if;

  if exists (
    select 1
    from kb_jobs
    where id = parse_job_id
      and payload_json #>> '{two_stage,state}' <> 'STARTED'
  ) then
    raise exception 'two-stage state was not persisted';
  end if;
end $$;

rollback;
