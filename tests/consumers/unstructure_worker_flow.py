#!/usr/bin/env python3
"""Synthetic orchestration on owned local stacks or explicitly verified Preview."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from dataclasses import replace
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import logging
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import traceback
from unittest.mock import patch
from urllib.parse import urlsplit
import uuid

from unstructure_role_boundary import local_target, query
from runtime import load_private, validate_target, PRODUCTION_REF

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT.parent / 'unstructure/src'


def check_address(address, ports):
    if not isinstance(address, tuple) or address[0] != '127.0.0.1' or address[1] not in ports:
        raise RuntimeError('Non-fixture network destination refused')


class LocalObjects:
    """S3 transport double only; real ready-check validates bytes/manifest/hash."""
    def __init__(self, root):
        self.root = root.resolve()
        self.calls = []
        self.corrupt = False

    def path(self, key):
        if not key.startswith('processed/'):
            raise RuntimeError('Unexpected fixture prefix')
        path = (self.root / key.removeprefix('processed/')).resolve()
        if not path.is_relative_to(self.root):
            raise RuntimeError('Object path escaped fixture root')
        return path

    def head_object(self, *, Bucket, Key):
        assert Bucket == 'synthetic'
        self.calls.append('head')
        size = self.path(Key).stat().st_size
        return {'ContentLength': size + int(self.corrupt and not Key.endswith('manifest.json'))}

    def get_object(self, *, Bucket, Key):
        assert Bucket == 'synthetic'
        self.calls.append('get')
        return {'Body': io.BytesIO(self.path(Key).read_bytes())}


class Providers(BaseHTTPRequestHandler):
    mode = 'success'
    state = 'SUCCESS'
    calls = []
    backlog = 0
    hold_for_heartbeat = False
    heartbeat_tick = threading.Event()

    def log_message(self, *_):
        pass

    def reply(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def parsed():
        return {'result': [{'text': 'Synthetic worker permission evidence.', 'page_idx': 0, 'type': 'text'}], 'txt': 'Synthetic worker permission evidence.'}

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        type(self).calls.append(self.path)
        if self.path == '/v1/embeddings':
            values = json.loads(body)['input']
            self.reply({'data': [{'index': i, 'embedding': [1.0, 0.0, 0.0]} for i, _ in enumerate(values)]})
        elif self.path.startswith('/parser'):
            if self.hold_for_heartbeat and not self.heartbeat_tick.wait(timeout=5):
                self.reply({'error': 'fixture heartbeat barrier timed out'}, 503)
                return
            if self.mode == 'transient':
                self.reply({'error': 'synthetic unavailable'}, 503)
            else:
                self.reply(self.parsed())
        elif self.path == '/two_stage/task':
            self.reply({'task_id': 'synthetic-' + uuid.uuid4().hex, 'state': 'PENDING'})
        else:
            self.reply({}, 404)

    def do_GET(self):
        type(self).calls.append(self.path)
        if self.path == '/two_stage/queue_status':
            self.reply({'queues': {'queue_parse_gpu': self.backlog}, 'unacked': {}})
        elif self.path.startswith('/two_stage/task/'):
            if self.state == 'POLL_ERROR':
                self.reply({}, 503)
            else:
                self.reply({'state': self.state, 'result': self.parsed(), 'error': 'synthetic parser failure'})
        else:
            self.reply({}, 404)


def load_sources():
    sys.path.insert(0, str(SOURCE))
    from kb_parse_worker import worker, control_plane, reconciler, s3_ready
    return worker, control_plane, reconciler, s3_ready


def configuration(cls, dsn, root, base):
    return cls(database_url=dsn, worker_id='s9-local-flow', queue_name='kb_parse_queue',
        s3_ready_queue_name='kb_s3_ready_queue', queue_vt_seconds=30, lock_seconds=30,
        heartbeat_interval_seconds=1, poll_interval_seconds=1,
        nas_raw_root=root/'raw', nas_processed_root=root/'processed',
        unstructure_serve_url=base+'/parser', unstructure_serve_bearer_token='synthetic',
        use_two_stage_parser=False, unstructure_serve_two_stage_base_url=base,
        two_stage_submit_timeout_seconds=5, two_stage_status_timeout_seconds=5,
        two_stage_poll_interval_seconds=1, two_stage_priority='normal', two_stage_chunk_type=True,
        two_stage_provider=None, two_stage_model=None, two_stage_prompt=None,
        two_stage_parse_queue_name='queue_parse_gpu', two_stage_max_parse_backlog=5,
        two_stage_queue_status_timeout_seconds=5, two_stage_finalizer_limit=1,
        parser_profile='synthetic', parser_version='fixture', s3_ready_mode='check',
        s3_bucket='synthetic', s3_processed_prefix='processed', s3_strict_hash=True,
        s3_ready_timeout_seconds=1, s3_ready_poll_interval_seconds=1,
        embedding_base_url=base+'/v1', embedding_model='synthetic', embedding_api_key='synthetic',
        embedding_dimensions=3, embedding_batch_size=2, embedding_chunk_max_tokens=1000,
        embedding_timeout_seconds=5, parse_job_timeout_seconds=20, s3_ready_job_timeout_seconds=10)


def preview_target(path, expected_ref):
    target = load_private(path)
    validate_target(target)
    receipt = target.get('verification_receipt', {})
    if (target.get('mode') != 'preview' or target.get('project_ref') != expected_ref
            or target.get('parent_project_ref') != PRODUCTION_REF
            or receipt.get('is_default') is not False
            or receipt.get('persistent') is not False or not receipt.get('branch_id')):
        raise RuntimeError('Exact disposable KB Preview receipt required')
    return target


def run(target_path, acl_upgrade=False, preview_ref=None):
    if preview_ref and acl_upgrade:
        raise RuntimeError('Preview cannot reopen pre-S9 ACLs')
    # Both paths fail before importing application code or opening a DB connection.
    target = preview_target(target_path, preview_ref) if preview_ref else local_target(target_path)
    import psycopg2
    from psycopg2 import sql
    from psycopg2.extensions import make_dsn
    w, cp, rec, s3 = load_sources()
    owner = psycopg2.connect(target['db_url'], connect_timeout=5)
    nonce = 's9_flow_' + uuid.uuid4().hex[:16]
    role = 'postgres' if preview_ref else nonce
    denied_role = nonce + '_deny'
    created = False
    denied_created = False
    report = {}
    counts = {'connections': 0}
    scenarios = []
    server = None
    cid = None
    def admin(statement):
        if preview_ref:
            query(owner, statement)
            return
        # Local platform admin is used solely for temporary role lifecycle.
        # stdin and captured diagnostics never enter command args or receipts.
        result = subprocess.run(['docker', 'exec', '-i', 'supabase_db_'+target['project_id'],
            'psql', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
            input=statement.as_string(owner), text=True, capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError('Owned-local role lifecycle failed; diagnostics withheld')
    # Fixture and role setup use owner; every actual worker connection uses a
    # fresh NOSUPERUSER login with explicit object privileges and its own BYPASSRLS.
    # This is an observed-capability emulation, NOT a recommended production grant.
    try:
        if preview_ref:
            assert query(owner, 'select session_user,current_user')[0] == ('postgres', 'postgres')
            assert query(owner, 'select rolsuper,rolbypassrls from pg_roles where rolname=current_user')[0] == (False, True)
            # A shared/populated branch must never be consumed by this harness.
            assert query(owner, 'select count(*) from public.kb_jobs')[0][0] == 0
            for queue in ('kb_parse_queue', 'kb_s3_ready_queue'):
                assert query(owner, sql.SQL('select count(*) from pgmq.{}').format(sql.Identifier('q_'+queue)))[0][0] == 0
        password = secrets.token_urlsafe(32)
        if not preview_ref:
            admin(sql.SQL('create role {} login inherit nosuperuser nocreatedb nocreaterole noreplication bypassrls password {}').format(sql.Identifier(role), sql.Literal(password)))
            created = True
        admin(sql.SQL('create role {} login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls password {}').format(sql.Identifier(denied_role), sql.Literal(password)))
        denied_created = True
        contract = json.loads((Path(__file__).with_name('worker_role_contract.json')).read_text())
        if not preview_ref:
            for signature in contract['s9_rpc'] + contract['support_rpc']:
                query(owner, sql.SQL('grant execute on function {} to {}').format(sql.SQL(signature), sql.Identifier(role)))
            query(owner, sql.SQL('grant usage on schema public, pgmq to {}').format(sql.Identifier(role)))
            for table in contract['direct_read_tables']:
                query(owner, sql.SQL('grant select on public.{} to {}').format(sql.Identifier(table), sql.Identifier(role)))
            for table in ('q_kb_parse_queue', 'q_kb_s3_ready_queue'):
                query(owner, sql.SQL('grant select, update on pgmq.{} to {}').format(sql.Identifier(table), sql.Identifier(role)))
        dsn = (make_dsn(target['db_url'], connect_timeout=15, application_name='s9-preview-worker-flow')
               if preview_ref else make_dsn(target['db_url'], user=role, password=password, connect_timeout=5,
                   options='-c statement_timeout=10000', application_name='s9-local-worker-flow'))
        denied_user = denied_role + '.' + preview_ref if preview_ref and (urlsplit(target['db_url']).hostname or '').endswith('.pooler.supabase.com') else denied_role
        denied_dsn = make_dsn(dsn, user=denied_user, password=password)
        real_connect = cp.connect
        real_heartbeat = cp.heartbeat_job

        def checked_heartbeat(*args, **kwargs):
            result = real_heartbeat(*args, **kwargs)
            if result:
                counts['heartbeats'] = counts.get('heartbeats', 0) + 1
                if counts['heartbeats'] >= 2:
                    Providers.heartbeat_tick.set()
            return result

        def checked_connect(url):
            assert url in (dsn, denied_dsn), 'Unexpected worker connection configuration'
            expected_role = role if url == dsn else denied_role
            conn = real_connect(url)
            try:
                assert query(conn, 'select session_user,current_user')[0] == (expected_role, expected_role)
                assert query(conn, 'select rolsuper,rolbypassrls from pg_roles where rolname=current_user')[0] == (False, url == dsn)
                counts['connections'] += 1
                return conn
            except BaseException:
                conn.close()
                raise

        with tempfile.TemporaryDirectory(prefix='s9-worker-artifacts-') as tmp, ExitStack() as stack:
            root = Path(tmp)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Providers)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.server_close)
            stack.callback(server.shutdown)
            base = f'http://127.0.0.1:{server.server_port}'
            cfg = configuration(w.WorkerConfig, dsn, root, base)
            objects = LocalObjects(cfg.nas_processed_root)
            stack.enter_context(patch.object(cp, 'connect', checked_connect))
            stack.enter_context(patch.object(cp, 'heartbeat_job', checked_heartbeat))
            stack.enter_context(patch.object(s3.boto3, 'client', side_effect=lambda name: objects if name == 's3' else (_ for _ in ()).throw(RuntimeError('Unexpected AWS client'))))
            # No network except this fixture HTTP listener. libpq uses the
            # validated owned database port, not Python socket.connect.
            original_connect = socket.socket.connect
            def confined_connect(sock, address):
                check_address(address, {server.server_port})
                return original_connect(sock, address)
            stack.enter_context(patch.object(socket.socket, 'connect', confined_connect))
            # Suppress application exception text (it can contain SQL/DSNs).
            previous_disable = logging.root.manager.disable
            logging.disable(logging.CRITICAL)
            stack.callback(logging.disable, previous_disable)
            Providers.calls, Providers.mode, Providers.state, Providers.backlog = [], 'success', 'SUCCESS', 0
            Providers.hold_for_heartbeat = True
            Providers.heartbeat_tick.clear()
            cid, actor = str(uuid.uuid4()), str(uuid.uuid4())
            query(owner, "insert into public.kb_collections(id,name,path) values(%s,'Synthetic S9 flow',%s)", (cid,'/synthetic/'+cid))

            def fixture(version=1, status='queued', corrupt=False):
                doc, job = str(uuid.uuid4()), str(uuid.uuid4())
                raw = cfg.nas_raw_root/'synthetic'/cid/f'{doc}.pdf'
                raw.parent.mkdir(parents=True, exist_ok=True)
                raw.write_bytes(b'%PDF-1.4\nSynthetic only\n%%EOF')
                digest = 'f'*64 if corrupt else hashlib.sha256(raw.read_bytes()).hexdigest()
                query(owner, "insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,file_size,sha256,created_by,owner_user_id,status,raw_uri,document_version) values(%s,%s,%s,'synthetic.pdf','pdf',%s,%s,%s,%s,'parse_queued',%s,%s)", (doc,cid,doc,raw.stat().st_size,digest,actor,actor,raw.as_posix(),version))
                query(owner, "insert into public.kb_jobs(id,document_id,document_version,stage,status) values(%s,%s,1,'parse',%s::public.kb_job_status)", (job,doc,status))
                msg = send(job)
                return doc, job, msg

            def send(job):
                return query(owner, "select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))", (job,))[0][0]

            def status(job):
                return query(owner, 'select status::text from public.kb_jobs where id=%s', (job,))[0][0]

            def archived(msg, queue='kb_parse_queue'):
                assert query(owner, sql.SQL('select count(*) from pgmq.{} where msg_id=%s').format(sql.Identifier('q_'+queue)),(msg,))[0][0] == 0
                assert query(owner, sql.SQL('select count(*) from pgmq.{} where msg_id=%s').format(sql.Identifier('a_'+queue)),(msg,))[0][0] == 1

            def ready(doc):
                job, msg = query(owner, "select id,pgmq_msg_id from public.kb_jobs where document_id=%s and stage='s3_ready'", (doc,))[0]
                assert w.S3ReadyWorker(cfg).run_once()
                assert status(job) == 'succeeded'
                archived(msg, 'kb_s3_ready_queue')
                assert query(owner,'select status::text from public.kb_documents where id=%s',(doc,))[0][0] == 'processed_s3_ready'

            # Complete synchronous parse -> real artifacts -> strict S3 checks.
            policy = json.loads((ROOT/'tests/schema/legacy_acl_policy.json').read_text())
            migration = ROOT/'supabase/migrations/20261015081907_narrow_legacy_public_permissions.sql'
            if acl_upgrade:
                # Reconstruct just the exact pre-S9 ACL delta, preserving all
                # current object bodies. Full prior-chain replay is a separate gate.
                for signature in policy['restricted_functions']:
                    query(owner, sql.SQL('grant execute on function {} to public, anon, authenticated').format(sql.SQL(signature)))
                for table in policy['restricted_tables']:
                    query(owner, sql.SQL('grant insert,update,delete,references,trigger,truncate on public.{} to anon,authenticated').format(sql.Identifier(table)))
            doc, job, msg = fixture()
            if acl_upgrade:
                before = query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,))
                query(owner, migration.read_text())
                assert query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,)) == before
                scenarios.append('populated pre-S9 ACL delta upgraded without changing queued job')
            for signature in policy['restricted_functions']:
                assert not query(owner,"select has_function_privilege('authenticated',%s,'EXECUTE')",(signature,))[0][0]
            for table in ('q_kb_parse_queue', 'q_kb_s3_ready_queue'):
                assert query(owner,"select relrowsecurity from pg_class where oid=%s::regclass",('pgmq.'+table,))[0][0]
                assert query(owner,"select count(*) from pg_policies where schemaname='pgmq' and tablename=%s",(table,))[0][0] == 0
            # Red contrast executes the SAME scheduler: denied at queue access,
            # before a claim or any business state mutation.
            before = query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,))
            try:
                w.ParseWorker(replace(cfg, database_url=denied_dsn)).run_once()
            except psycopg2.Error as exc:
                assert exc.pgcode == '42501'
            else:
                raise AssertionError('Restricted scheduler must fail at queue access')
            assert query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,)) == before
            scenarios.append('restricted LOGIN scheduler denied 42501 before claim')
            assert w.ParseWorker(cfg).run_once() and status(job) == 'succeeded'
            assert Providers.heartbeat_tick.is_set() and counts['heartbeats'] >= 2
            Providers.hold_for_heartbeat = False
            archived(msg)
            assert query(owner,'select chunk_count from public.kb_documents where id=%s',(doc,))[0][0] == 1
            ready(doc)
            duplicate = send(job)
            before = len(Providers.calls)
            assert w.ParseWorker(cfg).run_once() and status(job) == 'succeeded'
            assert len(Providers.calls) == before
            archived(duplicate)
            scenarios.append('sync parse/artifacts/strict S3/terminal duplicate')

            doc, job, _ = fixture()
            assert w.ParseWorker(cfg).run_once() and status(job) == 'succeeded'
            sj = query(owner,"select id from public.kb_jobs where document_id=%s and stage='s3_ready'",(doc,))[0][0]
            objects.corrupt = True
            assert w.S3ReadyWorker(cfg).run_once() and status(sj) == 'failed'
            assert query(owner,'select status::text from public.kb_documents where id=%s',(doc,))[0][0] != 'processed_s3_ready'
            objects.corrupt = False
            query(owner,"update public.kb_jobs set next_retry_at=now()-interval '1 second' where id=%s",(sj,))
            query(owner,"update pgmq.q_kb_s3_ready_queue set vt=now()-interval '1 second' where message->>'job_id'=%s",(str(sj),))
            ready(doc)
            scenarios.append('S3 corrupted artifact denied then retry recovered')

            # Invalid bytes fail terminally before calling any provider.
            _, job, msg = fixture(corrupt=True)
            before = len(Providers.calls)
            assert w.ParseWorker(cfg).run_once() and status(job) == 'dead'
            assert len(Providers.calls) == before
            archived(msg)
            scenarios.append('raw hash failure and archive')

            # Retry disposition and its wakeup are real database transitions.
            doc, job, msg = fixture()
            Providers.mode = 'transient'
            assert w.ParseWorker(cfg).run_once() and status(job) == 'failed'
            archived(msg)
            assert query(owner,'select next_retry_at is not null from public.kb_jobs where id=%s',(job,))[0][0]
            query(owner,"update public.kb_jobs set next_retry_at=now()-interval '1 second' where id=%s",(job,))
            query(owner,"update pgmq.q_kb_parse_queue set vt=now()-interval '1 second' where message->>'job_id'=%s",(job,))
            Providers.mode = 'success'
            assert w.ParseWorker(cfg).run_once() and status(job) == 'succeeded'
            ready(doc)
            scenarios.append('transient failure/backoff/wakeup/recovery')

            # Version and deletion guards must prevent parser side effects.
            for kind in ('stale', 'deleted'):
                doc, job, msg = fixture(version=2 if kind == 'stale' else 1)
                if kind == 'deleted':
                    query(owner,'update public.kb_documents set deleted_at=now() where id=%s',(doc,))
                before = len(Providers.calls)
                assert w.ParseWorker(cfg).run_once()
                assert status(job) in ('cancelled','dead')
                assert len(Providers.calls) == before
                archived(msg)
                scenarios.append(kind+' document guarded')

            # Split submitter/finalizer, parser backpressure and poll recovery.
            two = replace(cfg, use_two_stage_parser=True)
            doc, job, msg = fixture()
            Providers.backlog = 5
            assert not w.ParseSubmitterWorker(two).run_once() and status(job) == 'queued'
            Providers.backlog = 0
            assert w.ParseSubmitterWorker(two).run_once() and status(job) == 'running'
            archived(msg)
            for state in ('STARTED', 'POLL_ERROR', 'SUCCESS'):
                Providers.state = state
                query(owner,"update public.kb_jobs set locked_until=now()-interval '1 second' where id=%s",(job,))
                assert w.ParseFinalizerWorker(two).run_once()
                assert status(job) == ('succeeded' if state == 'SUCCESS' else 'running')
            ready(doc)
            assert not w.ParseFinalizerWorker(two).run_once()
            scenarios.append('two-stage backpressure/submit/poll error/recovery/duplicate')
            doc, job, _ = fixture()
            assert w.ParseSubmitterWorker(two).run_once()
            query(owner,"update public.kb_jobs set locked_until=now()-interval '1 second' where id=%s",(job,))
            Providers.state = 'FAILURE'
            assert w.ParseFinalizerWorker(two).run_once() and status(job) == 'failed'
            query(owner,"update public.kb_jobs set next_retry_at=now()-interval '1 second' where id=%s",(job,))
            query(owner,"update pgmq.q_kb_parse_queue set vt=now()-interval '1 second' where message->>'job_id'=%s",(job,))
            Providers.state = 'SUCCESS'
            assert w.ParseSubmitterWorker(two).run_once()
            query(owner,"update public.kb_jobs set locked_until=now()-interval '1 second' where id=%s",(job,))
            assert w.ParseFinalizerWorker(two).run_once() and status(job) == 'succeeded'
            ready(doc)
            scenarios.append('two-stage parser failure retry and recovery')

            # Reconciler restores DB finalization from real durable local files.
            doc, job, _ = fixture()
            assert w.ParseWorker(cfg).run_once() and status(job) == 'succeeded'
            # Remove only this scenario's S3 continuation before replaying the
            # synthetic crash boundary (artifacts written, DB not finalized).
            sj, sm = query(owner,"select id,pgmq_msg_id from public.kb_jobs where document_id=%s and stage='s3_ready'",(doc,))[0]
            query(owner,"select pgmq.archive('kb_s3_ready_queue',%s)",(sm,))
            query(owner,'delete from public.kb_jobs where id=%s',(sj,))
            query(owner,"update public.kb_jobs set status='dead',locked_until=null where id=%s",(job,))
            query(owner,"update public.kb_documents set status='failed',processed_manifest_local_uri=null,processed_artifact_uuid=null,processed_manifest_hash=null where id=%s",(doc,))
            before = query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,))
            assert rec.ParseFinalizationReconciler(cfg, document_id=doc, dry_run=True).run_once() == 1
            assert query(owner,'select to_jsonb(j) from public.kb_jobs j where id=%s',(job,)) == before
            assert rec.ParseFinalizationReconciler(cfg, document_id=doc).run_once() == 1
            assert status(job) == 'succeeded'
            assert rec.ParseFinalizationReconciler(cfg, document_id=doc).run_once() == 0
            ready(doc)
            scenarios.append('artifact reconciler replay and idempotency')

            assert objects.calls.count('get') > 0
            assert '/v1/embeddings' in Providers.calls
            report.update({'schema_version':1,'passed':True,'mode':target['mode'],'run_id':target['run_id'],
                'chain_mode':'populated ACL delta upgrade' if acl_upgrade else 'fresh head',
                'role_profile':('Preview postgres NOSUPERUSER BYPASSRLS; existing grants/ownership, no added worker grants' if preview_ref else 'fresh LOGIN NOSUPERUSER BYPASSRLS; explicit 13 RPC/schema/queue/snapshot grants; nonowner, test-only'),
                'ownership_equivalence':('Preview owner login observed; production memberships/configuration not reproduced' if preview_ref else 'object access granted explicitly; hosted owner identity/memberships not reproduced'),
                'contract_sha256':hashlib.sha256(Path(__file__).with_name('worker_role_contract.json').read_bytes()).hexdigest(),
                'migration_sha256':hashlib.sha256(migration.read_bytes()).hexdigest(),
                'identity_checks':counts['connections'],'scenarios':scenarios,
                'successful_heartbeats':counts['heartbeats'],'midflight_heartbeat_barrier':True,
                'entrypoint':'actual run_once methods; CLI argument dispatch not executed',
                'archive_cleanup':('synthetic archive/audit rows require deletion of this owned disposable Preview' if preview_ref else 'synthetic archive/audit rows disposed by owned stack stop'),
                'database_mocked':False,'external_doubles':['loopback parser/embedding HTTP','S3 object transport'],
                'production_qualified':False,'source_sha256':{str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((SOURCE/'kb_parse_worker').glob('*.py'))},
                'harness_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
            return report
    finally:
        owner.rollback()
        if cid is not None:
            for queue_name in ('kb_parse_queue', 'kb_s3_ready_queue'):
                query(owner, sql.SQL("delete from pgmq.{} where message->>'job_id' in (select id::text from public.kb_jobs where document_id in (select id from public.kb_documents where primary_collection_id=%s))").format(sql.Identifier('q_'+queue_name)), (cid,))
            query(owner,'delete from public.kb_jobs where document_id in (select id from public.kb_documents where primary_collection_id=%s)',(cid,))
            query(owner,'delete from public.kb_documents where primary_collection_id=%s',(cid,))
            query(owner,'delete from public.kb_collections where id=%s',(cid,))
        if created:
            admin(sql.SQL('drop owned by {}; drop role {};').format(sql.Identifier(role), sql.Identifier(role)))
        if denied_created:
            # The Preview denial login owns nothing and receives no grants.
            # Hosted postgres has CREATEROLE/admin authority, but not SET ROLE
            # authority for DROP OWNED on this NOINHERIT login (PG17).
            if preview_ref:
                admin(sql.SQL('drop role {}').format(sql.Identifier(denied_role)))
            else:
                admin(sql.SQL('drop owned by {}; drop role {};').format(sql.Identifier(denied_role), sql.Identifier(denied_role)))
        assert query(owner,'select count(*) from pg_roles where rolname in (%s,%s)',(nonce,denied_role))[0][0] == 0
        report['temporary_roles_removed'] = True
        owner.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--acl-upgrade', action='store_true')
    parser.add_argument('--preview-ref', help='Opt in to the exact verified disposable KB Preview; never production/persistent Dev')
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.target, args.acl_upgrade, args.preview_ref), indent=2))
        return 0
    except Exception as exc:
        print(json.dumps({'passed':False,'error_type':type(exc).__name__,'sqlstate':getattr(exc,'pgcode',None),'locations':[(Path(f.filename).name,f.lineno) for f in traceback.extract_tb(exc.__traceback__)]}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
