begin;

insert into kb_collections (name, path, content_type)
values ('Smoke Papers', '/smoke/papers', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type
returning id;

delete from kb_collections
where path = '/smoke/retention-default';

insert into kb_collections (name, path, content_type)
values ('Retention Default Smoke', '/smoke/retention-default', 'papers');

do $$
declare
  raw_policy kb_retention_policy;
  processed_policy kb_retention_policy;
begin
  select raw_retention_policy, processed_retention_policy
  into raw_policy, processed_policy
  from kb_collections
  where path = '/smoke/retention-default';

  if raw_policy <> 'delete_immediately'::kb_retention_policy then
    raise exception 'expected raw retention default delete_immediately, got %', raw_policy;
  end if;

  if processed_policy <> 'delete_immediately'::kb_retention_policy then
    raise exception 'expected processed retention default delete_immediately, got %', processed_policy;
  end if;
end $$;

with collection as (
  select id from kb_collections where path = '/smoke/papers'
),
actor as (
  select gen_random_uuid() as id
),
document as (
  insert into kb_documents (
    primary_collection_id,
    dedupe_scope,
    original_filename,
    file_ext,
    sha256,
    created_by,
    owner_user_id
  )
  select
    collection.id,
    collection.id::text,
    'smoke.pdf',
    '.pdf',
    repeat('a', 64),
    actor.id,
    actor.id
  from collection, actor
  returning id, document_version, created_by
)
insert into kb_jobs (document_id, document_version, stage)
select id, document_version, 'parse'
from document
returning id;

do $$
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
begin
  select id into collection_id from kb_collections where path = '/smoke/papers';

  begin
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
      collection_id,
      collection_id::text,
      'duplicate.pdf',
      '.pdf',
      repeat('a', 64),
      actor_id,
      actor_id
    );

    raise exception 'expected duplicate active document to fail';
  exception
    when unique_violation then null;
  end;
end $$;

rollback;
