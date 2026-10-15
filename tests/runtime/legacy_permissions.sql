-- S9 effective privileges and actual execution, including PUBLIC inheritance.
begin;
create role s9_untrusted nologin;
grant s9_untrusted to postgres with set true;
grant usage on schema public to s9_untrusted;
create temp table s9_functions(signature text, invocation text);
insert into s9_functions values ('public.authorize_kb_api_key_collection_action(text, text, text[], jsonb, text, jsonb)', 'select public.authorize_kb_api_key_collection_action(NULL::text, NULL::text, NULL::text[], NULL::jsonb, NULL::text, NULL::jsonb)');
insert into s9_functions values ('public.claim_parse_two_stage_task(text, integer)', 'select public.claim_parse_two_stage_task(NULL::text, NULL::integer)');
insert into s9_functions values ('public.fail_job_v2(uuid, text, boolean, text, kb_job_stage)', 'select public.fail_job_v2(NULL::uuid, NULL::text, NULL::boolean, NULL::text, NULL::kb_job_stage)');
insert into s9_functions values ('public.has_service_role(uuid)', 'select public.has_service_role(NULL::uuid)');
insert into s9_functions values ('public.kb_default_collection_search_partition()', 'select public.kb_default_collection_search_partition()');
insert into s9_functions values ('public.kb_normalize_collection_path(text)', 'select public.kb_normalize_collection_path(NULL::text)');
insert into s9_functions values ('public.kb_set_updated_at()', 'select public.kb_set_updated_at()');
insert into s9_functions values ('public.mark_parse_local_ready(uuid, text, uuid, integer, text, uuid, text, integer, jsonb)', 'select public.mark_parse_local_ready(NULL::uuid, NULL::text, NULL::uuid, NULL::integer, NULL::text, NULL::uuid, NULL::text, NULL::integer, NULL::jsonb)');
insert into s9_functions values ('public.mark_parse_two_stage_task_state(uuid, text, text, text, integer)', 'select public.mark_parse_two_stage_task_state(NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::integer)');
insert into s9_functions values ('public.mark_processed_s3_ready(uuid, text, uuid, integer, text, text, uuid, text, integer)', 'select public.mark_processed_s3_ready(NULL::uuid, NULL::text, NULL::uuid, NULL::integer, NULL::text, NULL::text, NULL::uuid, NULL::text, NULL::integer)');
insert into s9_functions values ('public.register_parse_two_stage_task(uuid, text, text, text, text, text, bigint, integer, jsonb)', 'select public.register_parse_two_stage_task(NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::bigint, NULL::integer, NULL::jsonb)');
insert into s9_functions values ('public.replay_parse_local_ready_from_artifact(uuid, text, uuid, integer, text, uuid, text, integer, jsonb, jsonb, text)', 'select public.replay_parse_local_ready_from_artifact(NULL::uuid, NULL::text, NULL::uuid, NULL::integer, NULL::text, NULL::uuid, NULL::text, NULL::integer, NULL::jsonb, NULL::jsonb, NULL::text)');
insert into s9_functions values ('public.resolve_document_search_partition(uuid)', 'select public.resolve_document_search_partition(NULL::uuid)');
insert into s9_functions values ('public.resolve_query_search_partitions(uuid[], boolean, boolean)', 'select public.resolve_query_search_partitions(NULL::uuid[], NULL::boolean, NULL::boolean)');
insert into s9_functions values ('public.set_created_by()', 'select public.set_created_by()');
insert into s9_functions values ('public.set_last_updated_by()', 'select public.set_last_updated_by()');
insert into s9_functions values ('public.set_last_updated_time()', 'select public.set_last_updated_time()');
insert into s9_functions values ('public.verify_kb_api_key(text, text, text[], jsonb)', 'select public.verify_kb_api_key(NULL::text, NULL::text, NULL::text[], NULL::jsonb)');
do $$
declare f record; r text;
begin
 for f in select * from s9_functions loop
  foreach r in array array['anon','authenticated','s9_untrusted'] loop
   if has_function_privilege(r,f.signature,'EXECUTE') then
    raise exception 'S9 unexpected effective EXECUTE: % %', r, f.signature;
   end if;
   execute format('set local role %I',r);
   begin
    execute f.invocation;
    raise exception 'S9 invocation unexpectedly allowed: % %',r,f.signature;
   exception when insufficient_privilege then null;
   end;
   reset role;
  end loop;
  if not has_function_privilege('service_role',f.signature,'EXECUTE') then
   raise exception 'S9 service contract lost: %',f.signature;
  end if;
 end loop;
end $$;
do $$
declare t text; r text; p text;
begin
 foreach t in array array['edu_meta','edu_textbooks','esg_category','esg_country','esg_meta','green_deal_meta','internal_use','journals','journals_issn','kb_api_keys','kb_audit_events','kb_collections','kb_documents','kb_grants','kb_group_members','kb_groups','kb_index_records','kb_jobs','kb_query_logs','kb_schema_migrations','kb_search_partitions','reports','standards','user_roles'] loop
  foreach r in array array['anon','authenticated','s9_untrusted'] loop
   foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] loop
    if has_table_privilege(r,'public.'||t,p) then
     raise exception 'S9 unexpected table privilege: % % %',r,t,p;
    end if;
   end loop;
  end loop;
 end loop;
end $$;
-- RLS does not protect TRUNCATE; test the statement, with automatic rollback.
set local role anon;
do $$ begin
 begin truncate public.edu_meta;
 raise exception 'S9 anonymous TRUNCATE was allowed';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
-- A dedicated worker role needs explicit grants; PUBLIC is never its credential.
create role s9_worker nologin noinherit nobypassrls;
grant s9_worker to postgres with set true;
grant usage on schema public to s9_worker;
grant execute on function public.claim_parse_two_stage_task(text,integer) to s9_worker;
set local role s9_worker;
select * from public.claim_parse_two_stage_task('s9-custom-worker',1);
do $$ begin
 begin perform count(*) from public.kb_jobs;
 raise exception 'custom worker can read jobs directly';
 exception when insufficient_privilege then null;
 end;
 begin perform public.has_service_role(gen_random_uuid());
 raise exception 'custom worker inherited unrelated function';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
rollback;
