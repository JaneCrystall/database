create table if not exists public.kb_search_partitions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name text not null,
  status text not null default 'active',
  opensearch_read_alias text not null,
  opensearch_write_alias text not null,
  opensearch_concrete_index text not null,
  pinecone_index_name text not null,
  pinecone_namespace text not null,
  index_schema_version text not null default 'v1',
  embedding_model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  check (status in ('active', 'paused', 'deprecated')),
  check (opensearch_read_alias <> ''),
  check (opensearch_write_alias <> ''),
  check (opensearch_concrete_index <> ''),
  check (pinecone_index_name <> ''),
  check (pinecone_namespace <> ''),
  check (index_schema_version <> '')
);

alter table public.kb_search_partitions enable row level security;

drop trigger if exists kb_search_partitions_set_updated_at on public.kb_search_partitions;
create trigger kb_search_partitions_set_updated_at
before update on public.kb_search_partitions
for each row execute function public.kb_set_updated_at();

insert into public.kb_search_partitions (
  key,
  name,
  status,
  opensearch_read_alias,
  opensearch_write_alias,
  opensearch_concrete_index,
  pinecone_index_name,
  pinecone_namespace,
  index_schema_version,
  embedding_model
)
values
  (
    'general',
    'General Knowledge Base',
    'active',
    'kb_general_read',
    'kb_general_write',
    'kb_general_v1',
    'tiangong-kb-general',
    'kb_general_v1',
    'v1',
    'text-embedding-3-small'
  ),
  (
    'course',
    'Course Knowledge Base',
    'active',
    'kb_course_read',
    'kb_course_write',
    'kb_course_v1',
    'tiangong-kb-course',
    'kb_course_v1',
    'v1',
    'text-embedding-3-small'
  )
on conflict (key) do update
set name = excluded.name,
    status = excluded.status,
    opensearch_read_alias = excluded.opensearch_read_alias,
    opensearch_write_alias = excluded.opensearch_write_alias,
    opensearch_concrete_index = excluded.opensearch_concrete_index,
    pinecone_index_name = excluded.pinecone_index_name,
    pinecone_namespace = excluded.pinecone_namespace,
    index_schema_version = excluded.index_schema_version,
    embedding_model = excluded.embedding_model,
    updated_at = now();

alter table public.kb_collections
add column if not exists search_partition_id uuid
references public.kb_search_partitions(id) on delete restrict;

create or replace function public.kb_default_collection_search_partition()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_parent_partition_id uuid;
  v_default_partition_id uuid;
begin
  if new.search_partition_id is not null then
    return new;
  end if;

  if new.parent_id is not null then
    select search_partition_id
    into v_parent_partition_id
    from public.kb_collections
    where id = new.parent_id;

    if v_parent_partition_id is not null then
      new.search_partition_id = v_parent_partition_id;
      return new;
    end if;
  end if;

  if lower(trim(both '/' from new.path)) = 'course'
     or lower(trim(both '/' from new.path)) like 'course/%'
     or lower(coalesce(new.content_type, '')) in ('course', 'courses') then
    select id into v_default_partition_id
    from public.kb_search_partitions
    where key = 'course';
  else
    select id into v_default_partition_id
    from public.kb_search_partitions
    where key = 'general';
  end if;

  new.search_partition_id = v_default_partition_id;
  return new;
end;
$$;

drop trigger if exists kb_collections_default_search_partition on public.kb_collections;
create trigger kb_collections_default_search_partition
before insert or update of parent_id, path, content_type, search_partition_id
on public.kb_collections
for each row execute function public.kb_default_collection_search_partition();

alter table public.kb_index_records
add column if not exists search_partition_id uuid
references public.kb_search_partitions(id) on delete restrict;

alter table public.kb_index_records
add column if not exists chunk_index integer
check (chunk_index is null or chunk_index >= 0);

create index if not exists kb_collections_search_partition_idx
on public.kb_collections (search_partition_id);

create index if not exists kb_index_records_search_partition_idx
on public.kb_index_records (search_partition_id, deleted_at);

create index if not exists kb_index_records_target_idx
on public.kb_index_records (
  opensearch_index_name,
  pinecone_index_name,
  pinecone_namespace,
  deleted_at
);

with recursive partition_ids as (
  select
    (select id from public.kb_search_partitions where key = 'course') as course_id,
    (select id from public.kb_search_partitions where key = 'general') as general_id
),
seeded as (
  update public.kb_collections c
  set search_partition_id = case
    when lower(trim(both '/' from c.path)) = 'course'
      or lower(trim(both '/' from c.path)) like 'course/%'
      or lower(coalesce(c.content_type, '')) in ('course', 'courses')
      then partition_ids.course_id
    else partition_ids.general_id
  end
  from partition_ids
  where c.search_partition_id is null
    and c.parent_id is null
  returning c.id
),
recursive_tree as (
  select id, parent_id, search_partition_id as inherited_partition_id
  from public.kb_collections
  where parent_id is null

  union all

  select
    child.id,
    child.parent_id,
    coalesce(child.search_partition_id, parent.inherited_partition_id) as inherited_partition_id
  from public.kb_collections child
  join recursive_tree parent on parent.id = child.parent_id
)
update public.kb_collections c
set search_partition_id = recursive_tree.inherited_partition_id
from recursive_tree
where c.id = recursive_tree.id
  and c.search_partition_id is null
  and recursive_tree.inherited_partition_id is not null;

update public.kb_index_records r
set search_partition_id = c.search_partition_id,
    chunk_index = coalesce(
      r.chunk_index,
      nullif(regexp_replace(r.record_id, '^.*_([0-9]+)$', '\1'), r.record_id)::integer
    )
from public.kb_documents d
join public.kb_collections c on c.id = d.primary_collection_id
where r.document_id = d.id
  and (r.search_partition_id is null or r.chunk_index is null)
  and c.search_partition_id is not null;

create or replace function public.resolve_document_search_partition(
  p_document_id uuid
)
returns table (
  search_partition_id uuid,
  key text,
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
  with recursive collection_chain as (
    select
      c.id,
      c.parent_id,
      c.search_partition_id,
      0 as depth
    from public.kb_documents d
    join public.kb_collections c on c.id = d.primary_collection_id
    where d.id = p_document_id

    union all

    select
      parent.id,
      parent.parent_id,
      parent.search_partition_id,
      child.depth + 1
    from public.kb_collections parent
    join collection_chain child on child.parent_id = parent.id
  )
  select
    p.id,
    p.key,
    p.opensearch_read_alias,
    p.opensearch_write_alias,
    p.opensearch_concrete_index,
    p.pinecone_index_name,
    p.pinecone_namespace,
    p.index_schema_version,
    p.embedding_model
  from collection_chain c
  join public.kb_search_partitions p on p.id = c.search_partition_id
  where p.status = 'active'
  order by c.depth
  limit 1;
$$;
