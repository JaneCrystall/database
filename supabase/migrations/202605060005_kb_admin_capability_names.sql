drop function if exists public.get_kb_admin_capabilities(uuid);

create or replace function public.get_kb_admin_capabilities(p_actor_id uuid)
returns table (
  can_view_console boolean,
  can_view_documents boolean,
  can_view_jobs boolean,
  can_view_audit_events boolean,
  can_retry boolean,
  can_reindex boolean,
  can_reparse boolean,
  can_delete boolean,
  can_review_metadata boolean,
  can_view_health boolean,
  role text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_read boolean;
  v_has_operator boolean;
  v_has_delete boolean;
  v_has_manage boolean;
  v_owns_documents boolean;
begin
  v_has_read := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['read'::public.kb_grant_action]
  );
  v_has_operator := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['reindex'::public.kb_grant_action]
  );
  v_has_delete := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['delete'::public.kb_grant_action]
  );
  v_has_manage := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['manage'::public.kb_grant_action]
  );

  select exists (
    select 1
    from public.kb_documents d
    where p_actor_id is not null
      and d.deleted_at is null
      and (d.created_by = p_actor_id or d.owner_user_id = p_actor_id)
  )
  into v_owns_documents;

  return query
  select
    (p_actor_id is not null and (v_has_read or v_has_operator or v_has_delete or v_has_manage or v_owns_documents)) as can_view_console,
    (p_actor_id is not null and (v_has_read or v_has_operator or v_has_delete or v_has_manage or v_owns_documents)) as can_view_documents,
    (p_actor_id is not null and (v_has_read or v_has_operator or v_has_delete or v_has_manage or v_owns_documents)) as can_view_jobs,
    (p_actor_id is not null and (v_has_read or v_has_operator or v_has_delete or v_has_manage or v_owns_documents)) as can_view_audit_events,
    (v_has_operator or v_has_manage) as can_retry,
    (v_has_operator or v_has_manage) as can_reindex,
    (v_has_operator or v_has_manage) as can_reparse,
    (v_has_delete or v_has_manage) as can_delete,
    (v_has_operator or v_has_manage) as can_review_metadata,
    (v_has_operator or v_has_delete or v_has_manage) as can_view_health,
    case
      when v_has_manage or v_has_delete then 'admin'
      when v_has_operator then 'operator'
      when v_has_read or v_owns_documents then 'support'
      else 'none'
    end as role;
end;
$$;

revoke all on function public.get_kb_admin_capabilities(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.get_kb_admin_capabilities(uuid) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on function public.get_kb_admin_capabilities(uuid) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.get_kb_admin_capabilities(uuid) to service_role;
  end if;
end $$;
