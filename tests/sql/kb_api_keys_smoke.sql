begin;

do $$
declare
  admin_actor_id uuid := gen_random_uuid();
  external_actor_id uuid := gen_random_uuid();
  first_key_id uuid;
  rotated_key_id uuid;
  rls_enabled boolean;
begin
  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    collection_scope,
    expires_at,
    created_by
  )
  values (
    'F08 Smoke Key',
    'f08-smoke-client',
    external_actor_id,
    'tgkb_live_smoke001',
    repeat('a', 64),
    array['kb:read', 'kb:upload']::text[],
    array['/course/thu_humanities']::text[],
    now() + interval '30 days',
    admin_actor_id
  )
  returning id into first_key_id;

  if first_key_id is null then
    raise exception 'kb_api_keys insert did not return an id';
  end if;

  perform 1
  from public.kb_api_keys
  where token_prefix = 'tgkb_live_smoke001'
    and token_hash = repeat('a', 64)
    and revoked_at is null
    and (expires_at is null or expires_at > now());

  if not found then
    raise exception 'active API key lookup by prefix and hash failed';
  end if;

  begin
    insert into public.kb_api_keys (
      name,
      client_id,
      token_prefix,
      token_hash,
      scopes,
      created_by
    )
    values (
      'Invalid Scope',
      'f08-smoke-client',
      'tgkb_live_invalid',
      repeat('b', 64),
      array['kb:read', 'kb:unknown']::text[],
      admin_actor_id
    );

    raise exception 'invalid scope insert unexpectedly succeeded';
  exception
    when check_violation then
      null;
  end;

  begin
    insert into public.kb_api_keys (
      name,
      client_id,
      token_prefix,
      token_hash,
      scopes,
      created_by
    )
    values (
      'Duplicate Hash',
      'f08-smoke-client',
      'tgkb_live_dup',
      repeat('a', 64),
      array['kb:read']::text[],
      admin_actor_id
    );

    raise exception 'duplicate token_hash insert unexpectedly succeeded';
  exception
    when unique_violation then
      null;
  end;

  update public.kb_api_keys
  set revoked_at = now(),
      revoked_by = admin_actor_id,
      revoke_reason = 'smoke revoke'
  where id = first_key_id;

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    collection_scope,
    rotated_from_key_id,
    created_by
  )
  select
    name,
    client_id,
    actor_user_id,
    'tgkb_live_smoke002',
    repeat('c', 64),
    scopes,
    collection_scope,
    id,
    admin_actor_id
  from public.kb_api_keys
  where id = first_key_id
  returning id into rotated_key_id;

  if not exists (
    select 1
    from public.kb_api_keys
    where id = rotated_key_id
      and rotated_from_key_id = first_key_id
      and token_hash = repeat('c', 64)
      and revoked_at is null
  ) then
    raise exception 'rotated API key lineage was not persisted';
  end if;

  select c.relrowsecurity into rls_enabled
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'kb_api_keys';

  if rls_enabled is distinct from true then
    raise exception 'kb_api_keys RLS is not enabled';
  end if;
end;
$$;

rollback;
