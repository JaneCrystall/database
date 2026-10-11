begin;

insert into kb_collections (name, path, content_type)
values ('F06 Lifecycle Smoke', '/smoke/f06-lifecycle', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
#variable_conflict use_variable
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
  smoke_document_id uuid;
  delete_job_id uuid;
  delete_msg_id bigint;
  delete_read_msg_id bigint;
  delete_generation integer;
  reindex_job_id uuid;
  reindex_msg_id bigint;
  retry_msg_id bigint;
  reparse_job_id uuid;
  reparse_msg_id bigint;
  previous_version integer;
  current_version integer;
  result_count integer;
  ok boolean;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f06-lifecycle';

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    raw_uri,
    processed_manifest_s3_key,
    created_by,
    owner_user_id
  )
  values (
    collection_id,
    collection_id::text || ':delete',
    'delete.pdf',
    '.pdf',
    128,
    repeat('d', 64),
    'completed',
    'nas://kb/raw/smoke/f06/delete.pdf',
    'processed/smoke/f06/delete/manifest.json',
    actor_id,
    actor_id
  )
  returning id into smoke_document_id;

  perform create_kb_grant(
    actor_id,
    'document',
    smoke_document_id,
    'user',
    actor_id,
    array['delete'::kb_grant_action, 'reindex'::kb_grant_action],
    null,
    'f06-grant'
  );

  insert into kb_index_records (
    document_id,
    document_version,
    chunk_id,
    record_id,
    opensearch_index_name,
    pinecone_index_name,
    pinecone_namespace
  )
  values (
    smoke_document_id,
    1,
    'chunk_0',
    smoke_document_id::text || ':v1:chunk_0',
    'kb_chunks_write',
    'tiangong',
    'kb_chunks_v1'
  );

  select job_id, msg_id, request_delete.delete_generation
  into delete_job_id, delete_msg_id, delete_generation
  from request_delete(smoke_document_id, actor_id, 'f06 delete', 'f06-delete');

  if delete_job_id is null or delete_msg_id is null or delete_generation <> 1 then
    raise exception 'request_delete did not return expected job/message/generation';
  end if;

  select count(*)
  into result_count
  from request_delete(smoke_document_id, actor_id, 'f06 delete again', 'f06-delete-again')
  where already_applied = false
    and job_id = delete_job_id;

  if result_count <> 1 then
    raise exception 'repeated request_delete before completion should reuse the active delete job';
  end if;

  select msg_id
  into delete_read_msg_id
  from pgmq.read(
    'kb_delete_queue',
    1800,
    1,
    jsonb_build_object('job_id', delete_job_id::text)
  )
  limit 1;

  perform start_job_from_pgmq_message(
    delete_job_id,
    'kb_delete_queue',
    delete_read_msg_id,
    'f06-delete-worker',
    1800
  );

  if complete_delete(
    delete_job_id,
    'f06-delete-worker',
    smoke_document_id,
    1,
    delete_generation + 1,
    '{}'::jsonb
  ) then
    raise exception 'complete_delete should reject stale delete_generation';
  end if;

  ok := complete_delete(
    delete_job_id,
    'f06-delete-worker',
    smoke_document_id,
    1,
    delete_generation,
    jsonb_build_object('opensearch', 'ok', 'pinecone', 'ok')
  );

  if not ok then
    raise exception 'complete_delete should succeed';
  end if;

  if not exists (
    select 1
    from kb_documents
    where id = smoke_document_id
      and status = 'deleted'
      and delete_completed_at is not null
      and opensearch_indexed = false
      and pinecone_indexed = false
  ) then
    raise exception 'complete_delete did not mark document deleted';
  end if;

  if not exists (
    select 1
    from kb_index_records
    where document_id = smoke_document_id
      and deleted_at is not null
  ) then
    raise exception 'complete_delete did not tombstone index records';
  end if;

  select count(*)
  into result_count
  from request_delete(smoke_document_id, actor_id, 'already deleted', 'f06-delete-after-complete')
  where already_applied = true
    and result_code = 'already_deleted';

  if result_count <> 1 then
    raise exception 'request_delete should be idempotent after deleted';
  end if;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    file_size,
    sha256,
    status,
    raw_uri,
    processed_manifest_s3_key,
    created_by,
    owner_user_id
  )
  values (
    collection_id,
    collection_id::text || ':reindex',
    'reindex.pdf',
    '.pdf',
    256,
    repeat('e', 64),
    'completed',
    'nas://kb/raw/smoke/f06/reindex.pdf',
    'processed/smoke/f06/reindex/manifest.json',
    actor_id,
    actor_id
  )
  returning id into smoke_document_id;

  perform create_kb_grant(
    actor_id,
    'document',
    smoke_document_id,
    'user',
    actor_id,
    array['reindex'::kb_grant_action],
    null,
    'f06-reindex-grant'
  );

  select job_id, msg_id
  into reindex_job_id, reindex_msg_id
  from request_reindex(smoke_document_id, actor_id, 'f06 reindex', 'f06-reindex');

  if reindex_job_id is null or reindex_msg_id is null then
    raise exception 'request_reindex did not enqueue an index job';
  end if;

  select count(*)
  into result_count
  from request_reindex(smoke_document_id, actor_id, 'f06 reindex duplicate', 'f06-reindex-duplicate')
  where already_applied = true
    and job_id = reindex_job_id;

  if result_count <> 1 then
    raise exception 'request_reindex should return active index job without duplicate enqueue';
  end if;

  update kb_jobs
  set status = 'failed',
      last_error = 'manual retry smoke'
  where id = reindex_job_id;

  select msg_id
  into retry_msg_id
  from request_retry(smoke_document_id, actor_id, 'index', 'f06 retry index', 'f06-retry-index');

  if retry_msg_id is null then
    raise exception 'request_retry should requeue a failed index job';
  end if;

  select document_version
  into previous_version
  from kb_documents
  where id = smoke_document_id;

  select job_id, msg_id, request_reparse.document_version, request_reparse.previous_document_version
  into reparse_job_id, reparse_msg_id, current_version, previous_version
  from request_reparse(smoke_document_id, actor_id, 'f06 reparse', 'f06-reparse');

  if reparse_job_id is null or reparse_msg_id is null then
    raise exception 'request_reparse did not enqueue parse job';
  end if;

  if current_version <> previous_version + 1 then
    raise exception 'request_reparse should increment document_version';
  end if;

  if not exists (
    select 1
    from kb_documents
    where id = smoke_document_id
      and status = 'parse_queued'
      and processed_manifest_s3_key is null
      and opensearch_indexed = false
      and pinecone_indexed = false
  ) then
    raise exception 'request_reparse did not reset processed/index fields';
  end if;
end $$;

rollback;
