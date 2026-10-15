#!/usr/bin/env python3
"""Local-only real LOGIN qualification; RPC access is not whole-worker readiness."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import traceback
from urllib.parse import urlsplit
import uuid

from runtime import RuntimeErrorSafe, command, load_private, local_docker, validate_target

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = Path(__file__).with_name('worker_role_contract.json')


def query(conn, statement, args=()):
    with conn.cursor() as cur:
        cur.execute(statement, args)
        rows = cur.fetchall() if cur.description else []
    conn.commit()
    return rows


def denied(conn, operation):
    try:
        operation()
    except psycopg2.Error as exc:
        conn.rollback()
        assert exc.pgcode == '42501', f'Expected 42501, got SQLSTATE {exc.pgcode}'
    else:
        raise AssertionError('Expected permission denial')


def local_target(path):
    target = load_private(path)
    validate_target(target)
    if target['mode'] != 'local':
        raise RuntimeErrorSafe('Only an owned disposable local stack is allowed')
    local_docker()
    state = load_private(Path(target['session_dir']) / 'session.json')
    for key in ('run_id', 'project_id', 'session_dir'):
        if state.get(key) != target.get(key):
            raise RuntimeErrorSafe('Session ownership mismatch')
    if state.get('owns_stack') is not True or state.get('stopped'):
        raise RuntimeErrorSafe('Inactive session')
    container = 'supabase_db_' + target['project_id']
    info = json.loads(command(['docker', 'inspect', container]))[0]
    labels = info['Config']['Labels']
    if labels.get('com.supabase.cli.project') != target['project_id'] or labels.get('com.supabase.cli.workdir') != target['session_dir']:
        raise RuntimeErrorSafe('Container ownership mismatch')
    ports = info['NetworkSettings']['Ports']['5432/tcp']
    if str(urlsplit(target['db_url']).port) not in {p['HostPort'] for p in ports}:
        raise RuntimeErrorSafe('Database port does not belong to owned container')
    return target


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


def run(target_path):
    target = local_target(target_path)
    global psycopg2
    import psycopg2
    from psycopg2 import sql as pgsql
    from psycopg2.extensions import make_dsn
    contract = json.loads(CONTRACT.read_text())
    sources = {name: ROOT.parent / 'unstructure/src/kb_parse_worker' / f'{name}.py'
               for name in ('control_plane', 'queue', 'snapshot')}
    cp, queue, snapshot = [module(f's9_{name}', path) for name, path in sources.items()]
    owner = cp.connect(target['db_url'])
    role = 's9_rpc_' + uuid.uuid4().hex[:16]
    role_created = False
    worker = None
    cid, actor = str(uuid.uuid4()), str(uuid.uuid4())
    wid = 'synthetic-worker'
    def fixture(status='running'):
        doc, job = str(uuid.uuid4()), str(uuid.uuid4())
        query(owner, "insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,sha256,created_by,owner_user_id,status,raw_uri) values(%s,%s,%s,'s9-role.pdf','pdf',%s,%s,%s,'parse_queued','nas://synthetic/role.pdf')", (doc,cid,doc,'a'*64,actor,actor))
        query(owner, "insert into public.kb_jobs(id,document_id,document_version,stage,status,locked_by,locked_until) values(%s,%s,1,'parse',%s::public.kb_job_status,%s,now()+interval '5 minutes')", (job,doc,status,wid))
        return doc,job
    def grant(signatures):
        for signature in signatures:  # Exact reviewed signatures, never user SQL.
            query(owner, pgsql.SQL('grant execute on function {} to {}').format(pgsql.SQL(signature), pgsql.Identifier(role)))
    def denied_signature(signature):
        name, args = signature[:-1].split('(',1)
        nulls = ','.join('NULL::'+t.strip() for t in args.split(',')) if args else ''
        denied(worker, lambda: query(worker, f'select * from {name}({nulls})'))
    def unchanged(job, operation):
        before = query(owner, 'select to_jsonb(j) from public.kb_jobs j where id=%s', (job,))
        denied(worker, operation)
        assert query(owner, 'select to_jsonb(j) from public.kb_jobs j where id=%s', (job,)) == before
    try:
        query(owner, "insert into public.kb_collections(id,name,path) values(%s,'S9 role boundary',%s)", (cid,'/s9-role/'+cid))
        password = secrets.token_urlsafe(32)
        query(owner, pgsql.SQL('create role {} login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls password {}').format(pgsql.Identifier(role), pgsql.Literal(password)))
        role_created = True
        query(owner, pgsql.SQL('grant usage on schema public to {}').format(pgsql.Identifier(role)))
        worker = cp.connect(make_dsn(target['db_url'], user=role, password=password, connect_timeout=5, application_name='s9-local-rpc-role'))
        assert query(worker, 'select session_user, current_user')[0] == (role,role)
        flags = query(owner, 'select rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreaterole,rolcreatedb from pg_roles where rolname=%s',(role,))[0]
        assert flags == (True,False,False,False,False,False)
        assert query(owner, 'select count(*) from pg_auth_members where member=(select oid from pg_roles where rolname=%s)',(role,))[0][0] == 0
        for signature in contract['s9_rpc']:
            denied_signature(signature)
        grant(contract['s9_rpc'])
        # All other newly restricted functions and support RPCs still deny.
        policy = json.loads((ROOT/'tests/schema/legacy_acl_policy.json').read_text())
        catalog = json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())
        triggers = {f['name'] for f in catalog['functions'] if f['returns'] == 'trigger'}
        for signature in policy['restricted_functions'] + contract['support_rpc']:
            allowed = signature in contract['s9_rpc']
            assert query(owner, 'select has_function_privilege(%s,%s,\'EXECUTE\')',(role,signature))[0][0] == allowed
            if not allowed and signature.split('.')[1].split('(')[0] not in triggers:
                denied_signature(signature)
        # Actual seven adapters, with lease/owner rejection and server-side effects.
        doc,job = fixture()
        msg = query(owner,"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0][0]
        assert cp.register_parse_two_stage_task(worker,job,wid,'s9-role-task','http://synthetic.invalid/task','http://synthetic.invalid/status','kb_parse_queue',msg,300,{}).job_id == job
        assert cp.claim_parse_two_stage_task(worker,wid,300).job_id == job
        assert not cp.mark_parse_two_stage_task_state(worker,job,'wrong-worker','STARTED',None,300)
        assert cp.mark_parse_two_stage_task_state(worker,job,wid,'STARTED',None,300)
        artifact = str(uuid.uuid4())
        assert not cp.mark_parse_local_ready(worker,job,'wrong-worker',doc,1,'nas://synthetic/role',artifact,'b'*64,1,{})
        assert cp.mark_parse_local_ready(worker,job,wid,doc,1,'nas://synthetic/role',artifact,'b'*64,1,{})
        assert cp.mark_processed_s3_ready(worker,job,wid,doc,1,'synthetic/role','b'*64,artifact,'nas://synthetic/role',1)
        assert query(owner,'select status::text from public.kb_jobs where id=%s',(job,))[0][0] == 'succeeded'
        doc,job = fixture()
        assert cp.fail_job(worker,job,wid,False,'synthetic').job_status == 'dead'
        replay_args = (worker,job,'synthetic-repair',doc,1,'nas://synthetic/replay',str(uuid.uuid4()),'c'*64,1,{}, {},'S9 qualification')
        replay = cp.replay_parse_local_ready_from_artifact(*replay_args)
        assert replay.parse_job_status == 'succeeded'
        assert cp.replay_parse_local_ready_from_artifact(*replay_args).s3_ready_job_id == replay.s3_ready_job_id
        # Seven grants do NOT authorize queue, snapshot, support RPCs or writes.
        doc,job = fixture()
        unchanged(job, lambda: cp.heartbeat_job(worker,job,wid,300))
        denied(worker, lambda: queue.read_one(worker,'kb_parse_queue',30))
        denied(worker, lambda: snapshot.load_job_snapshot(worker,job,'parse'))
        for table in json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())['relations']:
            for permission in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'):
                assert not query(owner,'select has_table_privilege(%s,%s,%s)',(role,'public.'+table['name'],permission))[0][0]
        unchanged(job, lambda: query(worker,"update public.kb_jobs set locked_by='forged' where id=%s",(job,)))
        denied(worker, lambda: query(worker,'truncate public.edu_meta'))
        denied(worker, lambda: query(worker,'set role service_role'))
        # Add only the six extra public RPC grants; no table/RLS/pgmq grants.
        grant(contract['support_rpc'])
        doc,job = fixture('queued')
        msg = query(owner,"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0][0]
        assert cp.claim_job(worker,job,'kb_parse_queue',msg,wid,300).claimed
        assert not cp.heartbeat_job(worker,job,'wrong-worker',300)
        assert cp.heartbeat_job(worker,job,wid,300)
        assert not queue.archive_job_message(worker,job,wid)
        artifact = str(uuid.uuid4())
        result = cp.complete_parse_local_ready_and_enqueue_s3_check(worker,job,wid,doc,1,'nas://synthetic/support',artifact,'d'*64,1,{}, {})
        assert result.parse_job_status == 'succeeded'
        assert cp.claim_job(worker,result.s3_ready_job_id,'kb_s3_ready_queue',result.s3_ready_msg_id,wid,300).claimed
        assert cp.complete_s3_ready_check(worker,result.s3_ready_job_id,wid,doc,1,'synthetic/support','d'*64,artifact,'nas://synthetic/support',1)
        assert query(owner,'select status::text from public.kb_jobs where id=%s',(result.s3_ready_job_id,))[0][0] == 'succeeded'
        msg = query(owner,"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0][0]
        assert queue.archive_job_message_by_id(worker,'kb_parse_queue',msg)
        doc,job = fixture('succeeded')
        msg = query(owner,"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0][0]
        query(owner,"update public.kb_jobs set pgmq_queue='kb_parse_queue', pgmq_msg_id=%s where id=%s",(msg,job))
        assert queue.archive_job_message(worker,job,wid)
        # Extra RPCs do not solve direct reads; contrast real privileged adapters.
        doc,job = fixture()
        denied(worker, lambda: snapshot.load_job_snapshot(worker,job,'parse'))
        denied(worker, lambda: queue.read_one(worker,'kb_parse_queue',30))
        query(owner,'set role service_role')
        assert snapshot.load_job_snapshot(owner,job,'parse').job_id == job
        # BYPASSRLS does not bypass schema/object privileges: this local chain
        # does not grant service_role USAGE on pgmq. Preserve the finding.
        denied(owner, lambda: queue.read_one(owner,'kb_s3_ready_queue',30))
        query(owner,'reset role')
        queue_facts = query(owner, "select p.oid::regprocedure::text,p.prosecdef,has_function_privilege('service_role',p.oid,'EXECUTE') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgmq' and p.proname='read'")
        query(owner,pgsql.SQL('grant usage on schema pgmq to {}').format(pgsql.Identifier(role)))
        for signature, _, _ in queue_facts:
            query(owner,pgsql.SQL('grant execute on function {} to {}').format(pgsql.SQL(signature),pgsql.Identifier(role)))
        # The invoker queue function still needs privileges on its selected queue.
        denied(worker, lambda: queue.read_one(worker,'kb_parse_queue',30))
        for table in ('q_kb_parse_queue','q_kb_s3_ready_queue'):
            query(owner,pgsql.SQL('grant select, update on pgmq.{} to {}').format(pgsql.Identifier(table),pgsql.Identifier(role)))
        msg = query(owner,"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0][0]
        assert query(owner,'select count(*) from pgmq.q_kb_parse_queue where msg_id=%s',(msg,))[0][0] == 1
        assert queue.read_one(worker,'kb_parse_queue',30) is None
        denied(worker, lambda: queue.read_one(worker,'kb_index_queue',30))
        # SELECT alone does not make a custom worker visible to existing RLS.
        for table in contract['direct_read_tables']:
            query(owner,pgsql.SQL('grant select on public.{} to {}').format(pgsql.Identifier(table),pgsql.Identifier(role)))
        assert query(worker,'select count(*) from public.kb_jobs')[0][0] == 0
        try:
            snapshot.load_job_snapshot(worker,job,'parse')
        except RuntimeError:
            worker.rollback()
        else:
            raise AssertionError('Custom role must not gain snapshot visibility from SELECT alone')
        return {'mode':'local','run_id':target['run_id'],'passed':True,
                'identity':'fresh LOGIN, session_user=current_user, no memberships, NOINHERIT/NOBYPASSRLS/nonowner',
                's9_adapters_passed':7,'support_adapters_passed':6,
                'denied':['ungranted RPCs','24-table writes','TRUNCATE','SET ROLE service_role','pgmq.read','snapshot'],
                'service_role_snapshot':'passed',
                'service_role_queue':'42501: schema pgmq (local reconstructed chain)',
                'queue_profile':'schema+function+queue SELECT/UPDATE: no rows under RLS despite queued fixture; index queue denied',
                'queue_functions':queue_facts,
                'direct_select_profile':'three table SELECT grants: zero jobs visible under existing RLS',
                'whole_worker_qualified':False,'production_role_verified':False,
                'contract_sha256':hashlib.sha256(CONTRACT.read_bytes()).hexdigest(),
                'harness_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'source_sha256':{str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources.values()},
                'cleanup':'login/grants removed; fixture rows removed by owned stack stop'}
    finally:
        if worker is not None:
            worker.close()
        owner.rollback()
        query(owner,'reset role')
        if role_created:
            for signature in contract['s9_rpc'] + contract['support_rpc']:
                query(owner,pgsql.SQL('revoke execute on function {} from {}').format(pgsql.SQL(signature), pgsql.Identifier(role)))
            for table in contract['direct_read_tables']:
                query(owner,pgsql.SQL('revoke select on public.{} from {}').format(pgsql.Identifier(table),pgsql.Identifier(role)))
            for table in ('q_kb_parse_queue','q_kb_s3_ready_queue'):
                query(owner,pgsql.SQL('revoke select, update on pgmq.{} from {}').format(pgsql.Identifier(table),pgsql.Identifier(role)))
            for (signature,) in query(owner,"select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgmq' and p.proname='read'"):
                query(owner,pgsql.SQL('revoke execute on function {} from {}').format(pgsql.SQL(signature),pgsql.Identifier(role)))
            query(owner,pgsql.SQL('revoke usage on schema public, pgmq from {}').format(pgsql.Identifier(role)))
            query(owner,pgsql.SQL('drop role {}').format(pgsql.Identifier(role)))
        owner.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target',type=Path,required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.target),indent=2))
    except Exception as exc:
        # Never emit psycopg diagnostics/DSNs/passwords or a traceback with SQL.
        print(json.dumps({'passed':False,'error_type':type(exc).__name__,'sqlstate':getattr(exc,'pgcode',None),'locations':[(Path(f.filename).name,f.lineno) for f in traceback.extract_tb(exc.__traceback__)]}),file=sys.stderr)
        raise SystemExit(1)
