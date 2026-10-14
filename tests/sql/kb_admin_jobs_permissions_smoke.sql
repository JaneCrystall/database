-- Authorization oracle stays in the unchanged single-document helper; this
-- catches drift in the set-based Jobs predicate rather than repeating it.
begin;
insert into kb_collections(id,name,path,content_type)
values (md5('jobs-test-root')::uuid,'Jobs test','/jobs-test','papers'),
       (md5('jobs-test-child')::uuid,'Jobs child','/jobs-test/child','papers'),
       (md5('jobs-test-sibling')::uuid,'Jobs sibling','/jobs-test-other','papers');
insert into kb_groups(id,name,created_by)
values (md5('jobs-test-group')::uuid,'Jobs test group',md5('jobs-test-admin')::uuid);
insert into kb_group_members(group_id,user_id)
values (md5('jobs-test-group')::uuid,md5('jobs-test-restricted')::uuid);
insert into kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,
                         created_by,owner_user_id,visibility,deleted_at)
select md5('jobs-test-d-'||n)::uuid,
       md5(case when n<=4 then 'jobs-test-child' when n<=8 then 'jobs-test-root' else 'jobs-test-sibling' end)::uuid,
       'jobs-test', 'synthetic-'||n||'.pdf', md5(n::text),
       md5(case when n in (9,10) then 'jobs-test-restricted' else 'jobs-test-owner' end)::uuid,
       md5(case when n in (11,12) then 'jobs-test-restricted' else 'jobs-test-owner' end)::uuid,
       case when n in (13,14) then 'public' else 'private' end::kb_document_visibility,
       case when n%2=0 then now() end
from generate_series(1,24) n;
insert into kb_grants(principal_type,principal_id,resource_type,resource_id,actions,created_by,expires_at,revoked_at)
select 'user',md5('jobs-test-admin')::uuid,'collection',id,array['manage']::kb_grant_action[],
       md5('jobs-test-admin')::uuid,null,null from kb_collections where path like '/jobs-test%';
-- Read-only collection + inherited group subtree + document action grants.
insert into kb_grants(principal_type,principal_id,resource_type,resource_id,actions,created_by,expires_at,revoked_at)
values
('group',md5('jobs-test-group')::uuid,'subtree',md5('jobs-test-root')::uuid,array['read']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'collection',md5('jobs-test-child')::uuid,array['read']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-15')::uuid,array['reindex']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-16')::uuid,array['delete']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-17')::uuid,array['manage']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-18')::uuid,array['read']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-19')::uuid,array['manage']::kb_grant_action[],md5('jobs-test-admin')::uuid,now(),null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-20')::uuid,array['manage']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,now()),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-21')::uuid,array['upload','share']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-22')::uuid,array['reindex']::kb_grant_action[],md5('jobs-test-admin')::uuid,null,null),
('user',md5('jobs-test-restricted')::uuid,'document',md5('jobs-test-d-23')::uuid,array['read']::kb_grant_action[],md5('jobs-test-admin')::uuid,now()+interval '1 hour',null);
insert into kb_jobs(id,document_id,document_version,stage,status,locked_by,locked_until,
                    next_retry_at,attempt_count,created_at,updated_at)
select md5('jobs-test-j-'||n)::uuid,md5('jobs-test-d-'||n)::uuid,1,
       (array['parse','index','s3_ready']::kb_job_stage[])[1+n%3],
       (array['queued','running','failed','dead','succeeded']::kb_job_status[])[1+n%5],
       case when n%2=0 then 'jobs-test-worker' end,
       case n%3 when 0 then now()-interval '1 hour' when 1 then now()+interval '1 hour' end,
       case when n%2=0 then now()+interval '1 hour' end,
       n%3,'2026-01-01'::timestamptz+(n%3)*interval '1 day',
       '2026-02-01'::timestamptz+(n%2)*interval '1 day'
from generate_series(1,24) n;

-- Compare membership/count against the original helper for each role/filter.
do $$
declare
  actor uuid; filters jsonb; expected uuid[]; actual uuid[]; total bigint;
  sort_key text; direction text; page uuid[]; wanted uuid[]; order_expr text;
