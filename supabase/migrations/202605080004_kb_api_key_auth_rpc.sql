create or replace function public.kb_normalize_collection_path(p_path text)
returns text
language plpgsql
immutable
as $$
declare
  v_key text;
begin
  v_key := trim(both '/' from btrim(coalesce(p_path, '')));

  if v_key = ''
     or v_key like '%//%'
     or exists (
       select 1
       from regexp_split_to_table(v_key, '/') as segment
       where segment in ('', '.', '..')
     )
  then
    return null;
  end if;

  return '/' || v_key;
end;
$$;

create or replace function public.verify_kb_api_key(
  p_token_prefix text,
  p_token_hash text,
  p_required_scopes text[] default '{}'::text[],
  p_request_context jsonb default '{}'::jsonb
)
returns table (
  ok boolean,
  status integer,
  code text,
  message text,
  token_id uuid,
  client_id text,
  actor_user_id uuid,
  scopes text[],
  collection_scope text[],
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key public.kb_api_keys%rowtype;
  v_missing_scope text;
begin
  if p_request_context is null or jsonb_typeof(p_request_context) <> 'object' then
    p_request_context := '{}'::jsonb;
  end if;

  if coalesce(btrim(p_token_prefix), '') = ''
     or coalesce(btrim(p_token_hash), '') !~ '^[0-9a-f]{64}$'
  then
    return query
      select
        false,
        401,
        'invalid_token',
        'Invalid bearer token.',
        null::uuid,
        null::text,
        null::uuid,
        '{}'::text[],
        '{}'::text[],
        null::timestamptz;
    return;
  end if;

  select *
  into v_key
  from public.kb_api_keys
  where token_prefix = p_token_prefix
    and token_hash = p_token_hash
  limit 1;

  if not found then
    return query
      select
        false,
        401,
        'invalid_token',
        'Invalid bearer token.',
        null::uuid,
        null::text,
        null::uuid,
        '{}'::text[],
        '{}'::text[],
        null::timestamptz;
    return;
  end if;

  if v_key.revoked_at is not null then
    return query
      select
        false,
        401,
        'revoked_token',
        'Bearer token has been revoked.',
        v_key.id,
        v_key.client_id,
        v_key.actor_user_id,
        v_key.scopes,
        coalesce(v_key.collection_scope, '{}'::text[]),
        v_key.expires_at;
    return;
  end if;

  if v_key.expires_at is not null and v_key.expires_at <= now() then
    return query
      select
        false,
        401,
        'expired_token',
        'Bearer token has expired.',
        v_key.id,
        v_key.client_id,
        v_key.actor_user_id,
        v_key.scopes,
        coalesce(v_key.collection_scope, '{}'::text[]),
        v_key.expires_at;
    return;
  end if;

  select required_scope
  into v_missing_scope
  from unnest(coalesce(p_required_scopes, '{}'::text[])) as required_scope
  where not required_scope = any(v_key.scopes)
  limit 1;

  if v_missing_scope is not null then
    return query
      select
        false,
        403,
        'missing_scope',
        format('Bearer token is missing %s scope.', v_missing_scope),
        v_key.id,
        v_key.client_id,
        v_key.actor_user_id,
        v_key.scopes,
        coalesce(v_key.collection_scope, '{}'::text[]),
        v_key.expires_at;
    return;
  end if;

  if v_key.actor_user_id is null then
    return query
      select
        false,
        403,
        'missing_actor',
        'Bearer token is not mapped to an actor.',
        v_key.id,
        v_key.client_id,
        null::uuid,
        v_key.scopes,
        coalesce(v_key.collection_scope, '{}'::text[]),
        v_key.expires_at;
    return;
  end if;

  update public.kb_api_keys
  set last_used_at = now()
  where id = v_key.id;

  return query
    select
      true,
      200,
      'ok',
      'OK',
      v_key.id,
      v_key.client_id,
      v_key.actor_user_id,
      v_key.scopes,
      coalesce(v_key.collection_scope, '{}'::text[]),
      v_key.expires_at;
end;
$$;

create or replace function public.authorize_kb_api_key_collection_action(
  p_token_prefix text,
  p_token_hash text,
  p_required_scopes text[] default '{}'::text[],
  p_collection_selector jsonb default '{}'::jsonb,
  p_action text default 'read',
  p_request_context jsonb default '{}'::jsonb
)
returns table (
  ok boolean,
  status integer,
  code text,
  message text,
  token_id uuid,
  client_id text,
  actor_user_id uuid,
  scopes text[],
  collection_scope text[],
  expires_at timestamptz,
  collection_id uuid,
  collection_path text,
  collection_key text,
  action text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth record;
  v_collection_id_text text;
  v_collection_path_text text;
  v_collection_key_text text;
  v_selector_count integer;
  v_collection public.kb_collections%rowtype;
  v_normalized_path text;
  v_grant_action public.kb_grant_action;
  v_request_id text;
  v_allowed boolean;
begin
  if p_collection_selector is null or jsonb_typeof(p_collection_selector) <> 'object' then
    p_collection_selector := '{}'::jsonb;
  end if;

  if p_request_context is null or jsonb_typeof(p_request_context) <> 'object' then
    p_request_context := '{}'::jsonb;
  end if;

  select *
  into v_auth
  from public.verify_kb_api_key(
    p_token_prefix,
    p_token_hash,
    p_required_scopes,
    p_request_context
  )
  limit 1;

  if v_auth.ok is distinct from true then
    return query
      select
        v_auth.ok,
        v_auth.status,
        v_auth.code,
        v_auth.message,
        v_auth.token_id,
        v_auth.client_id,
        v_auth.actor_user_id,
        v_auth.scopes,
        v_auth.collection_scope,
        v_auth.expires_at,
        null::uuid,
        null::text,
        null::text,
        p_action;
    return;
  end if;

  v_collection_id_text := nullif(btrim(p_collection_selector ->> 'collection_id'), '');
  v_collection_path_text := nullif(btrim(p_collection_selector ->> 'collection_path'), '');
  v_collection_key_text := nullif(btrim(p_collection_selector ->> 'collection_key'), '');
  v_selector_count :=
    case when v_collection_id_text is null then 0 else 1 end
    + case when v_collection_path_text is null then 0 else 1 end
    + case when v_collection_key_text is null then 0 else 1 end;

  if v_selector_count <> 1 then
    return query
      select
        false,
        400,
        'invalid_collection_selector',
        'Provide exactly one collection selector: collection_id, collection_path, or collection_key.',
        v_auth.token_id,
        v_auth.client_id,
        v_auth.actor_user_id,
        v_auth.scopes,
        v_auth.collection_scope,
        v_auth.expires_at,
        null::uuid,
        null::text,
        null::text,
        p_action;
    return;
  end if;

  if v_collection_id_text is not null then
    if v_collection_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      return query
        select
          false,
          400,
          'invalid_collection_selector',
          'Collection selector id is invalid.',
          v_auth.token_id,
          v_auth.client_id,
          v_auth.actor_user_id,
          v_auth.scopes,
          v_auth.collection_scope,
          v_auth.expires_at,
          null::uuid,
          null::text,
          null::text,
          p_action;
      return;
    end if;

    select *
    into v_collection
    from public.kb_collections
    where id = v_collection_id_text::uuid;
  else
    v_normalized_path := public.kb_normalize_collection_path(
      coalesce(v_collection_path_text, v_collection_key_text)
    );

    if v_normalized_path is null then
      return query
        select
          false,
          400,
          'invalid_collection_selector',
          'Collection selector path is invalid.',
          v_auth.token_id,
          v_auth.client_id,
          v_auth.actor_user_id,
          v_auth.scopes,
          v_auth.collection_scope,
          v_auth.expires_at,
          null::uuid,
          null::text,
          null::text,
          p_action;
      return;
    end if;

    select *
    into v_collection
    from public.kb_collections
    where path = v_normalized_path;
  end if;

  if not found then
    return query
      select
        false,
        404,
        'collection_not_found',
        'Collection selector did not match a collection.',
        v_auth.token_id,
        v_auth.client_id,
        v_auth.actor_user_id,
        v_auth.scopes,
        v_auth.collection_scope,
        v_auth.expires_at,
        null::uuid,
        null::text,
        null::text,
        p_action;
    return;
  end if;

  if cardinality(v_auth.collection_scope) > 0
     and not exists (
       select 1
       from unnest(v_auth.collection_scope) as scoped_path
       where public.kb_normalize_collection_path(scoped_path) = v_collection.path
     )
  then
    v_request_id := nullif(p_request_context ->> 'request_id', '');

    perform public.write_kb_audit_event(
      v_auth.actor_user_id,
      'kb.auth_denied',
      null,
      v_collection.id,
      '{}'::jsonb,
      v_request_id,
      jsonb_build_object(
        'reason', 'api_key_collection_scope_denied',
        'token_id', v_auth.token_id,
        'client_id', v_auth.client_id,
        'action', p_action,
        'resource_type', 'collection',
        'resource_id', v_collection.id
      )
    );

    return query
      select
        false,
        403,
        'collection_scope_denied',
        'Bearer token is not allowed for this collection.',
        v_auth.token_id,
        v_auth.client_id,
        v_auth.actor_user_id,
        v_auth.scopes,
        v_auth.collection_scope,
        v_auth.expires_at,
        v_collection.id,
        v_collection.path,
        trim(both '/' from v_collection.path),
        p_action;
    return;
  end if;

  v_grant_action := case p_action
    when 'search' then 'read'::public.kb_grant_action
    else p_action::public.kb_grant_action
  end;

  v_allowed := public.can_collection_action(
    v_auth.actor_user_id,
    v_collection.id,
    v_grant_action
  );

  if not v_allowed then
    v_request_id := nullif(p_request_context ->> 'request_id', '');

    perform public.write_kb_audit_event(
      v_auth.actor_user_id,
      'kb.auth_denied',
      null,
      v_collection.id,
      '{}'::jsonb,
      v_request_id,
      jsonb_build_object(
        'reason', 'missing collection grant',
        'token_id', v_auth.token_id,
        'client_id', v_auth.client_id,
        'action', p_action,
        'resource_type', 'collection',
        'resource_id', v_collection.id
      )
    );

    return query
      select
        false,
        403,
        'collection_action_denied',
        case
          when p_action = 'upload' then 'Upload permission denied.'
          else 'Collection action permission denied.'
        end,
        v_auth.token_id,
        v_auth.client_id,
        v_auth.actor_user_id,
        v_auth.scopes,
        v_auth.collection_scope,
        v_auth.expires_at,
        v_collection.id,
        v_collection.path,
        trim(both '/' from v_collection.path),
        p_action;
    return;
  end if;

  return query
    select
      true,
      200,
      'ok',
      'OK',
      v_auth.token_id,
      v_auth.client_id,
      v_auth.actor_user_id,
      v_auth.scopes,
      v_auth.collection_scope,
      v_auth.expires_at,
      v_collection.id,
      v_collection.path,
      trim(both '/' from v_collection.path),
      p_action;
exception
  when invalid_text_representation then
    return query
      select
        false,
        400,
        'invalid_action',
        'Collection action is invalid.',
        null::uuid,
        null::text,
        null::uuid,
        '{}'::text[],
        '{}'::text[],
        null::timestamptz,
        null::uuid,
        null::text,
        null::text,
        p_action;
end;
$$;

grant execute on function public.kb_normalize_collection_path(text) to service_role;
grant execute on function public.verify_kb_api_key(text, text, text[], jsonb) to service_role;
grant execute on function public.authorize_kb_api_key_collection_action(text, text, text[], jsonb, text, jsonb) to service_role;
