-- Catalog metadata only. Never selects application/auth rows or role secrets.
WITH target_tables(name, schema_name) AS (
 SELECT c.relname, n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','private','api') AND c.relkind IN ('r','p','v','m')
), relations AS (
  SELECT c.*, n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN target_tables t ON t.name=c.relname AND t.schema_name=n.nspname
), target_functions(name, schema_name) AS (
 SELECT DISTINCT p.proname, n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('public','private','api') AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')
)
SELECT jsonb_build_object(
  'relations', (SELECT jsonb_agg(jsonb_build_object(
    'owner',pg_get_userbyid(r.relowner),'name',CASE WHEN r.nspname='public' THEN r.relname ELSE r.nspname||'.'||r.relname END,'kind',r.relkind,'rls',r.relrowsecurity,'force_rls',r.relforcerowsecurity,
    'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
      'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
      'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
      FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
      WHERE a.attrelid=r.oid AND a.attnum>0 AND NOT a.attisdropped),
    'constraints',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',c.conname,'type',c.contype,
      'definition',pg_get_constraintdef(c.oid,true),'validated',c.convalidated) ORDER BY c.conname),'[]'::jsonb)
      FROM pg_constraint c WHERE c.conrelid=r.oid),
    'indexes',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',i.indexname,'definition',i.indexdef) ORDER BY i.indexname),'[]'::jsonb)
      FROM pg_indexes i WHERE i.schemaname=r.nspname AND i.tablename=r.relname),
    'triggers',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled,
      'definition',pg_get_triggerdef(t.oid,true)) ORDER BY t.tgname),'[]'::jsonb)
      FROM pg_trigger t WHERE t.tgrelid=r.oid AND NOT t.tgisinternal),
    'policies',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',p.policyname,'permissive',p.permissive,
      'roles',p.roles,'command',p.cmd,'using',p.qual,'check',p.with_check) ORDER BY p.policyname),'[]'::jsonb)
      FROM pg_policies p WHERE p.schemaname=r.nspname AND p.tablename=r.relname),
    'acl',(SELECT coalesce(jsonb_agg(jsonb_build_object('grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
      'privilege',x.privilege_type,'grantable',x.is_grantable) ORDER BY x.grantee=0,pg_get_userbyid(x.grantee),x.privilege_type),'[]'::jsonb)
      FROM aclexplode(coalesce(r.relacl,acldefault('r',r.relowner))) x)
  ) ORDER BY r.relname) FROM relations r),
  'functions',(SELECT jsonb_agg(jsonb_build_object('name',CASE WHEN n.nspname='public' THEN p.proname ELSE n.nspname||'.'||p.proname END,
    'arguments',pg_get_function_identity_arguments(p.oid),'full_arguments',pg_get_function_arguments(p.oid),'owner',pg_get_userbyid(p.proowner),'leakproof',p.proleakproof,'cost',p.procost,'rows',p.prorows,'returns',pg_get_function_result(p.oid),
    'body_md5',md5(p.prosrc),'language',l.lanname,'security_definer',p.prosecdef,
    'volatility',p.provolatile,'strict',p.proisstrict,'parallel',p.proparallel,'configuration',p.proconfig,
    'acl',(SELECT jsonb_agg(jsonb_build_object('grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END,
      'privilege',x.privilege_type,'grantable',x.is_grantable) ORDER BY x.grantee=0,pg_get_userbyid(x.grantee),x.privilege_type)
      FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x)
    ) ORDER BY p.proname,pg_get_function_identity_arguments(p.oid))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang
    JOIN target_functions f ON f.name=p.proname AND f.schema_name=n.nspname),
  'enums',(SELECT jsonb_agg(x ORDER BY x->>'name') FROM (SELECT jsonb_build_object('name',t.typname,'labels',jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)) AS x FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace JOIN pg_enum e ON e.enumtypid=t.oid WHERE n.nspname='public' GROUP BY t.typname) types),
  'lang',(SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e
    WHERE e.enumtypid='public.lang'::regtype)
);
