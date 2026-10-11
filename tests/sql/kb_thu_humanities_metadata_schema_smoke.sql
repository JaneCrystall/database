do $$
declare
  v_schema jsonb;
  v_fields jsonb;
  v_partition_key text;
begin
  select
    c.metadata_schema_json,
    c.metadata_schema_json -> 'fields',
    p.key
  into v_schema, v_fields, v_partition_key
  from public.kb_collections c
  join public.kb_search_partitions p on p.id = c.search_partition_id
  where c.path = '/course/thu_humanities';

  if v_schema is null then
    raise exception '/course/thu_humanities collection is not seeded';
  end if;

  if v_partition_key <> 'course' then
    raise exception '/course/thu_humanities should use course search partition, got %', v_partition_key;
  end if;

  if jsonb_path_query_array(v_fields, '$[*].key') <> '[
    "raw_relative_path",
    "tags"
  ]'::jsonb then
    raise exception '/course/thu_humanities metadata fields are not in contract order';
  end if;

  if jsonb_path_exists(v_fields, '$[*] ? (@.key == "course_name")') then
    raise exception 'metadata_schema_json must not include course_name';
  end if;

  if jsonb_path_exists(
    v_fields,
    '$[*] ? (@.key == "document_id" || @.key == "collection_path" || @.key == "source_uri" || @.key == "processed_manifest_s3_key")'
  ) then
    raise exception 'metadata_schema_json must not include system index fields';
  end if;

  if v_fields -> 0 ->> 'type' <> 'string' then
    raise exception 'raw_relative_path should be a string';
  end if;

  if v_fields -> 0 -> 'index_targets' <> '["opensearch", "pinecone"]'::jsonb then
    raise exception 'raw_relative_path should target OpenSearch and Pinecone';
  end if;

  if v_fields -> 1 ->> 'type' <> 'string' then
    raise exception 'tags should be a string';
  end if;

  if v_fields -> 1 -> 'index_targets' <> '["opensearch", "pinecone"]'::jsonb then
    raise exception 'tags should target OpenSearch and Pinecone';
  end if;

  if v_fields -> 1 ->> 'facet' <> 'true' then
    raise exception 'tags should be faceted';
  end if;
end $$;
