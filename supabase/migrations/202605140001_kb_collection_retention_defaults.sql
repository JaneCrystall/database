alter table public.kb_collections
  alter column raw_retention_policy set default 'delete_immediately',
  alter column processed_retention_policy set default 'delete_immediately';

update public.kb_collections
set raw_retention_policy = 'delete_immediately',
    processed_retention_policy = 'delete_immediately',
    updated_at = now()
where raw_retention_policy = 'archive_only'
  and processed_retention_policy = 'archive_only'
  and raw_retention_days = 0
  and processed_retention_days = 0;
