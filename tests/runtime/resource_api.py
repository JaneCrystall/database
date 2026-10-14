#!/usr/bin/env python3
"""Exercise real local PostgREST, never a hosted URL or a mocked database."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

container, workdir = sys.argv[1:]
if not re.fullmatch(r'supabase_db_tiangong-ai-database-test-\d+-\d+', container):
    raise SystemExit('Refusing a non-gate container')
if not Path(workdir).name.startswith('tiangong-ai-database-test.'):
    raise SystemExit('Refusing a non-gate workdir')
cli = os.environ['SUPABASE_CLI']
status = json.loads(subprocess.check_output([cli, 'status', '--workdir', workdir, '-o', 'json'], stderr=subprocess.DEVNULL))
url = status['API_URL']
parsed = urllib.parse.urlparse(url)
assert parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1'), 'Local HTTP only'
service = status.get('SERVICE_ROLE_KEY') or status['SECRET_KEY']
anon = status.get('ANON_KEY') or status['PUBLISHABLE_KEY']
actor, outsider, cid = [str(uuid.uuid4()) for _ in range(3)]
# Use the disposable Auth service, not a forged JWT or a production identity.
email, password = 'resource-'+actor+'@example.test', str(uuid.uuid4())
def auth(path, key, payload):
    headers = {'apikey':key,'Content-Type':'application/json'}
    if key.startswith('eyJ'): headers['Authorization']='Bearer '+key
    req=urllib.request.Request(url+'/auth/v1/'+path,headers=headers,data=json.dumps(payload).encode())
    with urllib.request.urlopen(req,timeout=15) as response: return json.load(response)
identity=auth('admin/users',service,{'email':email,'password':password,'email_confirm':True})
actor=identity['id']
user=auth('token?grant_type=password',anon,{'email':email,'password':password})['access_token']

def sql(query):
    result = subprocess.run(['docker','exec','-i',container,'psql','-XAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'], input=query,text=True,capture_output=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''

def request(path, body=None, *, token=service, schema='api', method=None):
    method = method or ('POST' if body is not None else 'GET')
    headers = {'apikey':service if token==service else anon, 'Content-Type':'application/json'}
    if token.startswith('eyJ'): headers['Authorization']='Bearer '+token
    if schema is not None:
        headers['Accept-Profile' if method in ('GET','HEAD') else 'Content-Profile'] = schema
    req = urllib.request.Request(url+'/rest/v1/'+path, data=json.dumps(body).encode() if body is not None else None, headers=headers,method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            content = response.read(); return response.status, json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        content=error.read(); return error.code, json.loads(content) if content else None

def expect(result, code, message=None):
    observed, data = result
    assert observed == code, (code, observed, data)
    if message: assert message in data.get('message',''), (message, data)
    return data

# Wait only for schema-cache readiness, never retry a mutating RPC.
for attempt in range(60):
    try:
        code, data = request('', schema='api')
        if code == 200 and '/rpc/kb_resource_command' in data.get('paths',{}): break
    except (urllib.error.URLError, TimeoutError): pass
    time.sleep(0.5)
else: raise AssertionError('API schema cache did not expose resource endpoints')
# Valid ordinary user JWT must reach PostgREST, not merely fail JWT verification.
expect(request('',token=user,schema='public'),200)
for role_token in (anon,user,service):
    for table in ('kb_resource_entries','kb_resource_document_links','kb_resource_requests'):
        expect(request(table,token=role_token,schema='private'),406)
        for schema in ('public','api'):
            for method,body in [('GET',None),('POST',{}),('PATCH',{}),('DELETE',None)]:
                code,data=request(table,body,token=role_token,schema=schema,method=method)
                assert code in (401,403,404), (schema,table,method,code,data)
    for schema in ('public','api'):
        for name,body in [('kb_resource_normalize_doi',{'p_value':'10.1/x'}),('kb_resource_legacy_metadata',{'p_ref':{}}),('kb_resource_validate_metadata',{'p_profile':{},'p_metadata':{},'p_complete':False})]:
            code,data=request('rpc/'+name,body,token=role_token,schema=schema)
            assert code in (401,403,404), (schema,name,code,data)
for schema in ('public',None):
    code,_=request('rpc/kb_resource_command',{},schema=schema)
    assert code == 404, 'No legacy/default-schema resource RPC may remain'

profile={'id':'http-test','version':1,'metadata_mode':'managed','fields':{'title':'string'},'required_fields':['title'],'matching':['unique_source_key'],'source_bindings':[{'id':'catalog','kind':'metadata-snapshot'},{'id':'drop','kind':'file-snapshot','source_root_ref':'synthetic/http'}]}
sql(f"insert into public.kb_collections(id,name,path,metadata_schema_json) values('{cid}','HTTP synthetic','http-{cid}','{json.dumps({'resource_profile':profile})}'::jsonb); insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection','{cid}','user','{actor}',array['manage']::public.kb_grant_action[],'{actor}');")
request_id=str(uuid.uuid4())
args={'p_actor_id':actor,'p_collection_id':cid,'p_operation':'upsert','p_request_id':request_id,'p_payload':{'binding_id':'catalog','external_key':'http-entry','metadata':{'title':'HTTP synthetic'},'expected_revision':0,'reason':'API qualification'}}
for token in (anon,user):
    expect(request('rpc/kb_resource_command',args,token=token),401 if token==anon else 403)
    expect(request('rpc/kb_resource_get',{'p_actor_id':actor,'p_collection_id':cid,'p_entry_id':str(uuid.uuid4())},token=token),401 if token==anon else 403)
expect(request('rpc/kb_resource_command',{**args,'p_actor_id':outsider}),403,'RESOURCE_FORBIDDEN')
r=expect(request('rpc/kb_resource_command',args),200)
assert r == expect(request('rpc/kb_resource_command',args),200)
expect(request('rpc/kb_resource_command',{**args,'p_payload':{**args['p_payload'],'reason':'changed'}}),500,'RESOURCE_REQUEST_CONFLICT')
entry=r['entry_id']
get={'p_actor_id':actor,'p_collection_id':cid,'p_entry_id':entry}
current=expect(request('rpc/kb_resource_get',get),200)
assert current['effective_metadata']['title']=='HTTP synthetic'
expect(request('rpc/kb_resource_get',{**get,'p_actor_id':outsider}),403,'RESOURCE_FORBIDDEN')

def command(op,**payload):
    global r
    body={**args,'p_operation':op,'p_request_id':str(uuid.uuid4()),'p_payload':{'entry_id':entry,'expected_revision':r['revision'],'reason':'HTTP lifecycle',**payload}}
    r=expect(request('rpc/kb_resource_command',body),200)
    return body
candidate=str(uuid.uuid4())
command('attach',candidate={'candidate_id':candidate,'binding_id':'drop','relative_locator':'test.pdf','sha256':'7'*64,'size':811,'stable':True,'pdf_valid':True})
command('review',decision='approve',candidate_id=candidate)
command('reserve',approved_revision=r['approved_revision'])
assert sql(f"select count(*) from public.kb_jobs where document_id='{r['document_id']}';")=='0'
relative=f"http-{cid}/{r['document_id']}.pdf"
pub=command('publish',approved_revision=r['approved_revision'],document_id=r['document_id'],sha256=r['approved_sha256'],size=r['approved_size'],copy_verified=True,raw_relative_path=relative,raw_uri='nas://raw/'+relative)
assert r==expect(request('rpc/kb_resource_command',pub),200)
assert sql(f"select count(*) from public.kb_jobs where document_id='{r['document_id']}';")=='1'
assert expect(request('rpc/kb_resource_get',get),200)['links'][0]['approval_current']
# A previous receipt must not bypass current authorization after revocation.
sql(f"update public.kb_grants set revoked_at=now() where resource_id='{cid}' and principal_id='{actor}';")
expect(request('rpc/kb_resource_command',args),403,'RESOURCE_FORBIDDEN')
expect(request('rpc/kb_resource_get',get),403,'RESOURCE_FORBIDDEN')
assert sql(f"select count(*) from private.kb_resource_entries where collection_id='{cid}';")=='1'
print('Real PostgREST schema, role, lifecycle, idempotency and revoked-access qualification passed.',flush=True)
