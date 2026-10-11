alter table public.kb_index_records enable row level security;

revoke all on table public.kb_index_records from anon;
revoke all on table public.kb_index_records from authenticated;
