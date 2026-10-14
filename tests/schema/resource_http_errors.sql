-- Rollback-scoped proof of the transport adapter; no fixture survives this file.
begin;
create temporary table resource_http_error_fixture(
  actor_id uuid,collection_id uuid,request_id uuid,entry_id uuid,payload jsonb,receipt jsonb
);

do $$
declare a uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); req uuid:=gen_random_uuid();
 p jsonb; result jsonb;
begin
 insert into public.kb_collections(id,name,path,metadata_schema_json) values(c,'HTTP errors','http-errors-'||c,
  '{"resource_profile":{"id":"http-errors","version":1,"metadata_mode":"managed","fields":{"title":"string"},"required_fields":["title"],"matching":["unique_source_key"],"source_bindings":[{"id":"catalog","kind":"metadata-snapshot"}]}}');
 insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
  values('collection',c,'user',a,array['manage']::public.kb_grant_action[],a);
 p:=jsonb_build_object('binding_id','catalog','external_key','original','expected_revision',0,
                      'reason','transport qualification','metadata',jsonb_build_object('title','Synthetic'));
 -- Verify the real gateway role retains both SQL and HTTP entrypoint access.
 set local role service_role;
 result:=private.kb_resource_command(a,c,'upsert',req,p);
 if api.kb_resource_command(a,c,'upsert',req,p) is distinct from result then
  raise exception 'transport changed successful receipt';
 end if;
 reset role;
 insert into resource_http_error_fixture values(a,c,req,(result->>'entry_id')::uuid,p,result);
end $$;

do $$
declare f resource_http_error_fixture%rowtype; conflict jsonb; before_entry jsonb; code text; message text;
begin
 select * into f from resource_http_error_fixture;
 select to_jsonb(e) into before_entry from private.kb_resource_entries e where id=f.entry_id;
 conflict:=f.payload||jsonb_build_object('reason','different input under the same request');
 set local role service_role;
 begin
  perform private.kb_resource_command(f.actor_id,f.collection_id,'upsert',f.request_id,conflict);
  raise exception 'private conflict unexpectedly succeeded';
 exception when serialization_failure then
  get stacked diagnostics code=returned_sqlstate,message=message_text;
  if code<>'40001' or message<>'RESOURCE_REQUEST_CONFLICT' then raise; end if;
 end;
 begin
  perform api.kb_resource_command(f.actor_id,f.collection_id,'upsert',f.request_id,conflict);
  raise exception 'API conflict unexpectedly succeeded';
 exception when sqlstate 'PT409' then
  if sqlerrm<>'RESOURCE_REQUEST_CONFLICT' then raise; end if;
 end;
 begin
  perform api.kb_resource_command(f.actor_id,f.collection_id,'override',gen_random_uuid(),
   jsonb_build_object('entry_id',f.entry_id,'expected_revision',999,'reason','stale revision',
                      'fields',jsonb_build_object('title','Must not be applied')));
  raise exception 'API stale revision unexpectedly succeeded';
 exception when sqlstate 'PT409' then
  if sqlerrm<>'RESOURCE_REVISION_CONFLICT' then raise; end if;
 end;
 reset role;
 if before_entry is distinct from (select to_jsonb(e) from private.kb_resource_entries e where id=f.entry_id)
  or (select count(*) from private.kb_resource_requests where collection_id=f.collection_id)<>1 then
  raise exception 'transport conflict changed resource state or receipts';
 end if;
end $$;

-- A synthetic genuine serialization failure from an insert trigger must retain
-- its SQLSTATE/message through the invoker adapter. Match the fixture collection
-- only, and roll back both the trigger and helper function below.
create function pg_temp.resource_plain_serialization_failure() returns trigger
language plpgsql as $$
begin
 raise exception using errcode='40001',message='could not serialize access due to synthetic concurrent update';
end $$;
do $$
declare f resource_http_error_fixture%rowtype;
begin
 select * into f from resource_http_error_fixture;
 execute format('create trigger resource_http_error_test before insert on private.kb_resource_entries
  for each row when (new.collection_id=%L::uuid) execute function pg_temp.resource_plain_serialization_failure()',f.collection_id);
end $$;
do $$
declare f resource_http_error_fixture%rowtype; code text; message text;
begin
 select * into f from resource_http_error_fixture;
 set local role service_role;
 begin
  perform api.kb_resource_command(f.actor_id,f.collection_id,'upsert',gen_random_uuid(),
   f.payload||jsonb_build_object('external_key','unexpected-serialization'));
  raise exception 'unexpected serialization failure was swallowed';
 exception when serialization_failure then
  get stacked diagnostics code=returned_sqlstate,message=message_text;
  if code<>'40001' or message<>'could not serialize access due to synthetic concurrent update' then raise; end if;
 end;
 reset role;
 if (select count(*) from private.kb_resource_entries where collection_id=f.collection_id)<>1
  or (select count(*) from private.kb_resource_requests where collection_id=f.collection_id)<>1 then
  raise exception 'unexpected serialization failure committed partial effects';
 end if;
end $$;
rollback;
