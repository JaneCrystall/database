"""Qualify the only changed object from the previous schema on the owned stack.

Called by test-database.sh after a fresh local replay; never accepts a DB URL.
All other catalog objects are unchanged by this migration. Restore the imported
RPC body, exercise compatibility, then apply the forward migration again.
"""
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
container = sys.argv[2]
if not container.startswith('supabase_db_tiangong-ai-database-test-'):
    raise SystemExit('Expected the disposable qualification stack')


def sql(source):
    return subprocess.run(
        ['docker', 'exec', '-i', container, 'psql', '-X', '-At',
         '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres'],
        input=source, text=True, check=True, capture_output=True,
    ).stdout


old = (repo / 'supabase/migrations/202605110001_kb_job_retry_backoff_dlq.sql').read_text()
start = old.index('create or replace function public.list_kb_admin_jobs(')
old = old[start:old.index('\ndo $$', start)]
migration = (repo / 'supabase/migrations/20261013091317_optimize_kb_admin_jobs_authorization.sql').read_text()
contract = """select jsonb_build_object(
    'oid',oid, 'owner',proowner,'acl',proacl,'args',pg_get_function_arguments(oid),
    'returns',pg_get_function_result(oid),'security_definer',prosecdef,
    'volatility',provolatile,'config',proconfig)::text from pg_proc
    where oid='public.list_kb_admin_jobs(uuid,jsonb,integer,integer,text,text)'::regprocedure;
"""
try:
    sql(old)
    before = sql(contract)
    sql((repo / 'tests/sql/kb_admin_jobs_permissions_smoke.sql').read_text())
    sql(migration)
    if before != sql(contract):
        raise SystemExit('Jobs upgrade changed identity, ACL, signature or execution attributes')
    print('Jobs prior-schema-to-head upgrade: identity/ACL/signature preserved; old role/filter/sort oracle passed')
except subprocess.CalledProcessError as exc:
    # This path is strictly local synthetic SQL, containing no connection secrets.
    print(exc.stderr, file=sys.stderr)
    raise SystemExit('Jobs upgrade qualification failed') from None
