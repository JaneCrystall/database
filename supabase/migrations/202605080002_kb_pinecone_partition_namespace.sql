update public.kb_search_partitions
set pinecone_index_name = 'tiangong',
    updated_at = now()
where key in ('course', 'general')
  and pinecone_index_name <> 'tiangong';