begin
  foreach actor in array array[md5('jobs-test-admin')::uuid,md5('jobs-test-restricted')::uuid,
                               md5('jobs-test-outsider')::uuid,null::uuid] loop
    for filters in select value from jsonb_array_elements(jsonb_build_array(
      '{}'::jsonb,'{"failed_only":true}'::jsonb,'{"stale_running":true}'::jsonb,
      '{"stage":"parse"}'::jsonb,'{"status":"dead"}'::jsonb,
      '{"locked_by":"jobs-test-worker"}'::jsonb,
      jsonb_build_object('document_id',md5('jobs-test-d-16')::uuid),
      '{"failed_only":true,"stage":"index"}'::jsonb,
      '{"failed_only":true,"stale_running":true}'::jsonb,
      '{"status":null}'::jsonb,'{"ignored":true}'::jsonb)) loop
      select coalesce(array_agg(j.id order by j.id),'{}'::uuid[]) into expected
      from kb_jobs j where kb_actor_can_access_admin_document(actor,j.document_id)
        and (not(filters ? 'stage') or j.stage=(filters->>'stage')::kb_job_stage)
        and (not(filters ? 'status') or j.status=(filters->>'status')::kb_job_status)
        and (not(filters ? 'locked_by') or j.locked_by=filters->>'locked_by')
        and (not(filters ? 'document_id') or j.document_id=(filters->>'document_id')::uuid)
        and (not coalesce((filters->>'failed_only')::boolean,false) or j.status in ('failed','dead'))
        and (not coalesce((filters->>'stale_running')::boolean,false) or (j.status='running' and j.locked_until<now()));
      select coalesce(array_agg(id order by id),'{}'::uuid[]),min(total_count) into actual,total
      from list_kb_admin_jobs(actor,filters,100);
      if actual is distinct from expected or (cardinality(actual)>0 and total<>cardinality(expected)) then
        raise exception 'permission/filter mismatch actor=% filters=%',actor,filters;
      end if;
      foreach sort_key in array array['created_at','updated_at','locked_until','next_retry_at','attempt_count','unknown'] loop
        foreach direction in array array['asc','desc'] loop
          order_expr := case when sort_key='unknown' then '' else format('%I %s nulls last,',sort_key,direction) end;
          execute format('select coalesce(array_agg(id),''{}''::uuid[]) from (select id from kb_jobs where id=any($1) order by %s updated_at desc,id limit 3 offset 2) q',order_expr)
          into wanted using expected;
          select coalesce(array_agg(id),'{}'::uuid[]) into page
          from list_kb_admin_jobs(actor,filters,3,2,sort_key,direction);
          if page is distinct from wanted then raise exception 'ordering mismatch %, %, %',actor,sort_key,direction; end if;
        end loop;
      end loop;
    end loop;
  end loop;
  select count(*) into total from list_kb_admin_jobs(md5('jobs-test-admin')::uuid,'{}',100,999);
  if total<>0 then raise exception 'empty page changed'; end if;
  select count(*) into total from list_kb_admin_jobs(md5('jobs-test-admin')::uuid,null,0,-10,null,null);
  if total<>1 then raise exception 'limit/offset/null normalization changed'; end if;
  begin
    perform * from list_kb_admin_jobs(md5('jobs-test-admin')::uuid,'[]');
    raise exception 'non-object filters accepted';
  exception when raise_exception then
    if sqlerrm<>'filters must be a JSON object' then raise; end if;
  end;
  begin
    perform * from list_kb_admin_jobs(md5('jobs-test-admin')::uuid,'{}',25,0,'updated_at','bad');
    raise exception 'bad direction accepted';
  exception when raise_exception then
    if sqlerrm<>'sort direction must be asc or desc' then raise; end if;
  end;
  if has_function_privilege('anon','list_kb_admin_jobs(uuid,jsonb,integer,integer,text,text)','execute')
    or has_function_privilege('authenticated','list_kb_admin_jobs(uuid,jsonb,integer,integer,text,text)','execute')
    or not has_function_privilege('service_role','list_kb_admin_jobs(uuid,jsonb,integer,integer,text,text)','execute') then
    raise exception 'RPC ACL changed';
  end if;
end $$;
-- Exercise the real backend role as well as owner-executed assertions.
set local role service_role;
select count(*) from list_kb_admin_jobs(md5('jobs-test-restricted')::uuid);
reset role;
rollback;
