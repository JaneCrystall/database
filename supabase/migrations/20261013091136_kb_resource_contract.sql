-- M1-03: opt-in resource registry. No collections/profiles or legacy rows are seeded.
-- Configuration is deployment-owned: kb_collections.metadata_schema_json.resource_profile.
-- Caller authentication stays at the trusted gateway; every command checks collection grants.
create table public.kb_resource_entries (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.kb_collections(id),
  primary_source_binding_id text not null check (length(primary_source_binding_id) between 1 and 128),
  external_key text not null check (length(external_key) between 1 and 1024),
  profile_json jsonb not null check (jsonb_typeof(profile_json) = 'object'),
  metadata_mode text not null check (metadata_mode in ('managed','legacy_ref')),
  legacy_ref jsonb,
  source_metadata jsonb not null default '{}' check (jsonb_typeof(source_metadata) = 'object'),
  manual_overrides jsonb not null default '{}' check (jsonb_typeof(manual_overrides) = 'object'),
  field_provenance jsonb not null default '{}' check (jsonb_typeof(field_provenance) = 'object'),
  candidates jsonb not null default '{}' check (jsonb_typeof(candidates) = 'object'),
  revision bigint not null default 1 check (revision > 0),
  review_state text not null default 'pending' check (review_state in ('pending','approved','rejected','conflict')),
  approved_revision bigint,
  approved_candidate_id uuid,
  approved_sha256 text,
  approved_size bigint,
  approved_by uuid,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (collection_id,primary_source_binding_id,external_key),
  check ((metadata_mode='managed' and legacy_ref is null) or
         (metadata_mode='legacy_ref' and jsonb_typeof(legacy_ref)='object' and legacy_ref is not null)),
  check (octet_length(source_metadata::text)+octet_length(manual_overrides::text)+
         octet_length(field_provenance::text)+octet_length(candidates::text) <= 65536),
  check ((review_state='approved' and approved_revision is not null and approved_revision<=revision
          and approved_candidate_id is not null and approved_sha256 is not null and approved_size is not null and approved_sha256 ~ '^[0-9a-f]{64}$'
          and approved_size>0 and approved_by is not null and approved_at is not null)
      or (review_state<>'approved' and approved_revision is null and approved_candidate_id is null
          and approved_sha256 is null and approved_size is null and approved_by is null and approved_at is null))
);
create table public.kb_resource_document_links (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.kb_resource_entries(id),
  document_id uuid not null references public.kb_documents(id),
  content_revision bigint not null check (content_revision>0),
  role text not null default 'primary' check (role='primary'),
  active boolean not null default false,
  publish_state text not null default 'reserved' check (publish_state in ('reserved','published','superseded')),
  approved_revision bigint not null,
  candidate_json jsonb not null,
  metadata_snapshot jsonb not null,
  effective_metadata_revision bigint not null,
  job_id uuid references public.kb_jobs(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique (entry_id,content_revision),
  check (active=(publish_state='published'))
);
create unique index kb_resource_active_primary on public.kb_resource_document_links(entry_id) where active;
create unique index kb_resource_document_owner on public.kb_resource_document_links(document_id) where publish_state<>'superseded';
create unique index kb_resource_reservation on public.kb_resource_document_links(entry_id) where publish_state='reserved';
-- Operational ledger, not a second metadata source. Retain throughout the trial lifecycle.
create table public.kb_resource_requests (
  actor_id uuid not null,
  collection_id uuid not null references public.kb_collections(id),
  operation text not null,
  request_id uuid not null,
  payload_digest text not null,
  result_json jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_id,collection_id,operation,request_id)
);
alter table public.kb_resource_entries enable row level security;
alter table public.kb_resource_document_links enable row level security;
alter table public.kb_resource_requests enable row level security;
revoke all on public.kb_resource_entries,public.kb_resource_document_links,public.kb_resource_requests from public,anon,authenticated,service_role;

