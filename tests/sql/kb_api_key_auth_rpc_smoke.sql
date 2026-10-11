begin;

do $$
declare
  admin_actor_id uuid := gen_random_uuid();
  actor_id uuid := gen_random_uuid();
  collection_id uuid;
  other_collection_id uuid;
  token_id uuid;
  limited_token_id uuid;
  revoked_token_id uuid;
  expired_token_id uuid;
  missing_actor_token_id uuid;
  auth_row record;
begin
  insert into public.kb_collections (name, path, content_type)
  values ('Auth RPC Smoke', '/smoke/auth-rpc', 'smoke')
  returning id into collection_id;

  insert into public.kb_collections (name, path, content_type)
  values ('Auth RPC Other', '/smoke/auth-rpc-other', 'smoke')
  returning id into other_collection_id;

  perform public.create_kb_grant(
    admin_actor_id,
    'collection',
    collection_id,
    'user',
    actor_id,
    array['read'::public.kb_grant_action, 'upload'::public.kb_grant_action],
    null,
    'auth-rpc-grant'
  );

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    collection_scope,
    created_by
  )
  values (
    'Auth RPC key',
    'auth-rpc-client',
    actor_id,
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:read', 'kb:upload']::text[],
    array['/smoke/auth-rpc']::text[],
    admin_actor_id
  )
  returning id into token_id;

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    collection_scope,
    created_by
  )
  values (
    'Limited key',
    'auth-rpc-client',
    actor_id,
    'tgkb_live_auth002',
    repeat('2', 64),
    array['kb:read']::text[],
    array[]::text[],
    admin_actor_id
  )
  returning id into limited_token_id;

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    revoked_at,
    created_by
  )
  values (
    'Revoked key',
    'auth-rpc-client',
    actor_id,
    'tgkb_live_auth003',
    repeat('3', 64),
    array['kb:read']::text[],
    now(),
    admin_actor_id
  )
  returning id into revoked_token_id;

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    expires_at,
    created_by
  )
  values (
    'Expired key',
    'auth-rpc-client',
    actor_id,
    'tgkb_live_auth004',
    repeat('4', 64),
    array['kb:read']::text[],
    now() - interval '1 day',
    admin_actor_id
  )
  returning id into expired_token_id;

  insert into public.kb_api_keys (
    name,
    client_id,
    actor_user_id,
    token_prefix,
    token_hash,
    scopes,
    created_by
  )
  values (
    'Missing actor key',
    'auth-rpc-client',
    null,
    'tgkb_live_auth005',
    repeat('5', 64),
    array['kb:read']::text[],
    admin_actor_id
  )
  returning id into missing_actor_token_id;

  select *
  into auth_row
  from public.verify_kb_api_key(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:upload']::text[],
    jsonb_build_object('request_id', 'verify-ok')
  );

  if auth_row.ok is distinct from true
     or auth_row.token_id <> token_id
     or auth_row.actor_user_id <> actor_id
     or auth_row.status <> 200
  then
    raise exception 'verify_kb_api_key should accept active token';
  end if;

  if not exists (
    select 1
    from public.kb_api_keys
    where id = token_id
      and last_used_at is not null
  ) then
    raise exception 'verify_kb_api_key should update last_used_at';
  end if;

  select *
  into auth_row
  from public.verify_kb_api_key(
    'tgkb_live_auth002',
    repeat('2', 64),
    array['kb:upload']::text[],
    '{}'::jsonb
  );

  if auth_row.ok is distinct from false
     or auth_row.status <> 403
     or auth_row.code <> 'missing_scope'
     or auth_row.token_id <> limited_token_id
  then
    raise exception 'verify_kb_api_key should reject missing scope';
  end if;

  select *
  into auth_row
  from public.verify_kb_api_key('missing', repeat('9', 64), array['kb:read']::text[]);

  if auth_row.ok is distinct from false
     or auth_row.status <> 401
     or auth_row.code <> 'invalid_token'
  then
    raise exception 'verify_kb_api_key should reject invalid token';
  end if;

  select *
  into auth_row
  from public.verify_kb_api_key('tgkb_live_auth003', repeat('3', 64), array['kb:read']::text[]);

  if auth_row.ok is distinct from false
     or auth_row.status <> 401
     or auth_row.code <> 'revoked_token'
     or auth_row.token_id <> revoked_token_id
  then
    raise exception 'verify_kb_api_key should reject revoked token';
  end if;

  select *
  into auth_row
  from public.verify_kb_api_key('tgkb_live_auth004', repeat('4', 64), array['kb:read']::text[]);

  if auth_row.ok is distinct from false
     or auth_row.status <> 401
     or auth_row.code <> 'expired_token'
     or auth_row.token_id <> expired_token_id
  then
    raise exception 'verify_kb_api_key should reject expired token';
  end if;

  select *
  into auth_row
  from public.verify_kb_api_key('tgkb_live_auth005', repeat('5', 64), array['kb:read']::text[]);

  if auth_row.ok is distinct from false
     or auth_row.status <> 403
     or auth_row.code <> 'missing_actor'
     or auth_row.token_id <> missing_actor_token_id
  then
    raise exception 'verify_kb_api_key should reject missing actor token';
  end if;

  select *
  into auth_row
  from public.authorize_kb_api_key_collection_action(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:upload']::text[],
    jsonb_build_object('collection_path', '/smoke/auth-rpc'),
    'upload',
    jsonb_build_object('request_id', 'authorize-ok')
  );

  if auth_row.ok is distinct from true
     or auth_row.collection_id <> collection_id
     or auth_row.collection_path <> '/smoke/auth-rpc'
     or auth_row.action <> 'upload'
  then
    raise exception 'authorize_kb_api_key_collection_action should allow scoped upload';
  end if;

  select *
  into auth_row
  from public.authorize_kb_api_key_collection_action(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:upload']::text[],
    jsonb_build_object('collection_id', other_collection_id),
    'upload',
    jsonb_build_object('request_id', 'scope-denied')
  );

  if auth_row.ok is distinct from false
     or auth_row.status <> 403
     or auth_row.code <> 'collection_scope_denied'
     or auth_row.collection_id <> other_collection_id
  then
    raise exception 'authorize_kb_api_key_collection_action should enforce collection_scope';
  end if;

  if not exists (
    select 1
    from public.kb_audit_events
    where public.kb_audit_events.actor_id = auth_row.actor_user_id
      and public.kb_audit_events.collection_id = other_collection_id
      and public.kb_audit_events.action = 'kb.auth_denied'
      and public.kb_audit_events.request_id = 'scope-denied'
  ) then
    raise exception 'collection_scope denial should write audit';
  end if;

  update public.kb_api_keys
  set collection_scope = array[]::text[]
  where id = token_id;

  select *
  into auth_row
  from public.authorize_kb_api_key_collection_action(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:upload']::text[],
    jsonb_build_object('collection_path', '/smoke/auth-rpc-other'),
    'upload',
    jsonb_build_object('request_id', 'grant-denied')
  );

  if auth_row.ok is distinct from false
     or auth_row.status <> 403
     or auth_row.code <> 'collection_action_denied'
     or auth_row.message <> 'Upload permission denied.'
  then
    raise exception 'authorize_kb_api_key_collection_action should enforce F01 grant';
  end if;

  select *
  into auth_row
  from public.authorize_kb_api_key_collection_action(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:read']::text[],
    jsonb_build_object('collection_key', 'smoke/auth-rpc'),
    'search',
    '{}'::jsonb
  );

  if auth_row.ok is distinct from true
     or auth_row.collection_id <> collection_id
     or auth_row.action <> 'search'
  then
    raise exception 'search action should map to read grant';
  end if;

  select *
  into auth_row
  from public.authorize_kb_api_key_collection_action(
    'tgkb_live_auth001',
    repeat('1', 64),
    array['kb:read']::text[],
    jsonb_build_object('collection_path', '/missing'),
    'read',
    '{}'::jsonb
  );

  if auth_row.ok is distinct from false
     or auth_row.status <> 404
     or auth_row.code <> 'collection_not_found'
  then
    raise exception 'authorize_kb_api_key_collection_action should reject missing collection';
  end if;

end;
$$;

rollback;
