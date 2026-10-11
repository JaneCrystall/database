with course_partition as (
  select id
  from public.kb_search_partitions
  where key = 'course'
),
course_parent as (
  insert into public.kb_collections (
    name,
    path,
    content_type,
    raw_retention_policy,
    processed_retention_policy,
    search_partition_id,
    metadata_schema_json
  )
  select
    'Course Materials',
    '/course',
    'collection',
    'delete_immediately',
    'delete_immediately',
    course_partition.id,
    '{}'::jsonb
  from course_partition
  on conflict (path) do update
  set search_partition_id = coalesce(
        public.kb_collections.search_partition_id,
        excluded.search_partition_id
      ),
      raw_retention_policy = excluded.raw_retention_policy,
      processed_retention_policy = excluded.processed_retention_policy,
      updated_at = now()
  returning id
),
target_parent as (
  select id from course_parent
  union all
  select id from public.kb_collections where path = '/course'
  limit 1
)
insert into public.kb_collections (
  name,
  parent_id,
  path,
  content_type,
  raw_retention_policy,
  processed_retention_policy,
  search_partition_id,
  metadata_schema_json
)
select
  '清华人文资料集合',
  target_parent.id,
  '/course/thu_humanities',
  'collection',
  'delete_immediately',
  'delete_immediately',
  course_partition.id,
  '{
    "version": 1,
    "fields": [
      {
        "key": "raw_relative_path",
        "type": "string",
        "description": "用户上传时的原始业务相对路径，用于引用展示、排障回溯和目录级过滤。",
        "filterable": true,
        "searchable": true,
        "index_targets": ["opensearch", "pinecone"]
      },
      {
        "key": "tags",
        "type": "string",
        "description": "从 collection path 派生的稳定标签，例如 course/thu_humanities 对应 thu_humanities。",
        "filterable": true,
        "facet": true,
        "index_targets": ["opensearch", "pinecone"]
      }
    ]
  }'::jsonb
from target_parent, course_partition
on conflict (path) do update
set name = excluded.name,
    parent_id = coalesce(public.kb_collections.parent_id, excluded.parent_id),
    content_type = excluded.content_type,
    raw_retention_policy = excluded.raw_retention_policy,
    processed_retention_policy = excluded.processed_retention_policy,
    search_partition_id = excluded.search_partition_id,
    metadata_schema_json = excluded.metadata_schema_json,
    updated_at = now();
