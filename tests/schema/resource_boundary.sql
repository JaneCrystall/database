-- Exact new capability boundary; legacy public catalog is checked separately.
do $$
declare r text; t text; f text; obj oid; is_definer boolean;
begin
 foreach t in array array['kb_resource_entries','kb_resource_document_links','kb_resource_requests'] loop
  if to_regclass('public.'||t) is not null then raise exception 'old public table remains: %',t; end if;
  obj:=to_regclass('private.'||t);
  if obj is null or not (select relrowsecurity from pg_class where oid=obj)
   or exists(select from pg_policy where polrelid=obj) then raise exception 'private table RLS drift: %',t; end if;
  foreach r in array array['anon','authenticated','service_role'] loop
   if has_table_privilege(r,obj,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'direct table grant: % %',r,t;
   end if;
  end loop;
 end loop;
 foreach r in array array['anon','authenticated','service_role'] loop
  if has_schema_privilege(r,'private','CREATE') or has_schema_privilege(r,'api','CREATE') then raise exception 'schema CREATE grant: %',r; end if;
  if r<>'service_role' and (has_schema_privilege(r,'private','USAGE') or has_schema_privilege(r,'api','USAGE')) then raise exception 'untrusted schema usage: %',r; end if;
 end loop;
 if (select count(*) from pg_proc where pronamespace='api'::regnamespace)<>2
 or exists(select from pg_class where relnamespace='api'::regnamespace and relkind in ('r','v','m','p')) then raise exception 'api must contain exactly two functions and no tables/views'; end if;
 if exists(select from pg_proc where pronamespace='public'::regnamespace and proname like 'kb_resource_%') then raise exception 'old public resource function remains'; end if;
 foreach f in array array['kb_resource_command(uuid,uuid,text,uuid,jsonb)','kb_resource_get(uuid,uuid,uuid)'] loop
  foreach r in array array['anon','authenticated','service_role'] loop
   if has_function_privilege(r,('api.'||f)::regprocedure,'EXECUTE') is distinct from (r='service_role')
   or has_function_privilege(r,('private.'||f)::regprocedure,'EXECUTE') is distinct from (r='service_role') then raise exception 'entrypoint ACL drift: % %',r,f; end if;
  end loop;
  if (select prosecdef from pg_proc where oid=('api.'||f)::regprocedure)
   or not (select prosecdef from pg_proc where oid=('private.'||f)::regprocedure) then raise exception 'elevation must live in private: %',f; end if;
 end loop;
 foreach f in array array['kb_resource_normalize_doi(text)','kb_resource_legacy_metadata(jsonb)','kb_resource_validate_metadata(jsonb,jsonb,boolean)'] loop
  foreach r in array array['anon','authenticated','service_role'] loop
   if has_function_privilege(r,('private.'||f)::regprocedure,'EXECUTE') then raise exception 'helper ACL drift: % %',r,f; end if;
  end loop;
 end loop;
 if exists(select from pg_proc where pronamespace in ('private'::regnamespace,'api'::regnamespace)
  and proconfig is distinct from array['search_path=pg_catalog']) then raise exception 'unsafe resource search path'; end if;
end $$;
