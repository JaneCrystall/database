create or replace function public.resolve_query_search_partitions(
  p_collection_ids uuid[] default null,
  p_include_descendants boolean default true,
  p_include_inactive boolean default false
)
returns table (
  search_partition_id uuid,
  key text,
  status text,
  opensearch_read_alias text,
  opensearch_write_alias text,
  opensearch_concrete_index text,
  pinecone_index_name text,
  pinecone_namespace text,
  index_schema_version text,
  embedding_model text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with recursive requested_collections as (
    select
      c.id,
      c.parent_id,
      c.search_partition_id
    from public.kb_collections c
    where coalesce(array_length(p_collection_ids, 1), 0) > 0
      and c.id = any(p_collection_ids)
  ),
  scoped_collections as (
    select
      id,
      parent_id,
      search_partition_id
    from requested_collections

    union all

    select
      child.id,
      child.parent_id,
      child.search_partition_id
    from public.kb_collections child
    join scoped_collections parent
      on p_include_descendants
     and child.parent_id = parent.id
  ),
  collection_chain as (
    select
      id as scope_collection_id,
      id,
      parent_id,
      search_partition_id,
      0 as depth
    from scoped_collections

    union all

    select
      chain.scope_collection_id,
      parent.id,
      parent.parent_id,
      parent.search_partition_id,
      chain.depth + 1
    from public.kb_collections parent
    join collection_chain chain on chain.parent_id = parent.id
  ),
  nearest_partition_per_collection as (
    select distinct on (scope_collection_id)
      scope_collection_id,
      search_partition_id
    from collection_chain
    where search_partition_id is not null
    order by scope_collection_id, depth
  ),
  selected_partition_ids as (
    select distinct search_partition_id
    from nearest_partition_per_collection
  )
  select
    p.id,
    p.key,
    p.status,
    p.opensearch_read_alias,
    p.opensearch_write_alias,
    p.opensearch_concrete_index,
    p.pinecone_index_name,
    p.pinecone_namespace,
    p.index_schema_version,
    p.embedding_model
  from public.kb_search_partitions p
  where (
      coalesce(array_length(p_collection_ids, 1), 0) = 0
      or p.id in (select search_partition_id from selected_partition_ids)
    )
    and (p_include_inactive or p.status = 'active')
  order by p.key;
$$;

grant execute on function public.resolve_query_search_partitions(uuid[], boolean, boolean) to service_role;
