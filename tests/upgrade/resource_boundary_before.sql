-- Real pre-boundary resource rows, with human override, approval, published and
-- reserved links and request receipts. Gate-only, no physical PDF is claimed.
create table m1_upgrade_proof.resource_state(key text primary key, value jsonb);
do $$
declare a uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); req uuid:=gen_random_uuid();
 r jsonb; candidate uuid; payload jsonb; relative text; n integer; t text;
begin
 insert into public.kb_collections(id,name,path,metadata_schema_json) values(c,'Schema upgrade','schema-upgrade',
 '{"resource_profile":{"id":"schema-upgrade","version":1,"metadata_mode":"managed","fields":{"title":"string"},"required_fields":["title"],"matching":["unique_source_key"],"source_bindings":[{"id":"catalog","kind":"metadata-snapshot"},{"id":"drop","kind":"file-snapshot","source_root_ref":"synthetic/upgrade"}]}}');
 insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection',c,'user',a,array['manage']::public.kb_grant_action[],a);
 for n in 1..2 loop
  payload:=jsonb_build_object('binding_id','catalog','external_key','upgrade-'||n,'expected_revision',0,'reason','schema upgrade','metadata',jsonb_build_object('title','Source title'));
  r:=public.kb_resource_command(a,c,'upsert',req,payload);
  if n=1 then
   insert into m1_upgrade_proof.resource_state values('replay',jsonb_build_object('actor',a,'collection',c,'request',req,'payload',payload,'receipt',r));
  end if;
  r:=public.kb_resource_command(a,c,'override',gen_random_uuid(),jsonb_build_object('entry_id',r->'entry_id','expected_revision',r->'revision','reason','Human correction','fields',jsonb_build_object('title','Reviewed title')));
  candidate:=gen_random_uuid();
  r:=public.kb_resource_command(a,c,'attach',gen_random_uuid(),jsonb_build_object('entry_id',r->'entry_id','expected_revision',r->'revision','reason','schema upgrade','candidate',jsonb_build_object('candidate_id',candidate,'binding_id','drop','relative_locator','test.pdf','sha256',repeat(n::text,64),'size',811,'stable',true,'pdf_valid',true)));
  r:=public.kb_resource_command(a,c,'review',gen_random_uuid(),jsonb_build_object('entry_id',r->'entry_id','expected_revision',r->'revision','reason','schema upgrade','decision','approve','candidate_id',candidate));
  r:=public.kb_resource_command(a,c,'reserve',gen_random_uuid(),jsonb_build_object('entry_id',r->'entry_id','expected_revision',r->'revision','reason','schema upgrade','approved_revision',r->'approved_revision'));
  if n=1 then
   relative:='schema-upgrade/'||(r->>'document_id')||'.pdf';
   r:=public.kb_resource_command(a,c,'publish',gen_random_uuid(),jsonb_build_object('entry_id',r->'entry_id','expected_revision',r->'revision','reason','schema upgrade','approved_revision',r->'approved_revision','document_id',r->'document_id','sha256',r->'approved_sha256','size',r->'approved_size','copy_verified',true,'raw_relative_path',relative,'raw_uri','nas://raw/'||relative));
   insert into m1_upgrade_proof.resource_state values('getter',public.kb_resource_get(a,c,(r->>'entry_id')::uuid));
  end if;
  req:=gen_random_uuid();
 end loop;
 foreach t in array array['kb_resource_entries','kb_resource_document_links','kb_resource_requests','kb_documents','kb_jobs','kb_audit_events'] loop
  execute format('insert into m1_upgrade_proof.resource_state values (%L,(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from public.%I x))',t,t);
 end loop;
 foreach t in array array['kb_resource_entries','kb_resource_document_links','kb_resource_requests'] loop
  insert into m1_upgrade_proof.resource_state values('oid:'||t,to_jsonb(('public.'||t)::regclass::oid));
 end loop;
 foreach t in array array['kb_resource_command(uuid,uuid,text,uuid,jsonb)','kb_resource_get(uuid,uuid,uuid)','kb_resource_normalize_doi(text)','kb_resource_legacy_metadata(jsonb)','kb_resource_validate_metadata(jsonb,jsonb,boolean)'] loop
  insert into m1_upgrade_proof.resource_state values('function_oid:'||t,to_jsonb(('public.'||t)::regprocedure::oid));
 end loop;
end $$;
