alter table public.kb_grants
  add column if not exists revoked_at timestamptz,
  add column if not exists revoked_by uuid,
  add column if not exists revocation_reason text;

create index if not exists kb_grants_active_resource_idx
on public.kb_grants (resource_type, resource_id, effect, expires_at)
where revoked_at is null;

create index if not exists kb_grants_active_principal_idx
on public.kb_grants (principal_type, principal_id, effect, expires_at)
where revoked_at is null;

create index if not exists kb_group_members_group_idx
on public.kb_group_members (group_id);

create or replace function public.write_kb_audit_event(
  p_actor_id uuid,
  p_action text,
  p_document_id uuid default null,
  p_collection_id uuid default null,
  p_scope_json jsonb default '{}'::jsonb,
  p_request_id text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_audit_id uuid;
begin
  if p_action is null or p_action = '' then
    raise exception 'audit action is required';
  end if;

  if p_scope_json is null or jsonb_typeof(p_scope_json) <> 'object' then
    raise exception 'scope_json must be a JSON object';
  end if;

  if p_payload_json is null or jsonb_typeof(p_payload_json) <> 'object' then
    raise exception 'payload_json must be a JSON object';
  end if;

  insert into public.kb_audit_events (
    actor_id,
    action,
    document_id,
    collection_id,
    scope_json,
    request_id,
    payload_json
  )
  values (
    p_actor_id,
    p_action,
    p_document_id,
    p_collection_id,
    p_scope_json,
    p_request_id,
    p_payload_json
  )
  returning id
  into v_audit_id;

  return v_audit_id;
end;
$$;

create or replace function public.kb_actor_principals(p_actor_id uuid)
returns table (principal_type public.kb_principal_type, principal_id uuid)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select 'user'::public.kb_principal_type, p_actor_id
  where p_actor_id is not null
  union
  select 'group'::public.kb_principal_type, gm.group_id
  from public.kb_group_members gm
  where gm.user_id = p_actor_id
$$;

create or replace function public.can_collection_action(
  p_actor_id uuid,
  p_collection_id uuid,
  p_action public.kb_grant_action
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with target_collection as (
    select id, path
    from public.kb_collections
    where id = p_collection_id
  ),
  principals as (
    select *
    from public.kb_actor_principals(p_actor_id)
  )
  select coalesce(
    exists (
      select 1
      from public.kb_grants g
      join principals p
        on p.principal_type = g.principal_type
       and p.principal_id = g.principal_id
      cross join target_collection tc
      left join public.kb_collections grant_collection
        on grant_collection.id = g.resource_id
       and g.resource_type = 'subtree'
      where p_actor_id is not null
        and p_action is not null
        and g.effect = 'allow'
        and g.revoked_at is null
        and (g.expires_at is null or g.expires_at > now())
        and (
          p_action = any(g.actions)
          or 'manage'::public.kb_grant_action = any(g.actions)
        )
        and (
          (
            g.resource_type = 'collection'
            and g.resource_id = tc.id
          )
          or (
            g.resource_type = 'subtree'
            and grant_collection.id is not null
            and (
              tc.path = grant_collection.path
              or tc.path like grant_collection.path || '/%'
            )
          )
        )
    ),
    false
  )
$$;

create or replace function public.can_read_document(
  p_actor_id uuid,
  p_document_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with target_document as (
    select
      d.id,
      d.primary_collection_id,
      d.created_by,
      d.owner_user_id,
      d.visibility,
      d.deleted_at,
      c.path as collection_path
    from public.kb_documents d
    join public.kb_collections c on c.id = d.primary_collection_id
    where d.id = p_document_id
  ),
  principals as (
    select *
    from public.kb_actor_principals(p_actor_id)
  )
  select coalesce(
    exists (
      select 1
      from target_document td
      where p_actor_id is not null
        and td.deleted_at is null
        and (
          td.created_by = p_actor_id
          or td.owner_user_id = p_actor_id
          or td.visibility = 'public'
          or exists (
            select 1
            from public.kb_grants g
            join principals p
              on p.principal_type = g.principal_type
             and p.principal_id = g.principal_id
            left join public.kb_collections grant_collection
              on grant_collection.id = g.resource_id
             and g.resource_type = 'subtree'
            where g.effect = 'allow'
              and g.revoked_at is null
              and (g.expires_at is null or g.expires_at > now())
              and (
                'read'::public.kb_grant_action = any(g.actions)
                or 'manage'::public.kb_grant_action = any(g.actions)
              )
              and (
                (
                  g.resource_type = 'document'
                  and g.resource_id = td.id
                )
                or (
                  g.resource_type = 'collection'
                  and g.resource_id = td.primary_collection_id
                )
                or (
                  g.resource_type = 'subtree'
                  and grant_collection.id is not null
                  and (
                    td.collection_path = grant_collection.path
                    or td.collection_path like grant_collection.path || '/%'
                  )
                )
              )
          )
        )
    ),
    false
  )
$$;

create or replace function public.can_document_action(
  p_actor_id uuid,
  p_document_id uuid,
  p_action public.kb_grant_action
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with target_document as (
    select
      d.id,
      d.primary_collection_id,
      c.path as collection_path
    from public.kb_documents d
    join public.kb_collections c on c.id = d.primary_collection_id
    where d.id = p_document_id
  ),
  principals as (
    select *
    from public.kb_actor_principals(p_actor_id)
  )
  select case
    when p_action = 'read'::public.kb_grant_action then
      public.can_read_document(p_actor_id, p_document_id)
    else coalesce(
      exists (
        select 1
        from public.kb_grants g
        join principals p
          on p.principal_type = g.principal_type
         and p.principal_id = g.principal_id
        cross join target_document td
        left join public.kb_collections grant_collection
          on grant_collection.id = g.resource_id
         and g.resource_type = 'subtree'
        where p_actor_id is not null
          and p_action is not null
          and g.effect = 'allow'
          and g.revoked_at is null
          and (g.expires_at is null or g.expires_at > now())
          and (
            p_action = any(g.actions)
            or 'manage'::public.kb_grant_action = any(g.actions)
          )
          and (
            (
              g.resource_type = 'document'
              and g.resource_id = td.id
            )
            or (
              g.resource_type = 'collection'
              and g.resource_id = td.primary_collection_id
            )
            or (
              g.resource_type = 'subtree'
              and grant_collection.id is not null
              and (
                td.collection_path = grant_collection.path
                or td.collection_path like grant_collection.path || '/%'
              )
            )
          )
      ),
      false
    )
  end
$$;

create or replace function public.create_kb_group(
  p_actor_id uuid,
  p_name text,
  p_request_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group_id uuid;
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  if p_name is null or p_name = '' then
    raise exception 'group name is required';
  end if;

  insert into public.kb_groups (name, created_by)
  values (p_name, p_actor_id)
  returning id
  into v_group_id;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.group_created',
    null,
    null,
    jsonb_build_object('group_id', v_group_id),
    p_request_id,
    jsonb_build_object('name', p_name)
  );

  return v_group_id;
end;
$$;

create or replace function public.add_kb_group_member(
  p_actor_id uuid,
  p_group_id uuid,
  p_user_id uuid,
  p_role text default 'member',
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  if p_group_id is null or p_user_id is null then
    raise exception 'group_id and user_id are required';
  end if;

  insert into public.kb_group_members (group_id, user_id, role)
  values (p_group_id, p_user_id, coalesce(nullif(p_role, ''), 'member'))
  on conflict (group_id, user_id)
  do update
  set role = excluded.role;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.group_member_added',
    null,
    null,
    jsonb_build_object('group_id', p_group_id, 'user_id', p_user_id),
    p_request_id,
    jsonb_build_object('role', coalesce(nullif(p_role, ''), 'member'))
  );

  return true;
end;
$$;

create or replace function public.remove_kb_group_member(
  p_actor_id uuid,
  p_group_id uuid,
  p_user_id uuid,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_removed_count integer;
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  delete from public.kb_group_members
  where group_id = p_group_id
    and user_id = p_user_id;

  get diagnostics v_removed_count = row_count;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.group_member_removed',
    null,
    null,
    jsonb_build_object('group_id', p_group_id, 'user_id', p_user_id),
    p_request_id,
    jsonb_build_object('removed', v_removed_count > 0)
  );

  return v_removed_count > 0;
end;
$$;

create or replace function public.create_kb_grant(
  p_actor_id uuid,
  p_resource_type public.kb_resource_type,
  p_resource_id uuid,
  p_principal_type public.kb_principal_type,
  p_principal_id uuid,
  p_actions public.kb_grant_action[],
  p_expires_at timestamptz default null,
  p_request_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_grant_id uuid;
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  if p_resource_id is null or p_principal_id is null then
    raise exception 'resource_id and principal_id are required';
  end if;

  if p_actions is null or cardinality(p_actions) = 0 then
    raise exception 'actions are required';
  end if;

  if p_principal_type = 'org'::public.kb_principal_type then
    raise exception 'org principals are not supported in the first version';
  end if;

  if p_principal_type = 'group'::public.kb_principal_type
     and not exists (select 1 from public.kb_groups where id = p_principal_id) then
    raise exception 'group principal % does not exist', p_principal_id;
  end if;

  if p_resource_type = 'document'::public.kb_resource_type
     and not exists (select 1 from public.kb_documents where id = p_resource_id) then
    raise exception 'document resource % does not exist', p_resource_id;
  end if;

  if p_resource_type in ('collection'::public.kb_resource_type, 'subtree'::public.kb_resource_type)
     and not exists (select 1 from public.kb_collections where id = p_resource_id) then
    raise exception 'collection resource % does not exist', p_resource_id;
  end if;

  insert into public.kb_grants (
    resource_type,
    resource_id,
    principal_type,
    principal_id,
    actions,
    effect,
    expires_at,
    created_by
  )
  values (
    p_resource_type,
    p_resource_id,
    p_principal_type,
    p_principal_id,
    p_actions,
    'allow',
    p_expires_at,
    p_actor_id
  )
  returning id
  into v_grant_id;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.grant_created',
    null,
    case
      when p_resource_type in ('collection'::public.kb_resource_type, 'subtree'::public.kb_resource_type)
      then p_resource_id
      else null
    end,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'resource_type', p_resource_type,
      'resource_id', p_resource_id,
      'principal_type', p_principal_type,
      'principal_id', p_principal_id
    ),
    p_request_id,
    jsonb_build_object('actions', p_actions, 'expires_at', p_expires_at)
  );

  return v_grant_id;
end;
$$;

create or replace function public.revoke_kb_grant(
  p_actor_id uuid,
  p_grant_id uuid,
  p_reason text default null,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_grant record;
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  update public.kb_grants
  set revoked_at = now(),
      revoked_by = p_actor_id,
      revocation_reason = p_reason
  where id = p_grant_id
    and revoked_at is null
  returning *
  into v_grant;

  if not found then
    return false;
  end if;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.grant_revoked',
    null,
    case
      when v_grant.resource_type in ('collection'::public.kb_resource_type, 'subtree'::public.kb_resource_type)
      then v_grant.resource_id
      else null
    end,
    jsonb_build_object(
      'grant_id', v_grant.id,
      'resource_type', v_grant.resource_type,
      'resource_id', v_grant.resource_id,
      'principal_type', v_grant.principal_type,
      'principal_id', v_grant.principal_id
    ),
    p_request_id,
    jsonb_build_object('reason', p_reason)
  );

  return true;
end;
$$;

create or replace function public.list_kb_grants_for_resource(
  p_resource_type public.kb_resource_type,
  p_resource_id uuid
)
returns table (
  id uuid,
  resource_type public.kb_resource_type,
  resource_id uuid,
  principal_type public.kb_principal_type,
  principal_id uuid,
  actions public.kb_grant_action[],
  effect public.kb_grant_effect,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revocation_reason text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    g.id,
    g.resource_type,
    g.resource_id,
    g.principal_type,
    g.principal_id,
    g.actions,
    g.effect,
    g.expires_at,
    g.revoked_at,
    g.revoked_by,
    g.revocation_reason,
    g.created_by,
    g.created_at,
    g.updated_at
  from public.kb_grants g
  where g.resource_type = p_resource_type
    and g.resource_id = p_resource_id
  order by g.created_at desc
$$;

create or replace function public.list_kb_grants_for_principal(
  p_principal_type public.kb_principal_type,
  p_principal_id uuid
)
returns table (
  id uuid,
  resource_type public.kb_resource_type,
  resource_id uuid,
  principal_type public.kb_principal_type,
  principal_id uuid,
  actions public.kb_grant_action[],
  effect public.kb_grant_effect,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revocation_reason text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    g.id,
    g.resource_type,
    g.resource_id,
    g.principal_type,
    g.principal_id,
    g.actions,
    g.effect,
    g.expires_at,
    g.revoked_at,
    g.revoked_by,
    g.revocation_reason,
    g.created_by,
    g.created_at,
    g.updated_at
  from public.kb_grants g
  where g.principal_type = p_principal_type
    and g.principal_id = p_principal_id
  order by g.created_at desc
$$;

create or replace function public.request_delete(
  p_document_id uuid,
  p_actor_id uuid,
  p_reason text default null,
  p_request_id text default null
)
returns table (document_id uuid, job_id uuid, msg_id bigint, delete_generation integer)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_document record;
  v_job_id uuid;
  v_msg_id bigint;
begin
  if not public.can_document_action(p_actor_id, p_document_id, 'delete') then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.auth_denied',
      p_document_id,
      null,
      jsonb_build_object(
        'resource_type', 'document',
        'resource_id', p_document_id,
        'requested_action', 'delete'
      ),
      p_request_id,
      jsonb_build_object('reason', 'missing delete or manage grant')
    );
    return;
  end if;

  update public.kb_documents d
  set status = 'delete_queued',
      deleted_at = coalesce(deleted_at, now()),
      deleted_by = coalesce(deleted_by, p_actor_id),
      delete_requested_at = coalesce(delete_requested_at, now()),
      delete_generation = case
        when deleted_at is null then delete_generation + 1
        else delete_generation
      end,
      last_error = null,
      last_error_stage = null
  where d.id = p_document_id
    and d.status <> 'deleted'
  returning d.id, d.document_version, d.delete_generation
  into v_document;

  if not found then
    raise exception 'document % is not available for delete', p_document_id;
  end if;

  update public.kb_jobs
  set status = 'cancelled',
      locked_by = null,
      locked_until = null,
      finished_at = now(),
      last_error = 'cancelled by delete request'
  where document_id = p_document_id
    and stage in ('parse', 'index')
    and status in ('queued', 'running', 'failed');

  insert into public.kb_jobs (
    document_id,
    document_version,
    stage,
    status,
    pgmq_queue,
    payload_json
  )
  values (
    p_document_id,
    v_document.document_version,
    'delete',
    'queued',
    'kb_delete_queue',
    jsonb_build_object('reason', p_reason, 'delete_generation', v_document.delete_generation)
  )
  on conflict (document_id, document_version, stage)
  where status in ('queued', 'running', 'failed')
  do update
  set updated_at = now()
  returning id
  into v_job_id;

  select sent.msg_id
  into v_msg_id
  from pgmq.send(
    'kb_delete_queue',
    jsonb_build_object('job_id', v_job_id::text)
  ) as sent(msg_id)
  limit 1;

  update public.kb_jobs
  set pgmq_queue = 'kb_delete_queue',
      pgmq_msg_id = v_msg_id
  where id = v_job_id;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.delete_requested',
    p_document_id,
    null,
    jsonb_build_object('delete_generation', v_document.delete_generation),
    p_request_id,
    jsonb_build_object(
      'job_id', v_job_id,
      'msg_id', v_msg_id,
      'reason', p_reason,
      'delete_generation', v_document.delete_generation
    )
  );

  return query select p_document_id, v_job_id, v_msg_id, v_document.delete_generation;
end;
$$;

create or replace function public.request_reindex(
  p_document_id uuid,
  p_actor_id uuid default null,
  p_reason text default null,
  p_request_id text default null
)
returns table (document_id uuid, job_id uuid, msg_id bigint)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
#variable_conflict use_column
declare
  v_job_id uuid;
  v_msg_id bigint;
begin
  if not public.can_document_action(p_actor_id, p_document_id, 'reindex') then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.auth_denied',
      p_document_id,
      null,
      jsonb_build_object(
        'resource_type', 'document',
        'resource_id', p_document_id,
        'requested_action', 'reindex'
      ),
      p_request_id,
      jsonb_build_object('reason', 'missing reindex or manage grant')
    );
    return;
  end if;

  select enqueued.job_id, enqueued.msg_id
  into v_job_id, v_msg_id
  from public.enqueue_index_from_processed_s3_ready(
    p_document_id,
    p_actor_id,
    p_request_id,
    jsonb_build_object('reason', p_reason, 'trigger', 'request_reindex')
  ) as enqueued
  limit 1;

  if v_job_id is null then
    return;
  end if;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.reindex_requested',
    p_document_id,
    null,
    '{}'::jsonb,
    p_request_id,
    jsonb_build_object('job_id', v_job_id, 'msg_id', v_msg_id, 'reason', p_reason)
  );

  return query select p_document_id, v_job_id, v_msg_id;
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'write_kb_audit_event',
        'kb_actor_principals',
        'can_collection_action',
        'can_read_document',
        'can_document_action',
        'create_kb_group',
        'add_kb_group_member',
        'remove_kb_group_member',
        'create_kb_grant',
        'revoke_kb_grant',
        'list_kb_grants_for_resource',
        'list_kb_grants_for_principal',
        'request_delete',
        'request_reindex'
      )
  loop
    execute format('revoke all on function %I.%I(%s) from public', r.nspname, r.proname, r.args);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %I.%I(%s) from anon', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on function %I.%I(%s) from authenticated', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %I.%I(%s) to service_role', r.nspname, r.proname, r.args);
    end if;
  end loop;
end $$;
