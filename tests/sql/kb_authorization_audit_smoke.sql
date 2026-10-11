begin;

insert into kb_collections (name, path, content_type)
values ('F01 Auth Smoke', '/smoke/auth', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

insert into kb_collections (name, parent_id, path, content_type)
select 'F01 Auth Smoke Child', id, '/smoke/auth/child', 'papers'
from kb_collections
where path = '/smoke/auth'
on conflict (path) do update
set name = excluded.name,
    parent_id = excluded.parent_id,
    content_type = excluded.content_type;

do $$
#variable_conflict use_variable
declare
  root_collection_id uuid;
  child_collection_id uuid;
  actor_id uuid := gen_random_uuid();
  other_actor_id uuid := gen_random_uuid();
  group_member_id uuid := gen_random_uuid();
  group_id uuid;
  owner_doc_id uuid;
  private_doc_id uuid;
  public_doc_id uuid;
  delete_doc_id uuid;
  reindex_doc_id uuid;
  revoked_grant_id uuid;
  result_count integer;
begin
  select id into root_collection_id
  from kb_collections
  where path = '/smoke/auth';

  select id into child_collection_id
  from kb_collections
  where path = '/smoke/auth/child';

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':owner',
    'owner.pdf',
    '.pdf',
    repeat('1', 64),
    actor_id,
    actor_id
  )
  returning id into owner_doc_id;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    visibility,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':private',
    'private.pdf',
    '.pdf',
    repeat('2', 64),
    'private',
    other_actor_id,
    other_actor_id
  )
  returning id into private_doc_id;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    visibility,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':public',
    'public.pdf',
    '.pdf',
    repeat('3', 64),
    'public',
    other_actor_id,
    other_actor_id
  )
  returning id into public_doc_id;

  if not can_read_document(actor_id, owner_doc_id) then
    raise exception 'owner should be able to read own document';
  end if;

  if can_document_action(actor_id, owner_doc_id, 'delete') then
    raise exception 'owner should not get delete without an explicit grant';
  end if;

  if can_read_document(actor_id, private_doc_id) then
    raise exception 'private document should not be readable before grant';
  end if;

  if not can_read_document(actor_id, public_doc_id) then
    raise exception 'public document should be readable by authenticated actor';
  end if;

  perform create_kb_grant(
    actor_id,
    'subtree',
    root_collection_id,
    'user',
    actor_id,
    array['read'::kb_grant_action],
    null,
    'smoke-subtree-read'
  );

  if not can_read_document(actor_id, private_doc_id) then
    raise exception 'subtree read grant should allow child document read';
  end if;

  perform create_kb_grant(
    actor_id,
    'collection',
    root_collection_id,
    'user',
    actor_id,
    array['upload'::kb_grant_action],
    null,
    'smoke-collection-upload'
  );

  if not can_collection_action(actor_id, root_collection_id, 'upload') then
    raise exception 'collection upload grant should allow exact collection upload';
  end if;

  if can_collection_action(actor_id, child_collection_id, 'upload') then
    raise exception 'collection upload grant should not imply child collection upload';
  end if;

  perform create_kb_grant(
    actor_id,
    'document',
    private_doc_id,
    'user',
    actor_id,
    array['reindex'::kb_grant_action],
    now() - interval '1 minute',
    'smoke-expired-reindex'
  );

  if can_document_action(actor_id, private_doc_id, 'reindex') then
    raise exception 'expired grant should not authorize reindex';
  end if;

  revoked_grant_id := create_kb_grant(
    actor_id,
    'document',
    private_doc_id,
    'user',
    actor_id,
    array['delete'::kb_grant_action],
    null,
    'smoke-delete-revoked'
  );

  if not can_document_action(actor_id, private_doc_id, 'delete') then
    raise exception 'delete grant should authorize before revoke';
  end if;

  if not revoke_kb_grant(actor_id, revoked_grant_id, 'smoke revoke', 'smoke-delete-revoke') then
    raise exception 'revoke_kb_grant should return true';
  end if;

  if can_document_action(actor_id, private_doc_id, 'delete') then
    raise exception 'revoked grant should not authorize delete';
  end if;

  group_id := create_kb_group(actor_id, 'F01 Auth Smoke Group ' || gen_random_uuid(), 'smoke-group');

  if not add_kb_group_member(actor_id, group_id, group_member_id, 'member', 'smoke-group-member') then
    raise exception 'add_kb_group_member should return true';
  end if;

  perform create_kb_grant(
    actor_id,
    'collection',
    child_collection_id,
    'group',
    group_id,
    array['reindex'::kb_grant_action],
    null,
    'smoke-group-reindex'
  );

  if not can_document_action(group_member_id, private_doc_id, 'reindex') then
    raise exception 'group collection grant should authorize group member reindex';
  end if;

  if not remove_kb_group_member(actor_id, group_id, group_member_id, 'smoke-group-member-remove') then
    raise exception 'remove_kb_group_member should return true';
  end if;

  if can_document_action(group_member_id, private_doc_id, 'reindex') then
    raise exception 'removed group member should not keep group authorization';
  end if;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    status,
    processed_manifest_s3_key,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':reindex',
    'reindex.pdf',
    '.pdf',
    repeat('4', 64),
    'processed_s3_ready',
    'processed/smoke/auth/reindex/manifest.json',
    other_actor_id,
    other_actor_id
  )
  returning id into reindex_doc_id;

  select count(*)
  into result_count
  from request_reindex(reindex_doc_id, actor_id, 'denied smoke', 'smoke-reindex-denied');

  if result_count <> 0 then
    raise exception 'request_reindex should return no rows when unauthorized';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where kb_audit_events.actor_id = actor_id
      and kb_audit_events.action = 'kb.auth_denied'
      and kb_audit_events.document_id = reindex_doc_id
      and kb_audit_events.request_id = 'smoke-reindex-denied'
  ) then
    raise exception 'denied reindex should write auth_denied audit';
  end if;

  perform create_kb_grant(
    actor_id,
    'document',
    reindex_doc_id,
    'user',
    actor_id,
    array['reindex'::kb_grant_action],
    null,
    'smoke-reindex-grant'
  );

  select count(*)
  into result_count
  from request_reindex(reindex_doc_id, actor_id, 'allowed smoke', 'smoke-reindex-allowed');

  if result_count <> 1 then
    raise exception 'request_reindex should return one row when authorized';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where kb_audit_events.actor_id = actor_id
      and kb_audit_events.action = 'kb.reindex_requested'
      and kb_audit_events.document_id = reindex_doc_id
      and kb_audit_events.request_id = 'smoke-reindex-allowed'
  ) then
    raise exception 'authorized reindex should write reindex_requested audit';
  end if;

  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    created_by,
    owner_user_id
  )
  values (
    child_collection_id,
    child_collection_id::text || ':delete',
    'delete.pdf',
    '.pdf',
    repeat('5', 64),
    other_actor_id,
    other_actor_id
  )
  returning id into delete_doc_id;

  select count(*)
  into result_count
  from request_delete(delete_doc_id, actor_id, 'denied smoke', 'smoke-delete-denied');

  if result_count <> 0 then
    raise exception 'request_delete should return no rows when unauthorized';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where kb_audit_events.actor_id = actor_id
      and kb_audit_events.action = 'kb.auth_denied'
      and kb_audit_events.document_id = delete_doc_id
      and kb_audit_events.request_id = 'smoke-delete-denied'
  ) then
    raise exception 'denied delete should write auth_denied audit';
  end if;

  perform create_kb_grant(
    actor_id,
    'document',
    delete_doc_id,
    'user',
    actor_id,
    array['delete'::kb_grant_action],
    null,
    'smoke-delete-grant'
  );

  select count(*)
  into result_count
  from request_delete(delete_doc_id, actor_id, 'allowed smoke', 'smoke-delete-allowed');

  if result_count <> 1 then
    raise exception 'request_delete should return one row when authorized';
  end if;

  if not exists (
    select 1
    from kb_audit_events
    where kb_audit_events.actor_id = actor_id
      and kb_audit_events.action = 'kb.delete_requested'
      and kb_audit_events.document_id = delete_doc_id
      and kb_audit_events.request_id = 'smoke-delete-allowed'
  ) then
    raise exception 'authorized delete should write delete_requested audit';
  end if;

  if (
    select count(*)
    from list_kb_grants_for_principal('user', actor_id)
  ) = 0 then
    raise exception 'principal grant listing should return grants';
  end if;
end $$;

rollback;
