do $$
declare
  missing_tables text[];
begin
  select coalesce(array_agg(c.relname order by c.relname), '{}'::text[])
  into missing_tables
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and c.relname in (
      'kb_schema_migrations',
      'kb_collections',
      'kb_documents',
      'kb_jobs',
      'kb_grants',
      'kb_groups',
      'kb_group_members',
      'kb_audit_events',
      'kb_query_logs',
      'kb_index_records'
    )
    and not c.relrowsecurity;

  if array_length(missing_tables, 1) is not null then
    raise exception 'KB tables without RLS enabled: %', missing_tables;
  end if;
end $$;