create function public.kb_resource_normalize_doi(p_value text) returns text
language sql immutable set search_path=pg_catalog as $$
 select nullif(lower(regexp_replace(btrim(p_value),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i')),'')
$$;
create index kb_resource_doi_match on public.kb_resource_entries
(collection_id,public.kb_resource_normalize_doi((source_metadata||manual_overrides)->>'doi'));

-- Fixed projections only: no dynamic SQL/table names and no writes to existing business tables.
create function public.kb_resource_legacy_metadata(p_ref jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
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

-- The small profile dialect is intentionally not an arbitrary JSON Schema/workflow engine.
create function public.kb_resource_validate_metadata(p_profile jsonb,p_metadata jsonb,p_complete boolean)
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

create function public.kb_resource_command(
  p_actor_id uuid,p_collection_id uuid,p_operation text,p_request_id uuid,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  e public.kb_resource_entries%rowtype;
  l public.kb_resource_document_links%rowtype;
  old_l public.kb_resource_document_links%rowtype;
  d public.kb_documents%rowtype;
  q public.kb_resource_requests%rowtype;
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
  select * into q from public.kb_resource_requests r where r.actor_id=p_actor_id
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
    select * into e from public.kb_resource_entries r where r.id=v_entry_id and r.collection_id=p_collection_id for update;
    if not found then raise exception using errcode='P0002',message='RESOURCE_NOT_FOUND'; end if;
  elsif p_operation='upsert' then
    select * into binding from jsonb_array_elements(profile->'source_bindings') b where b->>'id'=p_payload->>'binding_id';
    if binding is null or nullif(btrim(p_payload->>'external_key'),'') is null then
      raise exception using errcode='22023',message='RESOURCE_SOURCE_REQUIRED';
    end if;
    select * into e from public.kb_resource_entries r where r.collection_id=p_collection_id
      and r.primary_source_binding_id=p_payload->>'binding_id' and r.external_key=p_payload->>'external_key' for update;
    if not found and profile->'matching' ? 'unique_normalized_doi'
      and public.kb_resource_normalize_doi(p_payload->'metadata'->>'doi') is not null then
      select array_agg(r.id) into matching_ids from public.kb_resource_entries r where r.collection_id=p_collection_id
        and public.kb_resource_normalize_doi((r.source_metadata||r.manual_overrides)->>'doi')=
          public.kb_resource_normalize_doi(p_payload->'metadata'->>'doi');
      if cardinality(matching_ids)>1 then raise exception using errcode='40001',message='RESOURCE_MATCH_CONFLICT'; end if;
      if cardinality(matching_ids)=1 then select * into e from public.kb_resource_entries where id=matching_ids[1] for update; end if;
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
    insert into public.kb_resource_entries(collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref)
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
      metadata := public.kb_resource_legacy_metadata(e.legacy_ref);
    else
      if p_payload ? 'legacy_ref' then raise exception using errcode='22023',message='RESOURCE_LEGACY_READ_ONLY'; end if;
      metadata := coalesce(p_payload->'metadata','{}'::jsonb);
      perform public.kb_resource_validate_metadata(profile,metadata,false);
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
    perform public.kb_resource_validate_metadata(profile,before_effective,false);
    e.profile_json:=profile;
    changed:=true; invalidate:=true;
  elsif p_operation='override' then
    metadata := coalesce(p_payload->'fields','{}'::jsonb);
    perform public.kb_resource_validate_metadata(profile,metadata,false);
    e.manual_overrides := e.manual_overrides||metadata;
    for field in select jsonb_array_elements_text(coalesce(p_payload->'release_fields','[]'::jsonb)) loop
      e.manual_overrides := e.manual_overrides-field;
    end loop;
    changed := true;
    e.field_provenance := e.field_provenance||jsonb_build_object('manual',jsonb_build_object(
      'actor_id',p_actor_id,'at',now(),'reason',reason,'request_id',p_request_id));
  else
    if e.metadata_mode='legacy_ref' and public.kb_resource_legacy_metadata(e.legacy_ref)<>e.source_metadata then
      raise exception using errcode='40001',message='RESOURCE_SOURCE_CHANGED';
    end if;
    if p_operation='review' then
      if p_payload->>'decision'='approve' then
        perform public.kb_resource_validate_metadata(profile,before_effective,true);
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
      select * into l from public.kb_resource_document_links x where x.entry_id=e.id
        and x.approved_revision=e.approved_revision and x.publish_state<>'superseded' for update;
      if p_operation='reserve' then
        if l.id is null then
          -- Retire stale reservations; an approval never silently inherits a different snapshot.
          update public.kb_resource_document_links set publish_state='superseded',active=false
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
             or exists(select from public.kb_resource_document_links x where x.document_id=d.id
               and x.publish_state<>'superseded' and x.entry_id<>e.id) then
            raise exception using errcode='40001',message='RESOURCE_DOCUMENT_CONFLICT';
          end if;
          select * into old_l from public.kb_resource_document_links x
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
            update public.kb_resource_document_links set active=false,publish_state='reserved',job_id=null,published_at=null,
              approved_revision=e.approved_revision,candidate_json=c,metadata_snapshot=snapshot,
              effective_metadata_revision=e.approved_revision where id=old_l.id returning * into l;
            else
              insert into public.kb_resource_document_links(entry_id,document_id,content_revision,approved_revision,
                candidate_json,metadata_snapshot,effective_metadata_revision)
              select e.id,d.id,coalesce(max(x.content_revision),0)+1,e.approved_revision,c,snapshot,e.approved_revision
                from public.kb_resource_document_links x where x.entry_id=e.id returning * into l;
            end if;
          else
            -- An unmanaged processed document cannot be adopted by hash alone.
            if d.status not in ('received','raw_stored','failed') or exists(select from public.kb_jobs where kb_jobs.document_id=d.id) then
              raise exception using errcode='40001',message='RESOURCE_DOCUMENT_ALREADY_PROCESSING';
            end if;
            insert into public.kb_resource_document_links(entry_id,document_id,content_revision,approved_revision,
              candidate_json,metadata_snapshot,effective_metadata_revision)
            select e.id,d.id,coalesce(max(x.content_revision),0)+1,e.approved_revision,c,snapshot,e.approved_revision
              from public.kb_resource_document_links x where x.entry_id=e.id returning * into l;
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
          for old_l in select * from public.kb_resource_document_links x where x.entry_id=e.id and x.active for update loop
            update public.kb_jobs set status='cancelled',locked_by=null,locked_until=null,finished_at=now(),last_error='resource content superseded'
              where kb_jobs.document_id=old_l.document_id and stage in ('parse','index','s3_ready') and status in ('queued','running','failed');
            update public.kb_documents set document_version=document_version+1,status='failed',
              opensearch_indexed=false,pinecone_indexed=false,last_error='resource content superseded'
              where id=old_l.document_id and deleted_at is null and status not in ('delete_queued','deleting','deleted');
            update public.kb_resource_document_links set active=false,publish_state='superseded' where id=old_l.id;
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
          update public.kb_resource_document_links set active=true,publish_state='published',job_id=enqueued.job_id,published_at=now()
            where id=l.id returning * into l;
        end if;
      end if;
    end if;
  end if;
  invalidate := invalidate or (e.source_metadata||e.manual_overrides)<>before_effective;
  if invalidate then
    for old_l in select * from public.kb_resource_document_links x where x.entry_id=e.id and x.active for update loop
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
  update public.kb_resource_entries set profile_json=e.profile_json,source_metadata=e.source_metadata,manual_overrides=e.manual_overrides,
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
  insert into public.kb_resource_requests values(p_actor_id,p_collection_id,p_operation,p_request_id,digest,result,now());
  return result;
end $$;

-- Helpers cannot be called by application roles to bypass the command boundary.
revoke all on function public.kb_resource_normalize_doi(text),
  public.kb_resource_legacy_metadata(jsonb),public.kb_resource_validate_metadata(jsonb,jsonb,boolean),
  public.kb_resource_command(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.kb_resource_command(uuid,uuid,text,uuid,jsonb) to service_role;

create function public.kb_resource_get(p_actor_id uuid,p_collection_id uuid,p_entry_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare e public.kb_resource_entries%rowtype; links jsonb; source_stale boolean := false; profile_stale boolean;
begin
  if p_actor_id is null or not public.can_collection_action(p_actor_id,p_collection_id,'read') then
    raise exception using errcode='42501',message='RESOURCE_FORBIDDEN';
  end if;
  select * into e from public.kb_resource_entries where id=p_entry_id and collection_id=p_collection_id;
  if not found then raise exception using errcode='P0002',message='RESOURCE_NOT_FOUND'; end if;
  select metadata_schema_json->'resource_profile' is distinct from e.profile_json into profile_stale
    from public.kb_collections where id=p_collection_id;
  if e.metadata_mode='legacy_ref' then
    begin
      source_stale := public.kb_resource_legacy_metadata(e.legacy_ref)<>e.source_metadata;
    exception when no_data_found then source_stale:=true;
    end;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('document_version',d.document_version,
    'document_status',d.status,'approval_current',e.review_state='approved' and x.approved_revision=e.approved_revision
      and not source_stale and not profile_stale and d.deleted_at is null and x.active) order by x.content_revision),'[]') into links
    from public.kb_resource_document_links x join public.kb_documents d on d.id=x.document_id where x.entry_id=e.id;
  return to_jsonb(e)||jsonb_build_object('effective_metadata',e.source_metadata||e.manual_overrides,
    'source_stale',source_stale,'profile_stale',profile_stale,'links',links);
end $$;
revoke all on function public.kb_resource_get(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.kb_resource_get(uuid,uuid,uuid) to service_role;
