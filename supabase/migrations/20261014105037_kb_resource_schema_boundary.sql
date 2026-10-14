-- M1-03: explicit internal storage and gateway API boundary.
-- Preserve all prior migration bytes and existing rows/OIDs via SET SCHEMA.
-- No legacy table, queue, profile or hosted API configuration is changed.
begin;
create schema private authorization postgres;
create schema api authorization postgres;
revoke all on schema private, api from public, anon, authenticated, service_role;
-- Gateway needs USAGE only to invoke the two private implementations through
-- SECURITY INVOKER wrappers. This does not grant table or helper access.
grant usage on schema private, api to service_role;

alter table public.kb_resource_entries set schema private;
alter table public.kb_resource_document_links set schema private;
alter table public.kb_resource_requests set schema private;
alter function public.kb_resource_normalize_doi(text) set schema private;
alter function public.kb_resource_legacy_metadata(jsonb) set schema private;
alter function public.kb_resource_validate_metadata(jsonb,jsonb,boolean) set schema private;
alter function public.kb_resource_command(uuid,uuid,text,uuid,jsonb) set schema private;
alter function public.kb_resource_get(uuid,uuid,uuid) set schema private;

-- Rebind textual PL/pgSQL references; business rules remain unchanged.
create or replace function private.kb_resource_normalize_doi(p_value text) returns text
language sql immutable set search_path=pg_catalog as $$
 select nullif(lower(regexp_replace(btrim(p_value),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i')),'')
$$;

create or replace function private.kb_resource_legacy_metadata(p_ref jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare v jsonb; v_id uuid;
begin
  v_id := (p_ref->>'id')::uuid;
  case p_ref->>'table'
    when 'journals' then
      select jsonb_strip_nulls(jsonb_build_object('title',j.title,'doi',j.doi,'authors',j.authors,
        'published_date',j.date)) into v from public.journals j where j.id=v_id for share;
    when 'esg_meta' then
      select jsonb_strip_nulls(jsonb_build_object('title',e.report_title,'organization',e.company_name,
        'report_year',extract(year from e.report_end_date)::integer,'language',e.language))
        into v from public.esg_meta e where e.id=v_id for share;
    when 'reports' then
      select jsonb_strip_nulls(jsonb_build_object('title',r.title,'organization',r.issuing_organization::jsonb,
        'published_date',r.release_date::date,'source_ref',r.url))
        into v from public.reports r where r.id=v_id for share;
    else raise exception using errcode='22023',message='RESOURCE_LEGACY_ADAPTER_INVALID';
  end case;
  if v is null then raise exception using errcode='P0002',message='RESOURCE_LEGACY_NOT_FOUND'; end if;
  return v;
end $$;

create or replace function private.kb_resource_validate_metadata(p_profile jsonb,p_metadata jsonb,p_complete boolean)
returns void language plpgsql set search_path=pg_catalog as $$
declare f record; k text; v jsonb; t text;
begin
  if jsonb_typeof(p_metadata) is distinct from 'object' then
    raise exception using errcode='22023',message='RESOURCE_METADATA_OBJECT_REQUIRED';
  end if;
  for f in select * from jsonb_each(p_metadata) loop
    t := p_profile->'fields'->>f.key;
    v := f.value;
    if t is null or not coalesce(case t
      when 'string' then jsonb_typeof(v)='string'
      when 'integer' then jsonb_typeof(v)='number' and v::text ~ '^-?[0-9]+$'
      when 'array<string>' then jsonb_typeof(v)='array'
      when 'date' then jsonb_typeof(v)='string' and (v#>>'{}') ~ '^\d{4}-\d{2}-\d{2}$'
      when 'object' then jsonb_typeof(v)='object'
      when 'array' then jsonb_typeof(v)='array'
      else false end,false) then
      raise exception using errcode='22023',message='RESOURCE_FIELD_TYPE_INVALID',detail=f.key;
    end if;
    if t='date' then perform (v#>>'{}')::date; end if;
    if t='array<string>' and exists(select from jsonb_array_elements(v) x where jsonb_typeof(x)<>'string') then
      raise exception using errcode='22023',message='RESOURCE_FIELD_TYPE_INVALID',detail=f.key;
    end if;
  end loop;
  if p_complete then
    for k in select jsonb_array_elements_text(p_profile->'required_fields') loop
      if not p_metadata ? k or p_metadata->k='null'::jsonb or btrim(p_metadata->>k)='' then
        raise exception using errcode='22023',message='RESOURCE_REQUIRED_FIELD_MISSING',detail=k;
      end if;
    end loop;
  end if;
end $$;

create or replace function private.kb_resource_command(
  p_actor_id uuid,p_collection_id uuid,p_operation text,p_request_id uuid,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare
  e private.kb_resource_entries%rowtype;
  l private.kb_resource_document_links%rowtype;
  old_l private.kb_resource_document_links%rowtype;
  d public.kb_documents%rowtype;
  q private.kb_resource_requests%rowtype;
  profile jsonb; cfg_path text; binding jsonb; c jsonb; before_effective jsonb; old_candidates jsonb;
  candidate_id uuid; v_entry_id uuid; v_document_id uuid; snapshot jsonb; expected bigint; candidate_count integer;
  matching_ids uuid[]; result jsonb; digest text; metadata jsonb; reason text; field text; action public.kb_grant_action;
  reserved record; enqueued record; changed boolean := false; invalidate boolean := false;
begin
  if p_actor_id is null or p_collection_id is null or p_request_id is null then
    raise exception using errcode='22023',message='RESOURCE_ID_REQUIRED';
  end if;
  if p_operation is null or p_operation not in ('upsert','attach','override','review','reserve','publish','rebind') then
    raise exception using errcode='22023',message='RESOURCE_OPERATION_INVALID';
  end if;
  action := case when p_operation in ('review','override','rebind') then 'manage'::public.kb_grant_action else 'upload'::public.kb_grant_action end;
  if not public.can_collection_action(p_actor_id,p_collection_id,action) then
    raise exception using errcode='42501',message='RESOURCE_FORBIDDEN';
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>65536 then
    raise exception using errcode='22023',message='RESOURCE_PAYLOAD_INVALID';
  end if;
  -- Collection-scoped short transactions serialize source/DOI matching and dedupe races.
  -- No file/network IO takes place while holding this lock. Hash collisions only add contention.
  perform pg_advisory_xact_lock(hashtextextended('kb-resource:'||p_collection_id::text,0));
  if not public.can_collection_action(p_actor_id,p_collection_id,action) then
    raise exception using errcode='42501',message='RESOURCE_FORBIDDEN';
  end if;
  select metadata_schema_json->'resource_profile',path into profile,cfg_path
    from public.kb_collections where id=p_collection_id for share;
  if profile is null or profile->>'id' is null or not (profile->>'version' ~ '^[1-9][0-9]*$')
    or jsonb_typeof(profile->'fields') is distinct from 'object'
    or jsonb_typeof(profile->'required_fields') is distinct from 'array'
    or jsonb_typeof(profile->'source_bindings') is distinct from 'array'
    or jsonb_typeof(profile->'matching') is distinct from 'array'
    or not coalesce(profile->>'metadata_mode' in ('managed','legacy_ref'),false) then
    raise exception using errcode='22023',message='RESOURCE_PROFILE_NOT_CONFIGURED';
  end if;
  digest := encode(extensions.digest(p_payload::text,'sha256'),'hex');
  select * into q from private.kb_resource_requests r where r.actor_id=p_actor_id
    and r.collection_id=p_collection_id and r.operation=p_operation and r.request_id=p_request_id;
  if found then
    if q.payload_digest<>digest then raise exception using errcode='40001',message='RESOURCE_REQUEST_CONFLICT'; end if;
    return q.result_json; -- Only after current authorization; result is a historical receipt.
  end if;
  expected := (p_payload->>'expected_revision')::bigint;
  if expected is null or expected<0 then raise exception using errcode='22023',message='RESOURCE_REVISION_REQUIRED'; end if;
  reason := nullif(btrim(p_payload->>'reason'),'');
  if reason is null then raise exception using errcode='22023',message='RESOURCE_REASON_REQUIRED'; end if;
  v_entry_id := (p_payload->>'entry_id')::uuid;
  if v_entry_id is not null then
    select * into e from private.kb_resource_entries r where r.id=v_entry_id and r.collection_id=p_collection_id for update;
    if not found then raise exception using errcode='P0002',message='RESOURCE_NOT_FOUND'; end if;
  elsif p_operation='upsert' then
    select * into binding from jsonb_array_elements(profile->'source_bindings') b where b->>'id'=p_payload->>'binding_id';
    if binding is null or nullif(btrim(p_payload->>'external_key'),'') is null then
      raise exception using errcode='22023',message='RESOURCE_SOURCE_REQUIRED';
    end if;
    select * into e from private.kb_resource_entries r where r.collection_id=p_collection_id
      and r.primary_source_binding_id=p_payload->>'binding_id' and r.external_key=p_payload->>'external_key' for update;
    if not found and profile->'matching' ? 'unique_normalized_doi'
      and private.kb_resource_normalize_doi(p_payload->'metadata'->>'doi') is not null then
      select array_agg(r.id) into matching_ids from private.kb_resource_entries r where r.collection_id=p_collection_id
        and private.kb_resource_normalize_doi((r.source_metadata||r.manual_overrides)->>'doi')=
          private.kb_resource_normalize_doi(p_payload->'metadata'->>'doi');
      if cardinality(matching_ids)>1 then raise exception using errcode='40001',message='RESOURCE_MATCH_CONFLICT'; end if;
      if cardinality(matching_ids)=1 then select * into e from private.kb_resource_entries where id=matching_ids[1] for update; end if;
    end if;
  else raise exception using errcode='22023',message='RESOURCE_ENTRY_REQUIRED';
  end if;
  if e.id is null then
    if expected<>0 then raise exception using errcode='40001',message='RESOURCE_REVISION_CONFLICT'; end if;
    if (profile->>'metadata_mode'='managed' and p_payload ? 'legacy_ref') or
       (profile->>'metadata_mode'='legacy_ref' and (profile->>'legacy_enabled' is distinct from 'true'
         or p_payload->'legacy_ref'->>'table' is distinct from profile->>'legacy_table')) then
      raise exception using errcode='22023',message='RESOURCE_LEGACY_DISABLED_OR_MISMATCH';
    end if;
    insert into private.kb_resource_entries(collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref)
    values(p_collection_id,p_payload->>'binding_id',p_payload->>'external_key',profile,profile->>'metadata_mode',p_payload->'legacy_ref') returning * into e;
    changed := true;
  else
    if e.revision<>expected then raise exception using errcode='40001',message='RESOURCE_REVISION_CONFLICT'; end if;
    if e.profile_json<>profile and p_operation<>'rebind' then raise exception using errcode='40001',message='RESOURCE_PROFILE_CHANGED'; end if;
  end if;
  before_effective := e.source_metadata||e.manual_overrides;
  old_candidates := e.candidates;
  if p_operation='upsert' then
    select * into binding from jsonb_array_elements(profile->'source_bindings') b where b->>'id'=p_payload->>'binding_id';
    if binding is null then raise exception using errcode='22023',message='RESOURCE_BINDING_INVALID'; end if;
    if e.metadata_mode='legacy_ref' then
      if p_payload ? 'metadata' or (p_payload ? 'legacy_ref' and p_payload->'legacy_ref'<>e.legacy_ref) then
        raise exception using errcode='22023',message='RESOURCE_LEGACY_READ_ONLY';
      end if;
      metadata := private.kb_resource_legacy_metadata(e.legacy_ref);
    else
      if p_payload ? 'legacy_ref' then raise exception using errcode='22023',message='RESOURCE_LEGACY_READ_ONLY'; end if;
      metadata := coalesce(p_payload->'metadata','{}'::jsonb);
      perform private.kb_resource_validate_metadata(profile,metadata,false);
      -- Only the primary source may refresh facts. Other bindings match/attach, not replace authority.
      if p_payload->>'binding_id'<>e.primary_source_binding_id and metadata<>e.source_metadata then
        raise exception using errcode='40001',message='RESOURCE_SECONDARY_SOURCE_PROPOSAL';
      end if;
    end if;
    if metadata<>e.source_metadata then
      e.source_metadata := metadata;
      changed := true;
    end if;
    e.field_provenance := e.field_provenance||jsonb_build_object('source',jsonb_build_object(
      'binding_id',e.primary_source_binding_id,'actor_id',p_actor_id,'request_id',p_request_id,'observed_at',now(),
      'source_revision',p_payload->'source_revision','payload_digest',digest));
  elsif p_operation='attach' then
    c := p_payload->'candidate';
    candidate_id := (c->>'candidate_id')::uuid;
    select * into binding from jsonb_array_elements(profile->'source_bindings') b where b->>'id'=c->>'binding_id';
    if candidate_id is null or binding->>'kind' is distinct from 'file-snapshot'
      or not coalesce(c->>'sha256' ~ '^[0-9a-f]{64}$',false)
      or not coalesce(c->>'size' ~ '^[1-9][0-9]*$',false)
      or c->>'stable' is distinct from 'true' or c->>'pdf_valid' is distinct from 'true'
      or not coalesce(c->>'relative_locator' ~ '^[^/\\]+(/[^/\\]+)*\.pdf$',false)
      or c->>'relative_locator' ~ '(^|/)(\.|\.\.)(/|$)|[[:cntrl:]%?#]' then
      raise exception using errcode='22023',message='RESOURCE_CANDIDATE_INVALID';
    end if;
    c := jsonb_build_object('candidate_id',candidate_id,'binding_id',c->>'binding_id',
      'relative_locator',c->>'relative_locator','sha256',c->>'sha256','size',(c->>'size')::bigint);
    e.candidates := e.candidates||jsonb_build_object(candidate_id::text,c);
    changed := e.candidates<>old_candidates;
    invalidate := changed;
    select count(*) into candidate_count from jsonb_object_keys(e.candidates);
    if candidate_count>1 and changed then e.review_state:='conflict'; end if;
  elsif p_operation='rebind' then
    if profile->>'id' is distinct from e.profile_json->>'id'
      or (profile->>'version')::integer <= (e.profile_json->>'version')::integer
      or profile->>'metadata_mode' is distinct from e.metadata_mode
      or (e.metadata_mode='legacy_ref' and (profile->>'legacy_enabled' is distinct from 'true'
        or profile->>'legacy_table' is distinct from e.legacy_ref->>'table'))
      or not exists(select from jsonb_array_elements(profile->'source_bindings') b where b->>'id'=e.primary_source_binding_id)
      or exists(select from jsonb_each(e.candidates) c where not exists(
        select from jsonb_array_elements(profile->'source_bindings') b
        where b->>'id'=c.value->>'binding_id' and b->>'kind'='file-snapshot')) then
      raise exception using errcode='22023',message='RESOURCE_PROFILE_REBIND_INVALID';
    end if;
    perform private.kb_resource_validate_metadata(profile,before_effective,false);
    e.profile_json:=profile;
    changed:=true; invalidate:=true;
  elsif p_operation='override' then
    metadata := coalesce(p_payload->'fields','{}'::jsonb);
    perform private.kb_resource_validate_metadata(profile,metadata,false);
    e.manual_overrides := e.manual_overrides||metadata;
    -- Retain attribution per current override, not just the last editor of any field.
    for field in select jsonb_object_keys(metadata) loop
      e.field_provenance := e.field_provenance||jsonb_build_object('manual',
        coalesce(e.field_provenance->'manual','{}'::jsonb)||jsonb_build_object(field,jsonb_build_object(
          'actor_id',p_actor_id,'at',now(),'reason',reason,'request_id',p_request_id)));
    end loop;
    for field in select jsonb_array_elements_text(coalesce(p_payload->'release_fields','[]'::jsonb)) loop
      e.manual_overrides := e.manual_overrides-field;
      e.field_provenance := e.field_provenance||jsonb_build_object('manual',
        coalesce(e.field_provenance->'manual','{}'::jsonb)-field);
    end loop;
    changed := true;
  else
    if e.metadata_mode='legacy_ref' and private.kb_resource_legacy_metadata(e.legacy_ref)<>e.source_metadata then
      raise exception using errcode='40001',message='RESOURCE_SOURCE_CHANGED';
    end if;
    if p_operation='review' then
      if p_payload->>'decision'='approve' then
        perform private.kb_resource_validate_metadata(profile,before_effective,true);
        candidate_id := (p_payload->>'candidate_id')::uuid;
        c := e.candidates->candidate_id::text;
        if c is null then raise exception using errcode='22023',message='RESOURCE_CANDIDATE_REQUIRED'; end if;
        e.review_state := 'approved';
        e.approved_revision := e.revision+1;
        e.approved_candidate_id := candidate_id;
        e.approved_sha256 := c->>'sha256';
        e.approved_size := (c->>'size')::bigint;
        e.approved_by := p_actor_id;
        e.approved_at := now();
      elsif p_payload->>'decision'='reject' then
        e.review_state := 'rejected'; invalidate:=true;
      else raise exception using errcode='22023',message='RESOURCE_REVIEW_INVALID'; end if;
      changed := true;
    else
      if e.review_state<>'approved' or (p_payload->>'approved_revision')::bigint is distinct from e.approved_revision then
        raise exception using errcode='40001',message='RESOURCE_APPROVAL_REQUIRED';
      end if;
      c := e.candidates->e.approved_candidate_id::text;
      select * into l from private.kb_resource_document_links x where x.entry_id=e.id
        and x.approved_revision=e.approved_revision and x.publish_state<>'superseded' for update;
      if p_operation='reserve' then
        if l.id is null then
          -- Retire stale reservations; an approval never silently inherits a different snapshot.
          update private.kb_resource_document_links set publish_state='superseded',active=false
            where entry_id=e.id and publish_state='reserved';
          snapshot := jsonb_build_object('resource_id',e.id,'metadata',before_effective,'profile',profile,
            'source_ref',jsonb_build_object('binding_id',e.primary_source_binding_id,'external_key',e.external_key),
            'provenance',e.field_provenance,'approved_by',e.approved_by,'approved_at',e.approved_at);
          -- Take existing job locks before reserve_document takes its document lock.
          perform j.id from public.kb_jobs j join public.kb_documents doc on doc.id=j.document_id
            where doc.dedupe_scope=p_collection_id::text and doc.sha256=e.approved_sha256
              and doc.deleted_at is null order by j.id for update of j;
          select * into reserved from public.reserve_document(p_collection_id,p_collection_id::text,
            e.id::text||'.pdf','.pdf',e.approved_size,e.approved_sha256,p_actor_id,'{}',p_request_id::text);
          v_document_id := reserved.document_id;
          select * into d from public.kb_documents where id=v_document_id for update;
          if d.primary_collection_id<>p_collection_id or d.file_size is distinct from e.approved_size
             or exists(select from private.kb_resource_document_links x where x.document_id=d.id
               and x.publish_state<>'superseded' and x.entry_id<>e.id) then
            raise exception using errcode='40001',message='RESOURCE_DOCUMENT_CONFLICT';
          end if;
          select * into old_l from private.kb_resource_document_links x
            where x.entry_id=e.id and x.document_id=d.id order by x.content_revision desc limit 1 for update;
          if old_l.id is not null then
            -- Same bytes: retain document/content identity, start a fresh processing generation.
            if d.status in ('delete_queued','deleting','deleted') then
              raise exception using errcode='40001',message='RESOURCE_DOCUMENT_CONFLICT';
            end if;
            perform public.write_kb_audit_event(p_actor_id,'kb.resource.snapshot_superseded',d.id,p_collection_id,
              jsonb_build_object('entry_id',e.id),p_request_id::text,to_jsonb(old_l));
            update public.kb_jobs set status='cancelled',locked_by=null,locked_until=null,finished_at=now(),
              last_error='resource approval superseded' where kb_jobs.document_id=d.id and stage in ('parse','index','s3_ready') and status in ('queued','running','failed');
            update public.kb_documents set document_version=document_version+1,status='received',
              processed_manifest_local_uri=null,processed_manifest_s3_key=null,processed_manifest_hash=null,
              processed_artifact_uuid=null,processed_s3_ready_at=null,chunk_count=null,parse_time=null,index_time=null,
              opensearch_indexed=false,pinecone_indexed=false where id=d.id;
            if old_l.active then
            update private.kb_resource_document_links set active=false,publish_state='reserved',job_id=null,published_at=null,
              approved_revision=e.approved_revision,candidate_json=c,metadata_snapshot=snapshot,
              effective_metadata_revision=e.approved_revision where id=old_l.id returning * into l;
            else
              insert into private.kb_resource_document_links(entry_id,document_id,content_revision,approved_revision,
                candidate_json,metadata_snapshot,effective_metadata_revision)
              select e.id,d.id,coalesce(max(x.content_revision),0)+1,e.approved_revision,c,snapshot,e.approved_revision
                from private.kb_resource_document_links x where x.entry_id=e.id returning * into l;
            end if;
          else
            -- An unmanaged processed document cannot be adopted by hash alone.
            if d.status not in ('received','raw_stored','failed') or exists(select from public.kb_jobs where kb_jobs.document_id=d.id) then
              raise exception using errcode='40001',message='RESOURCE_DOCUMENT_ALREADY_PROCESSING';
            end if;
            insert into private.kb_resource_document_links(entry_id,document_id,content_revision,approved_revision,
              candidate_json,metadata_snapshot,effective_metadata_revision)
            select e.id,d.id,coalesce(max(x.content_revision),0)+1,e.approved_revision,c,snapshot,e.approved_revision
              from private.kb_resource_document_links x where x.entry_id=e.id returning * into l;
          end if;
        end if;
      else
        if l.id is null or l.document_id is distinct from (p_payload->>'document_id')::uuid then
          raise exception using errcode='40001',message='RESOURCE_RESERVATION_REQUIRED';
        end if;
        -- Publisher attests actual filesystem checks; DB cannot read or validate a NAS mount.
        if p_payload->>'sha256' is distinct from e.approved_sha256
          or (p_payload->>'size')::bigint is distinct from e.approved_size
          or p_payload->>'copy_verified' is distinct from 'true'
          or p_payload->>'raw_relative_path' is distinct from trim(both '/' from cfg_path)||'/'||l.document_id::text||'.pdf'
          or p_payload->>'raw_uri' is distinct from 'nas://raw/'||(p_payload->>'raw_relative_path')
          or cfg_path ~ '(^|/)(\.|\.\.)(/|$)|[[:cntrl:]\\%?#]'
          or trim(both '/' from cfg_path) ~ '//'  then
          raise exception using errcode='22023',message='RESOURCE_PUBLICATION_INVALID';
        end if;
        if l.publish_state='reserved' then
          -- Worker finalization locks jobs before documents. Keep that order when invalidating old work.
          for old_l in select * from private.kb_resource_document_links x where x.entry_id=e.id and x.active for update loop
            update public.kb_jobs set status='cancelled',locked_by=null,locked_until=null,finished_at=now(),last_error='resource content superseded'
              where kb_jobs.document_id=old_l.document_id and stage in ('parse','index','s3_ready') and status in ('queued','running','failed');
            update public.kb_documents set document_version=document_version+1,status='failed',
              opensearch_indexed=false,pinecone_indexed=false,last_error='resource content superseded'
              where id=old_l.document_id and deleted_at is null and status not in ('delete_queued','deleting','deleted');
            update private.kb_resource_document_links set active=false,publish_state='superseded' where id=old_l.id;
          end loop;
          select * into d from public.kb_documents where id=l.document_id for update;
          if d.deleted_at is not null or d.sha256<>e.approved_sha256 or d.file_size is distinct from e.approved_size
             or d.primary_collection_id<>p_collection_id then
            raise exception using errcode='40001',message='RESOURCE_DOCUMENT_CONFLICT';
          end if;
          update public.kb_documents set metadata_json=l.metadata_snapshot,metadata_reviewed_at=e.approved_at,
            metadata_reviewed_by=e.approved_by where id=d.id;
          select * into enqueued from public.mark_raw_ready_and_enqueue_parse(d.id,p_payload->>'raw_uri',
            e.approved_size,e.approved_sha256,p_actor_id,p_request_id::text,
            jsonb_build_object('resource_id',e.id,'approved_revision',e.approved_revision,'content_revision',l.content_revision));
          update private.kb_resource_document_links set active=true,publish_state='published',job_id=enqueued.job_id,published_at=now()
            where id=l.id returning * into l;
        end if;
      end if;
    end if;
  end if;
  invalidate := invalidate or (e.source_metadata||e.manual_overrides)<>before_effective;
  if invalidate then
    for old_l in select * from private.kb_resource_document_links x where x.entry_id=e.id and x.active for update loop
      update public.kb_jobs set status='cancelled',locked_by=null,locked_until=null,finished_at=now(),
        last_error='resource approval invalidated' where kb_jobs.document_id=old_l.document_id and stage in ('parse','index','s3_ready') and status in ('queued','running','failed');
      update public.kb_documents set document_version=document_version+1,status='failed',opensearch_indexed=false,
        pinecone_indexed=false,last_error='resource approval invalidated' where id=old_l.document_id and deleted_at is null and status not in ('delete_queued','deleting','deleted');
    end loop;
    if e.review_state not in ('conflict','rejected') then e.review_state:='pending'; end if;
    e.approved_revision:=null; e.approved_candidate_id:=null; e.approved_sha256:=null;
    e.approved_size:=null; e.approved_by:=null; e.approved_at:=null;
  end if;
  -- Creation consumes expected_revision=0 and returns revision=1; subsequent changes advance once.
  if changed and not (expected=0 and p_operation='upsert') then e.revision:=e.revision+1; end if;
  update private.kb_resource_entries set profile_json=e.profile_json,source_metadata=e.source_metadata,manual_overrides=e.manual_overrides,
    field_provenance=e.field_provenance,candidates=e.candidates,revision=e.revision,review_state=e.review_state,
    approved_revision=e.approved_revision,approved_candidate_id=e.approved_candidate_id,approved_sha256=e.approved_sha256,
    approved_size=e.approved_size,approved_by=e.approved_by,approved_at=e.approved_at,updated_at=now() where id=e.id;
  result := jsonb_build_object('entry_id',e.id,'revision',e.revision,'review_state',e.review_state,
    'approved_revision',e.approved_revision,'approved_candidate_id',e.approved_candidate_id,
    'approved_sha256',e.approved_sha256,'approved_size',e.approved_size);
  if l.id is not null then
    result := result||jsonb_build_object('document_id',l.document_id,'content_revision',l.content_revision,
      'publish_state',l.publish_state,'job_id',l.job_id);
  end if;
  perform public.write_kb_audit_event(p_actor_id,'kb.resource.'||p_operation,l.document_id,p_collection_id,
    jsonb_build_object('entry_id',e.id),p_request_id::text,
    jsonb_build_object('reason',reason,'payload_digest',digest,'input',p_payload,'result',result));
  insert into private.kb_resource_requests values(p_actor_id,p_collection_id,p_operation,p_request_id,digest,result,now());
  return result;
end $$;

create or replace function private.kb_resource_get(p_actor_id uuid,p_collection_id uuid,p_entry_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare e private.kb_resource_entries%rowtype; links jsonb; source_stale boolean := false; profile_stale boolean;
begin
  if p_actor_id is null or not public.can_collection_action(p_actor_id,p_collection_id,'read') then
    raise exception using errcode='42501',message='RESOURCE_FORBIDDEN';
  end if;
  select * into e from private.kb_resource_entries where id=p_entry_id and collection_id=p_collection_id;
  if not found then raise exception using errcode='P0002',message='RESOURCE_NOT_FOUND'; end if;
  select metadata_schema_json->'resource_profile' is distinct from e.profile_json into profile_stale
    from public.kb_collections where id=p_collection_id;
  if e.metadata_mode='legacy_ref' then
    begin
      source_stale := private.kb_resource_legacy_metadata(e.legacy_ref)<>e.source_metadata;
    exception when no_data_found then source_stale:=true;
    end;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('document_version',d.document_version,
    'document_status',d.status,'approval_current',e.review_state='approved' and x.approved_revision=e.approved_revision
      and not source_stale and not profile_stale and d.deleted_at is null and x.active) order by x.content_revision),'[]') into links
    from private.kb_resource_document_links x join public.kb_documents d on d.id=x.document_id where x.entry_id=e.id;
  return to_jsonb(e)||jsonb_build_object('effective_metadata',e.source_metadata||e.manual_overrides,
    'source_stale',source_stale,'profile_stale',profile_stale,'links',links);
end $$;

-- Thin API adapter; privilege elevation lives only in unexposed private.
create function api.kb_resource_command(p_actor_id uuid,p_collection_id uuid,p_operation text,p_request_id uuid,p_payload jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.kb_resource_command(p_actor_id,p_collection_id,p_operation,p_request_id,p_payload); $$;
-- Thin API adapter; privilege elevation lives only in unexposed private.
create function api.kb_resource_get(p_actor_id uuid,p_collection_id uuid,p_entry_id uuid)
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.kb_resource_get(p_actor_id,p_collection_id,p_entry_id); $$;

revoke all on private.kb_resource_entries, private.kb_resource_document_links, private.kb_resource_requests from public,anon,authenticated,service_role;
revoke all on function private.kb_resource_normalize_doi(text) from public,anon,authenticated,service_role;
revoke all on function private.kb_resource_legacy_metadata(jsonb) from public,anon,authenticated,service_role;
revoke all on function private.kb_resource_validate_metadata(jsonb,jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function private.kb_resource_command(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.kb_resource_get(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function api.kb_resource_command(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function api.kb_resource_command(uuid,uuid,text,uuid,jsonb), private.kb_resource_command(uuid,uuid,text,uuid,jsonb) to service_role;
revoke all on function api.kb_resource_get(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function api.kb_resource_get(uuid,uuid,uuid), private.kb_resource_get(uuid,uuid,uuid) to service_role;

comment on table private.kb_resource_entries is 'Resource identity and current review state; managed metadata or read-only legacy source observation; write only through resource commands.';
comment on table private.kb_resource_document_links is 'Versioned PDF association and immutable publication input; does not own PDF bytes or worker execution.';
comment on table private.kb_resource_requests is 'Transactional idempotency receipts; historical command results, not current resource state.';
notify pgrst, 'reload schema';
commit;
