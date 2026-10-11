create table if not exists public.kb_api_keys (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  client_id text not null,
  actor_user_id uuid,
  token_prefix text not null,
  token_hash text not null unique,
  scopes text[] not null,
  collection_scope text[] not null default '{}'::text[],
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text,
  rotated_from_key_id uuid references public.kb_api_keys(id) on delete set null,
  last_used_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (name <> ''),
  check (client_id <> ''),
  check (token_prefix <> ''),
  check (token_hash ~ '^[0-9a-f]{64}$'),
  check (cardinality(scopes) > 0),
  check (array_position(scopes, null::text) is null),
  check (
    scopes <@ array[
      'kb:read',
      'kb:upload',
      'kb:delete',
      'kb:reindex',
      'kb:admin'
    ]::text[]
  ),
  check (array_position(collection_scope, null::text) is null),
  check (cardinality(collection_scope) <= 100)
);

create index if not exists kb_api_keys_prefix_hash_idx
on public.kb_api_keys (token_prefix, token_hash);

create index if not exists kb_api_keys_client_idx
on public.kb_api_keys (client_id, created_at desc);

create index if not exists kb_api_keys_active_idx
on public.kb_api_keys (expires_at)
where revoked_at is null;

drop trigger if exists kb_api_keys_set_updated_at on public.kb_api_keys;
create trigger kb_api_keys_set_updated_at
before update on public.kb_api_keys
for each row execute function public.kb_set_updated_at();

alter table public.kb_api_keys enable row level security;
