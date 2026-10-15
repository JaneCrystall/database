#!/usr/bin/env python3
"""S9 real Auth/PostgREST denial and trusted-worker effects, disposable local only."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
if len(sys.argv) == 2:
    sys.path.insert(0, str(ROOT / 'tests/consumers'))
    from runtime import load_private, validate_target
    target = load_private(Path(sys.argv[1]))
    validate_target(target)
    assert target['mode'] == 'local', 'S9 qualification is local-only'
    container = 'supabase_db_' + target['project_ref']
    workdir = target['workdir']
    url, anon, service = (target[k] for k in ('api_url','publishable_key','service_role_key'))
else:
    container, workdir = sys.argv[1:]
    assert re.fullmatch(r'supabase_db_tiangong-ai-database-test-\d+-\d+', container)
    status = json.loads(subprocess.check_output([os.environ['SUPABASE_CLI'],'status','--workdir',workdir,'-o','json'],stderr=subprocess.DEVNULL))
    url, anon, service = status['API_URL'], status['ANON_KEY'], status['SERVICE_ROLE_KEY']
from urllib.parse import urlsplit
assert urlsplit(url).hostname in ('127.0.0.1','localhost') and urlsplit(url).scheme == 'http'
labels=json.loads(subprocess.check_output(['docker','inspect','--format','{{json .Config.Labels}}',container]))
assert Path(labels['com.supabase.cli.workdir']).resolve() == Path(workdir).resolve(), 'Disposable ownership mismatch'

def sql(query):
    result=subprocess.run(['docker','exec','-i',container,'psql','-XAtq','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],input=query,text=True,capture_output=True)
    assert result.returncode == 0, 'Synthetic SQL failed: '+result.stderr
    return result.stdout.strip()

def request(path, body=None, token=None, method=None):
    token=token or service
    headers={'apikey':service if token==service else anon,'Content-Type':'application/json'}
    if token.startswith('eyJ'): headers['Authorization']='Bearer '+token
    req=urllib.request.Request(url+path,headers=headers,data=json.dumps(body).encode() if body is not None else None,method=method)
    try:
        with urllib.request.urlopen(req,timeout=15) as response:
            raw=response.read();return response.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        return error.code,json.loads(error.read())

def ok(result):
    code,data=result
    assert code==200, ('Expected successful service operation',code,data.get('code') if isinstance(data,dict) else None)
    return data

def rpc(name,args,token=None):return request('/rest/v1/rpc/'+name,args,token)
uid=str(uuid.uuid4()); email='s9-'+uid+'@example.test'; password=str(uuid.uuid4())
code,identity=request('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True})
assert code in (200,201)
user=ok(request('/auth/v1/token?grant_type=password',{'email':email,'password':password},anon))['access_token']
assert request('/rest/v1/',token=user)[0]==200, 'Use a valid Auth JWT'
catalog=json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())
policy=json.loads((ROOT/'tests/schema/legacy_acl_policy.json').read_text())
names={s.split('(')[0].split('.')[1] for s in policy['restricted_functions']}
# All changed non-trigger RPCs must reject valid API principals before body validation.
for f in catalog['functions']:
    if f['name'] not in names or f['returns']=='trigger':continue
    args={arg.split(' ',1)[0]:None for arg in f['arguments'].split(', ') if arg}
    for token in (anon,user):
        code,data=rpc(f['name'],args,token)
        assert code in (401,403) and data.get('code')=='42501', (f['name'],'ordinary execution admitted',code)
# Exact pre-existing business read/own-role policy; no write policies are introduced.
assert ok(request('/rest/v1/user_roles?select=user_id',token=user))==[]
for token in (anon,user):
    for method in ('POST','PATCH','DELETE'):
        code,data=request('/rest/v1/edu_meta?id=eq.'+uid,{'name':'S9 denied write'} if method!='DELETE' else None,token,method)
        assert code in (401,403) and data.get('code')=='42501', ('table write',method,code)

cid=str(uuid.uuid4()); actor=identity['id']
sql(f"insert into public.kb_collections(id,name,path) values('{cid}','S9 synthetic','/s9/{cid}');")
def fixture():
    doc,job=str(uuid.uuid4()),str(uuid.uuid4())
    sql(f"""insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,file_size,sha256,created_by,owner_user_id,status)
    values('{doc}','{cid}','{doc}','s9.pdf','.pdf',128,repeat('a',64),'{actor}','{actor}','parse_queued');
    insert into public.kb_jobs(id,document_id,document_version,stage,status,locked_by,locked_until)
    values('{job}','{doc}',1,'parse','running','s9-worker',now()+interval '5 minutes');""")
    return doc,job

doc,job=fixture()
msg=int(sql(f"select pgmq.send('kb_parse_queue',jsonb_build_object('job_id','{job}'));"))
register={'p_job_id':job,'p_worker_id':'s9-worker','p_task_id':'s9-task','p_task_url':'http://synthetic.invalid/task','p_status_url':'http://synthetic.invalid/status','p_queue_name':'kb_parse_queue','p_msg_id':msg}
# Spoofing a real worker_id with correct IDs cannot mutate the existing job.
for token in (anon,user):
    assert rpc('register_parse_two_stage_task',register,token)[0] in (401,403)
assert sql(f"select payload_json->'two_stage' is null from public.kb_jobs where id='{job}'")=='t'
assert ok(rpc('register_parse_two_stage_task',register))[0]['job_id']==job
claim=ok(rpc('claim_parse_two_stage_task',{'p_worker_id':'s9-finalizer'}))
assert claim[0]['job_id']==job and claim[0]['task_id']=='s9-task'
state={'p_job_id':job,'p_worker_id':'wrong-worker','p_state':'STARTED'}
assert ok(rpc('mark_parse_two_stage_task_state',state)) is False
state['p_worker_id']='s9-finalizer'
assert ok(rpc('mark_parse_two_stage_task_state',state)) is True
base={'p_job_id':job,'p_worker_id':'s9-finalizer','p_document_id':doc,'p_document_version':1}
local={**base,'p_processed_manifest_local_uri':'nas://synthetic/s9.json','p_artifact_uuid':str(uuid.uuid4())}
assert ok(rpc('mark_parse_local_ready',{**local,'p_document_version':2})) is False
assert ok(rpc('mark_parse_local_ready',{**local,'p_worker_id':'wrong-worker'})) is False
sql(f"update public.kb_jobs set locked_until=now()-interval '1 second' where id='{job}';")
assert ok(rpc('mark_parse_local_ready',local)) is False
assert ok(rpc('mark_parse_two_stage_task_state',state)) is False
s3={**base,'p_manifest_s3_key':'synthetic/s9.json'}
assert ok(rpc('mark_processed_s3_ready',s3)) is False
sql(f"update public.kb_jobs set locked_until=now()+interval '5 minutes' where id='{job}'; update public.kb_documents set deleted_at=now() where id='{doc}';")
assert ok(rpc('mark_parse_local_ready',local)) is False
assert ok(rpc('mark_processed_s3_ready',s3)) is False
# The existing deletion trigger cancels jobs; restore this synthetic fixture explicitly.
assert sql(f"select status from public.kb_jobs where id='{job}'")=='cancelled'
sql(f"update public.kb_documents set deleted_at=null where id='{doc}'; update public.kb_jobs set status='running',locked_by='s9-finalizer',locked_until=now()+interval '5 minutes' where id='{job}';")
assert ok(rpc('mark_parse_local_ready',local)) is True
assert ok(rpc('mark_processed_s3_ready',{**s3,'p_document_version':2})) is False
assert ok(rpc('mark_processed_s3_ready',s3)) is True
assert sql(f"select status from public.kb_jobs where id='{job}'")=='succeeded'
# fail_job_v2 deliberately retains legacy expired-lease behavior (identity still trusted).
doc,job=fixture(); fail={'p_job_id':job,'p_worker_id':'wrong-worker','p_retryable':False,'p_error':'synthetic'}
assert ok(rpc('fail_job_v2',fail))==[]
sql(f"update public.kb_jobs set locked_until=now()-interval '1 second' where id='{job}';")
fail['p_worker_id']='s9-worker'
assert ok(rpc('fail_job_v2',fail))[0]['job_status']=='dead'
# Replay is a repair operation: it accepts expired running/dead jobs, not an active lease.
doc,job=fixture(); replay={'p_job_id':job,'p_worker_id':'s9-repair','p_document_id':doc,'p_document_version':1,'p_processed_manifest_local_uri':'nas://synthetic/replay.json','p_artifact_uuid':str(uuid.uuid4())}
assert ok(rpc('replay_parse_local_ready_from_artifact',replay))==[]
sql(f"update public.kb_jobs set locked_until=null where id='{job}';")
assert ok(rpc('replay_parse_local_ready_from_artifact',replay))==[]
sql(f"update public.kb_jobs set locked_until=now()-interval '1 second' where id='{job}';")
assert ok(rpc('replay_parse_local_ready_from_artifact',{**replay,'p_document_version':2}))==[]
r=ok(rpc('replay_parse_local_ready_from_artifact',replay))[0]
assert r['parse_job_status']=='succeeded' and r['s3_ready_msg_id'] is not None
assert ok(rpc('replay_parse_local_ready_from_artifact',replay))[0]['s3_ready_job_id']==r['s3_ready_job_id']
assert ok(rpc('verify_kb_api_key',{'p_token_prefix':'s9-missing','p_token_hash':'0'*64}))[0]['ok'] is False
assert ok(rpc('has_service_role',{'user_id':actor})) is False
assert isinstance(ok(rpc('resolve_document_search_partition',{'p_document_id':doc})),list)
assert isinstance(ok(rpc('resolve_query_search_partitions',{})),list)
print('S9 real Auth/PostgREST: ordinary roles denied; seven trusted worker RPCs, spoofed IDs, lease/version/deletion and replay effects passed.')
