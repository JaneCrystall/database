create or replace function public.reserve_document(
  p_collection_id uuid,
  p_dedupe_scope text,
  p_original_filename text,
  p_file_ext text,
  p_file_size bigint,
  p_sha256 text,
  p_actor_id uuid,
  p_metadata_json jsonb default '{}'::jsonb,
  p_request_id text default null
)
returns table (
  document_id uuid,
  document_version integer,
  status public.kb_document_status,
  duplicate boolean,
  existing_document_id uuid,
  raw_uri text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_document public.kb_documents%rowtype;
  v_duplicate_uploads jsonb;
begin
  if p_collection_id is null then
    raise exception 'collection_id is required';
  end if;

  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  if p_original_filename is null or btrim(p_original_filename) = '' then
    raise exception 'original_filename is required';
  end if;

  if p_dedupe_scope is null or btrim(p_dedupe_scope) = '' then
    raise exception 'dedupe_scope is required';
  end if;

  if p_sha256 is null or btrim(p_sha256) = '' then
    raise exception 'sha256 is required';
  end if;

  if p_file_size is not null and p_file_size < 0 then
    raise exception 'file_size must be non-negative';
  end if;

  if p_metadata_json is null or jsonb_typeof(p_metadata_json) <> 'object' then
    raise exception 'metadata_json must be a JSON object';
  end if;

  if not exists (
    select 1
    from public.kb_collections
    where id = p_collection_id
  ) then
    raise exception 'collection % does not exist', p_collection_id;
  end if;

  select *
  into v_document
  from public.kb_documents
  where dedupe_scope = btrim(p_dedupe_scope)
    and sha256 = btrim(p_sha256)
    and deleted_at is null
  order by created_at
  limit 1;

  if found then
    v_duplicate_uploads := coalesce(v_document.duplicate_uploads, '[]'::jsonb)
      || jsonb_build_array(
        jsonb_build_object(
          'actor_id', p_actor_id,
          'original_filename', p_original_filename,
          'request_id', p_request_id,
          'uploaded_at', now()
        )
      );

    update public.kb_documents
    set duplicate_uploads = v_duplicate_uploads
    where id = v_document.id;

    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.duplicate_upload_detected',
      v_document.id,
      p_collection_id,
      jsonb_build_object('original_filename', p_original_filename),
      p_request_id,
      jsonb_build_object('sha256', btrim(p_sha256), 'dedupe_scope', btrim(p_dedupe_scope))
    );

    return query
    select
      v_document.id,
      v_document.document_version,
      v_document.status,
      true,
      v_document.id,
      v_document.raw_uri;
    return;
  end if;

  begin
    insert into public.kb_documents (
      primary_collection_id,
      dedupe_scope,
      original_filename,
      file_ext,
      file_size,
      sha256,
      created_by,
      owner_user_id,
      metadata_json
    )
    values (
      p_collection_id,
      btrim(p_dedupe_scope),
      p_original_filename,
      nullif(btrim(coalesce(p_file_ext, '')), ''),
      p_file_size,
      btrim(p_sha256),
      p_actor_id,
      p_actor_id,
      p_metadata_json
    )
    returning *
    into v_document;
  exception
    when unique_violation then
      select *
      into v_document
      from public.kb_documents
      where dedupe_scope = btrim(p_dedupe_scope)
        and sha256 = btrim(p_sha256)
        and deleted_at is null
      order by created_at
      limit 1;

      if not found then
        raise exception 'duplicate document lookup failed after race';
      end if;

      v_duplicate_uploads := coalesce(v_document.duplicate_uploads, '[]'::jsonb)
        || jsonb_build_array(
          jsonb_build_object(
            'actor_id', p_actor_id,
            'original_filename', p_original_filename,
            'request_id', p_request_id,
            'uploaded_at', now()
          )
        );

      update public.kb_documents
      set duplicate_uploads = v_duplicate_uploads
      where id = v_document.id;

      perform public.write_kb_audit_event(
        p_actor_id,
        'kb.duplicate_upload_detected',
        v_document.id,
        p_collection_id,
        jsonb_build_object('original_filename', p_original_filename),
        p_request_id,
        jsonb_build_object('sha256', btrim(p_sha256), 'dedupe_scope', btrim(p_dedupe_scope))
      );

      return query
      select
        v_document.id,
        v_document.document_version,
        v_document.status,
        true,
        v_document.id,
        v_document.raw_uri;
      return;
  end;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.document_reserved',
    v_document.id,
    p_collection_id,
    jsonb_build_object('original_filename', p_original_filename),
    p_request_id,
    jsonb_build_object('sha256', btrim(p_sha256), 'dedupe_scope', btrim(p_dedupe_scope))
  );

  return query
  select
    v_document.id,
    v_document.document_version,
    v_document.status,
    false,
    null::uuid,
    v_document.raw_uri;
end;
$$;

create or replace function public.mark_document_ingest_failed(
  p_document_id uuid,
  p_actor_id uuid default null,
  p_request_id text default null,
  p_error text default null,
  p_stage public.kb_job_stage default 'parse'
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_updated boolean;
begin
  update public.kb_documents
  set status = 'failed',
      last_error = coalesce(nullif(p_error, ''), 'ingest failed'),
      last_error_stage = p_stage
  where id = p_document_id
    and deleted_at is null
    and status in ('received', 'raw_stored', 'failed')
  returning true
  into v_updated;

  if coalesce(v_updated, false) and p_actor_id is not null then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.ingest_failed',
      p_document_id,
      null,
      '{}'::jsonb,
      p_request_id,
      jsonb_build_object(
        'error', coalesce(nullif(p_error, ''), 'ingest failed'),
        'stage', p_stage
      )
    );
  end if;

  return coalesce(v_updated, false);
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
        'reserve_document',
        'mark_document_ingest_failed'
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
