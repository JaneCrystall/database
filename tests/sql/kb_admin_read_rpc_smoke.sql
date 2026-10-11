begin;

insert into kb_collections (name, path, content_type)
values ('F09 Admin Smoke', '/smoke/f09-admin', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

insert into kb_collections (name, parent_id, path, content_type)
select 'F09 Admin Smoke Child', id, '/smoke/f09-admin/child', 'papers'
from kb_collections
where path = '/smoke/f09-admin'
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type,
    parent_id = excluded.parent_id;

do $$
#variable_conflict use_variable
declare
  root_collection_id uuid;
  child_collection_id uuid;
  support_actor_id uuid := gen_random_uuid();
  operator_actor_id uuid := gen_random_uuid();
  admin_actor_id uuid := gen_random_uuid();
  owner_actor_id uuid := gen_random_uuid();
  outsider_actor_id uuid := gen_random_uuid();
  read_document_id uuid;
  private_document_id uuid;
  owner_document_id uuid;
  deleted_document_id uuid;
  result_count integer;
  expected_dead_count bigint;
  health_dead_count bigint;
  ignored_dead_count bigint;
  expected_stale_running_count bigint;
  two_stage_running_count bigint;
  caps record;
  detail record;
  health record;
  ok boolean;
begin
  select id into root_collection_id
  from kb_collections
  where path = '/smoke/f09-admin';

  select id into child_collection_id
  from kb_collections
  where path = '/smoke/f09-admin/child';

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    visibility,
    raw_uri,
    processed_manifest_local_uri,
    processed_manifest_s3_key,
    metadata_json,
    metadata_status,
    metadata_confidence,
    last_error,
    last_error_stage,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    'f09-admin:' || gen_random_uuid()::text || ':read',
    'low-confidence.pdf',
    '.pdf',
    128,
    repeat('9', 64),
    'failed',
    'private',
    'nas://kb/raw/smoke/f09/low-confidence.pdf',
    'nas://kb/processed/smoke/f09/low-confidence/manifest.json',
    'processed/smoke/f09/low-confidence/manifest.json',
    jsonb_build_object('title', 'Needs Review'),
    'low_confidence',
    0.4200,
    'parser confidence below threshold',
    'parse',
    gen_random_uuid(),
    gen_random_uuid()
  )
  returning id into read_document_id;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    visibility,
    raw_uri,
    metadata_status,
    created_by,
    owner_user_id
  )
  values (
    root_collection_id,
    'f09-admin:' || gen_random_uuid()::text || ':private',
    'private.pdf',
    '.pdf',
    64,
    repeat('8', 64),
    'completed',
    'private',
    'nas://kb/raw/smoke/f09/private.pdf',
    'extracted',
    gen_random_uuid(),
    gen_random_uuid()
  )
  returning id into private_document_id;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    visibility,
    raw_uri,
    metadata_status,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    'f09-admin:' || gen_random_uuid()::text || ':owner',
    'owned.pdf',
    '.pdf',
    96,
    repeat('7', 64),
    'completed',
    'private',
    'nas://kb/raw/smoke/f09/owned.pdf',
    'extracted',
    owner_actor_id,
    owner_actor_id
  )
  returning id into owner_document_id;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    visibility,
    raw_uri,
    metadata_status,
    created_by,
    owner_user_id,
    deleted_at,
    deleted_by,
    delete_generation,
    delete_requested_at,
    delete_completed_at
  )
  values (
    child_collection_id,
    'f09-admin:' || gen_random_uuid()::text || ':deleted',
    'deleted.pdf',
    '.pdf',
    32,
    repeat('6', 64),
    'deleted',
    'private',
    'nas://kb/raw/smoke/f09/deleted.pdf',
    'extracted',
    gen_random_uuid(),
    gen_random_uuid(),
    now(),
    admin_actor_id,
    1,
    now(),
    now()
  )
  returning id into deleted_document_id;

  perform create_kb_grant(
    admin_actor_id,
    'collection',
    child_collection_id,
    'user',
    support_actor_id,
    array['read'::kb_grant_action],
    null,
    'f09-support-read'
  );

  perform create_kb_grant(
    admin_actor_id,
    'collection',
    child_collection_id,
    'user',
    operator_actor_id,
    array['reindex'::kb_grant_action],
    null,
    'f09-operator-reindex'
  );

  perform create_kb_grant(
    admin_actor_id,
    'collection',
    child_collection_id,
    'user',
    admin_actor_id,
    array['delete'::kb_grant_action],
    null,
    'f09-admin-delete'
  );

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    priority,
    attempt_count,
    max_attempts,
    last_error,
    payload_json,
    finished_at
  )
  values (
    read_document_id,
    1,
    'parse',
    'failed',
    10,
    2,
    3,
    'parse smoke failure',
    jsonb_build_object('source', 'f09-smoke'),
    now()
  );

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    priority,
    attempt_count,
    max_attempts,
    locked_by,
    locked_until,
    payload_json,
    started_at
  )
  values (
    read_document_id,
    1,
    'index',
    'running',
    20,
    1,
    3,
    'f09-worker',
    now() - interval '5 minutes',
    jsonb_build_object('source', 'f09-smoke'),
    now() - interval '10 minutes'
  );

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    priority,
    attempt_count,
    max_attempts,
    last_error,
    payload_json,
    finished_at
  )
  values (
    deleted_document_id,
    1,
    'parse',
    'dead',
    10,
    3,
    3,
    'historical deleted document dead job',
    jsonb_build_object('source', 'f09-smoke-deleted-dead'),
    now() - interval '1 hour'
  );

  insert into kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    priority,
    attempt_count,
    max_attempts,
    locked_by,
    locked_until,
    payload_json,
    started_at
  )
  values (
    private_document_id,
    1,
    'parse',
    'running',
    10,
    1,
    3,
    'f09-two-stage-submitter',
    now() - interval '5 minutes',
    jsonb_build_object(
      'two_stage',
      jsonb_build_object(
        'task_id', 'f09-two-stage-task',
        'state', 'STARTED',
        'submitted_at', now() - interval '10 minutes'
      )
    ),
    now() - interval '10 minutes'
  );

  perform write_kb_audit_event(
    support_actor_id,
    'kb.smoke.event',
    read_document_id,
    child_collection_id,
    jsonb_build_object('resource_type', 'document', 'resource_id', read_document_id),
    'f09-audit-list',
    jsonb_build_object('source', 'f09-smoke')
  );

  select * into caps
  from get_kb_admin_capabilities(support_actor_id);

  if not caps.can_view_console or not caps.can_view_documents or not caps.can_view_jobs
     or not caps.can_view_audit_events or caps.can_retry or caps.can_delete or caps.role <> 'support' then
    raise exception 'support capabilities were not scoped as expected: %', row_to_json(caps);
  end if;

  select * into caps
  from get_kb_admin_capabilities(operator_actor_id);

  if not caps.can_view_console or not caps.can_view_documents or not caps.can_retry or not caps.can_reindex
     or not caps.can_review_metadata or not caps.can_view_health or caps.role <> 'operator' then
    raise exception 'operator capabilities were not scoped as expected: %', row_to_json(caps);
  end if;

  select * into caps
  from get_kb_admin_capabilities(admin_actor_id);

  if not caps.can_view_console or not caps.can_delete or not caps.can_view_health or caps.role <> 'admin' then
    raise exception 'admin capabilities were not scoped as expected: %', row_to_json(caps);
  end if;

  select * into caps
  from get_kb_admin_capabilities(outsider_actor_id);

  if caps.can_view_console or caps.can_view_documents or caps.can_view_jobs
     or caps.can_view_audit_events or caps.role <> 'none' then
    raise exception 'outsider should not have admin capabilities: %', row_to_json(caps);
  end if;

  select count(*) into result_count
  from list_kb_admin_documents(support_actor_id, '{}'::jsonb, 25, 0)
  where id = read_document_id;

  if result_count <> 1 then
    raise exception 'support actor should see readable document';
  end if;

  select count(*) into result_count
  from list_kb_admin_documents(support_actor_id, '{}'::jsonb, 25, 0)
  where id = private_document_id;

  if result_count <> 0 then
    raise exception 'support actor should not see unrelated private document';
  end if;

  select count(*) into result_count
  from list_kb_admin_documents(
    support_actor_id,
    jsonb_build_object(
      'metadata_status', 'low_confidence',
      'metadata_confidence_lte', 0.5,
      'q', 'low-confidence'
    ),
    25,
    0,
    'metadata_confidence',
    'asc'
  )
  where id = read_document_id
    and total_count >= 1;

  if result_count <> 1 then
    raise exception 'document metadata/q filters should find low-confidence document';
  end if;

  select count(*) into result_count
  from list_kb_admin_documents(owner_actor_id, '{}'::jsonb, 25, 0)
  where id = owner_document_id;

  if result_count <> 1 then
    raise exception 'owner actor should see owned document without grant';
  end if;

  select count(*) into result_count
  from list_kb_admin_documents(admin_actor_id, jsonb_build_object('include_deleted', true), 25, 0)
  where id = deleted_document_id;

  if result_count <> 1 then
    raise exception 'admin actor should see deleted documents when include_deleted is true';
  end if;

  select count(*) into result_count
  from list_kb_admin_jobs(operator_actor_id, jsonb_build_object('failed_only', true), 25, 0)
  where document_id = read_document_id
    and stage = 'parse'
    and status = 'failed';

  if result_count <> 1 then
    raise exception 'operator should see failed jobs for managed document';
  end if;

  select count(*) into result_count
  from list_kb_admin_jobs(operator_actor_id, jsonb_build_object('stale_running', true), 25, 0)
  where document_id = read_document_id
    and stage = 'index'
    and status = 'running';

  if result_count <> 1 then
    raise exception 'operator should see stale running jobs';
  end if;

  select * into detail
  from get_kb_admin_document_detail(operator_actor_id, read_document_id);

  if detail.document_json->>'original_filename' <> 'low-confidence.pdf'
     or jsonb_array_length(detail.jobs_json) <> 2 then
    raise exception 'document detail did not include expected document and jobs: %', row_to_json(detail);
  end if;

  select review_kb_document_metadata(
    support_actor_id,
    read_document_id,
    jsonb_build_object('title', 'Denied Review'),
    'extracted',
    0.9000,
    'support should not review metadata',
    'f09-review-denied'
  )
  into ok;

  if ok then
    raise exception 'support actor should not be allowed to review metadata';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where document_id = read_document_id
      and action = 'kb.auth_denied'
      and request_id = 'f09-review-denied'
  ) then
    raise exception 'metadata review authorization denial was not audited';
  end if;

  select review_kb_document_metadata(
    operator_actor_id,
    read_document_id,
    jsonb_build_object('title', 'Reviewed Title', 'authors', jsonb_build_array('Smoke Author')),
    'extracted',
    0.8800,
    'confirmed extracted title and author',
    'f09-review-allowed'
  )
  into ok;

  if not ok then
    raise exception 'operator actor should be allowed to review metadata';
  end if;

  if not exists (
    select 1
    from kb_documents
    where id = read_document_id
      and metadata_status = 'extracted'
      and metadata_confidence = 0.8800
      and metadata_json->>'title' = 'Reviewed Title'
      and metadata_reviewed_by = operator_actor_id
      and metadata_reviewed_at is not null
      and metadata_review_note = 'confirmed extracted title and author'
  ) then
    raise exception 'metadata review did not persist expected fields';
  end if;

  if not exists (
    select 1
    from list_kb_admin_audit_events(
      support_actor_id,
      jsonb_build_object('document_id', read_document_id, 'request_id', 'f09-audit-list'),
      25,
      0
    )
    where action = 'kb.smoke.event'
  ) then
    raise exception 'support actor should see audit events for readable document';
  end if;

  select count(*) into result_count
  from get_kb_admin_health(support_actor_id);

  if result_count <> 0 then
    raise exception 'support actor should not see admin health';
  end if;

  select * into health
  from get_kb_admin_health(operator_actor_id);

  if health.health_json is null
     or not (health.health_json ?& array[
       'checked_at',
       'documents_by_status',
       'jobs_by_stage_status',
       'failed_jobs_24h',
       'stale_running_jobs',
       'retry_backlog',
       'ignored_deleted_dead_jobs',
       'two_stage_running_parse_jobs',
       'queue_depths',
       'latest_job_activity'
     ]) then
    raise exception 'operator health payload is missing expected fields: %', row_to_json(health);
  end if;

  if not ((health.health_json->'queue_depths') ? 'kb_s3_ready_queue') then
    raise exception 'operator health payload is missing s3-ready queue depth: %', row_to_json(health);
  end if;

  select count(*)::bigint into expected_dead_count
  from kb_jobs j
  left join kb_documents d on d.id = j.document_id
  where j.status = 'dead'
    and d.status is distinct from 'deleted'::kb_document_status;

  select coalesce(sum((item->>'count')::bigint), 0)::bigint into health_dead_count
  from jsonb_array_elements(health.health_json->'jobs_by_stage_status') item
  where item->>'status' = 'dead';

  if health_dead_count <> expected_dead_count then
    raise exception 'admin health should exclude deleted-document dead jobs from jobs_by_stage_status, expected %, got %: %',
      expected_dead_count,
      health_dead_count,
      health.health_json;
  end if;

  if ((health.health_json->'retry_backlog'->>'dead_job_count')::bigint) <> expected_dead_count then
    raise exception 'admin health should exclude deleted-document dead jobs from retry_backlog: %', health.health_json;
  end if;

  select count(*)::bigint into ignored_dead_count
  from kb_jobs j
  join kb_documents d on d.id = j.document_id
  where j.status = 'dead'
    and d.status = 'deleted'::kb_document_status;

  if ((health.health_json->'ignored_deleted_dead_jobs'->>'count')::bigint) <> ignored_dead_count
     or ignored_dead_count < 1 then
    raise exception 'admin health should report ignored deleted-document dead jobs separately: %', health.health_json;
  end if;

  select count(*)::bigint into expected_stale_running_count
  from kb_jobs j
  where j.status = 'running'
    and j.locked_until < now()
    and not exists (
      select 1
      from kb_jobs t
      join kb_documents d on d.id = t.document_id
      where t.id = j.id
        and t.stage = 'parse'
        and t.status = 'running'
        and d.deleted_at is null
        and t.payload_json #>> '{two_stage,task_id}' is not null
        and coalesce(t.payload_json #>> '{two_stage,state}', '') not in ('SUCCESS', 'FAILURE', 'REVOKED')
    );

  if (health.health_json->>'stale_running_jobs')::bigint <> expected_stale_running_count then
    raise exception 'admin health should exclude active two-stage parse jobs from stale running pressure: %', health.health_json;
  end if;

  select count(*)::bigint into two_stage_running_count
  from kb_jobs j
  join kb_documents d on d.id = j.document_id
  where j.stage = 'parse'
    and j.status = 'running'
    and d.deleted_at is null
    and j.payload_json #>> '{two_stage,task_id}' is not null;

  if ((health.health_json->'two_stage_running_parse_jobs'->>'count')::bigint) <> two_stage_running_count
     or two_stage_running_count < 1 then
    raise exception 'admin health should report two-stage running parse jobs separately: %', health.health_json;
  end if;
end;
$$;

rollback;
