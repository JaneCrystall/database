begin;

insert into kb_collections (name, path, content_type)
values ('F02 Reserve Smoke', '/smoke/f02-reserve', 'papers')
on conflict (path) do update
set name = excluded.name,
    content_type = excluded.content_type;

do $$
declare
  collection_id uuid;
  actor_id uuid := gen_random_uuid();
  document_id uuid;
  duplicate_document_id uuid;
  document_version integer;
  document_status kb_document_status;
  duplicate boolean;
  existing_document_id uuid;
  duplicate_count integer;
  failed boolean;
begin
  select id into collection_id
  from kb_collections
  where path = '/smoke/f02-reserve';

  select r.document_id, r.document_version, r.status, r.duplicate, r.existing_document_id
  into document_id, document_version, document_status, duplicate, existing_document_id
  from reserve_document(
    collection_id,
    collection_id::text,
    'reserve-smoke.pdf',
    '.pdf',
    128,
    repeat('c', 64),
    actor_id,
    jsonb_build_object('source', 'smoke'),
    'reserve-smoke-1'
  ) r;

  if document_id is null or document_version <> 1 or document_status <> 'received' then
    raise exception 'reserve_document did not create a received document';
  end if;

  if duplicate or existing_document_id is not null then
    raise exception 'first reserve unexpectedly returned duplicate';
  end if;

  select r.document_id, r.duplicate, r.existing_document_id
  into duplicate_document_id, duplicate, existing_document_id
  from reserve_document(
    collection_id,
    collection_id::text,
    'reserve-smoke-copy.pdf',
    '.pdf',
    128,
    repeat('c', 64),
    actor_id,
    jsonb_build_object('source', 'smoke'),
    'reserve-smoke-2'
  ) r;

  if not duplicate or duplicate_document_id <> document_id or existing_document_id <> document_id then
    raise exception 'duplicate reserve did not return existing document';
  end if;

  select jsonb_array_length(duplicate_uploads)
  into duplicate_count
  from kb_documents
  where id = document_id;

  if duplicate_count <> 1 then
    raise exception 'duplicate upload was not recorded, got %', duplicate_count;
  end if;

  select mark_document_ingest_failed(
    document_id,
    actor_id,
    'reserve-smoke-failed',
    'raw write failed',
    'parse'
  )
  into failed;

  if not failed then
    raise exception 'mark_document_ingest_failed did not update document';
  end if;

  if not exists (
    select 1
    from kb_documents
    where id = document_id
      and status = 'failed'
      and last_error = 'raw write failed'
      and last_error_stage = 'parse'
  ) then
    raise exception 'failed document state was not persisted';
  end if;
end $$;

rollback;
