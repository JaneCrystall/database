begin;

do $$
declare
  course_partition_id uuid;
  parent_collection_id uuid;
  child_collection_id uuid;
  actor_id uuid := gen_random_uuid();
  smoke_document_id uuid;
  resolved record;
begin
  select id
  into course_partition_id
  from public.kb_search_partitions
  where key = 'course'
    and status = 'active';

  if course_partition_id is null then
    raise exception 'course search partition was not seeded';
  end if;

  insert into public.kb_collections (
    name,
    path,
    content_type,
    search_partition_id
  )
  values (
    'Course Partition Smoke',
    '/course/smoke',
    'course',
    course_partition_id
  )
  on conflict (path) do update
  set name = excluded.name,
      content_type = excluded.content_type,
      search_partition_id = excluded.search_partition_id
  returning id into parent_collection_id;

  insert into public.kb_collections (
    name,
    parent_id,
    path,
    content_type,
    search_partition_id
  )
  values (
    'Course Partition Smoke Child',
    parent_collection_id,
    '/course/smoke/child',
    'course',
    null
  )
  on conflict (path) do update
  set name = excluded.name,
      parent_id = excluded.parent_id,
      content_type = excluded.content_type,
      search_partition_id = excluded.search_partition_id
  returning id into child_collection_id;

  insert into public.kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    status,
    processed_manifest_s3_key,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':partition',
    'course.pdf',
    '.pdf',
    repeat('f', 64),
    'completed',
    'processed/course/smoke/manifest.json',
    actor_id,
    actor_id
  )
  returning id into smoke_document_id;

  select *
  into resolved
  from public.resolve_document_search_partition(smoke_document_id);

  if resolved.key <> 'course'
     or resolved.opensearch_write_alias <> 'kb_course_write'
     or resolved.pinecone_index_name <> 'tiangong'
     or resolved.pinecone_namespace <> 'kb_course_v1' then
    raise exception 'document search partition was not resolved to course target: %', resolved;
  end if;

  insert into public.kb_index_records (
    document_id,
    document_version,
    chunk_id,
    chunk_index,
    record_id,
    search_partition_id,
    opensearch_index_name,
    pinecone_index_name,
    pinecone_namespace
  )
  values (
    smoke_document_id,
    1,
    'chunk_0',
    0,
    smoke_document_id::text || '_0',
    course_partition_id,
    'kb_course_write',
    'tiangong',
    'kb_course_v1'
  );

  if not exists (
    select 1
    from public.kb_index_records
    where document_id = smoke_document_id
      and search_partition_id = course_partition_id
      and chunk_index = 0
      and opensearch_index_name = 'kb_course_write'
      and pinecone_index_name = 'tiangong'
      and pinecone_namespace = 'kb_course_v1'
  ) then
    raise exception 'index record target fields were not stored';
  end if;
end $$;

rollback;
