begin;

do $$
declare
  course_partition_id uuid;
  general_partition_id uuid;
  parent_collection_id uuid;
  child_collection_id uuid;
  general_collection_id uuid;
  result_count integer;
begin
  select id into course_partition_id
  from public.kb_search_partitions
  where key = 'course';

  select id into general_partition_id
  from public.kb_search_partitions
  where key = 'general';

  if course_partition_id is null or general_partition_id is null then
    raise exception 'required search partition seeds are missing';
  end if;

  insert into public.kb_collections (
    name,
    path,
    content_type,
    search_partition_id
  )
  values (
    'Query Partition Smoke Course',
    '/course/query-smoke',
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
    'Query Partition Smoke Course Child',
    parent_collection_id,
    '/course/query-smoke/child',
    'course',
    null
  )
  on conflict (path) do update
  set name = excluded.name,
      parent_id = excluded.parent_id,
      content_type = excluded.content_type,
      search_partition_id = excluded.search_partition_id
  returning id into child_collection_id;

  insert into public.kb_collections (
    name,
    path,
    content_type,
    search_partition_id
  )
  values (
    'Query Partition Smoke General',
    '/general/query-smoke',
    'general',
    general_partition_id
  )
  on conflict (path) do update
  set name = excluded.name,
      content_type = excluded.content_type,
      search_partition_id = excluded.search_partition_id
  returning id into general_collection_id;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(null, true, false)
  where key in ('course', 'general')
    and status = 'active';

  if result_count < 2 then
    raise exception 'global query partition resolver did not return active course/general partitions';
  end if;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(array[parent_collection_id], true, false)
  where key = 'course'
    and opensearch_read_alias = 'kb_course_read'
    and pinecone_index_name = 'tiangong'
    and pinecone_namespace = 'kb_course_v1';

  if result_count <> 1 then
    raise exception 'course subtree query partition did not resolve to course target';
  end if;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(array[child_collection_id], false, false)
  where key = 'course';

  if result_count <> 1 then
    raise exception 'child collection query partition did not inherit course target';
  end if;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(
    array[parent_collection_id, general_collection_id],
    true,
    false
  );

  if result_count <> 2 then
    raise exception 'multi-collection query partition did not deduplicate partition targets';
  end if;

  update public.kb_search_partitions
  set status = 'paused'
  where id = course_partition_id;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(array[parent_collection_id], true, false)
  where key = 'course';

  if result_count <> 0 then
    raise exception 'active query partition resolver should exclude paused partitions';
  end if;

  select count(*)
  into result_count
  from public.resolve_query_search_partitions(array[parent_collection_id], true, true)
  where key = 'course'
    and status = 'paused';

  if result_count <> 1 then
    raise exception 'include inactive query partition resolver should return paused partitions';
  end if;
end $$;

rollback;
