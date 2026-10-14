#!/usr/bin/env python3
"""Real local SQL/PGMQ contract tests. Gate-owned disposable Docker container only."""
import concurrent.futures
import json
import re
import subprocess
import sys
import uuid

container = sys.argv[1]
if not re.fullmatch(r'supabase_db_tiangong-ai-database-test-\d+-\d+', container):
    raise SystemExit('Refusing a non-gate container')

def quote(value):
    return "'" + str(value).replace("'", "''") + "'"

def sql(statement, error=None):
    p = subprocess.run(['docker','exec','-i',container,'psql','-XAt','--set','ON_ERROR_STOP=1',
                        '-U','postgres','-d','postgres'], input=statement, text=True, capture_output=True)
    if error:
        assert p.returncode and error in p.stderr, (error,p.stdout,p.stderr)
        return
    assert p.returncode == 0, p.stderr
    return p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ''

def check(statement, label):
    assert sql('select ('+statement+');') == 't', label
    print('PASS', label, flush=True)

actor = str(uuid.uuid4())
outsider = str(uuid.uuid4())
collections = []
for i, fields in enumerate(({'title':'string','organization':'string','report_year':'integer'},
                            {'title':'string','doi':'string'},
                            {'title':'string','source_ref':'string','organization':'string'})):
    cid=str(uuid.uuid4()); collections.append(cid)
    profile={'id':'test-profile-'+str(i),'version':1,'metadata_mode':'managed','fields':fields,
             'required_fields':list(fields),'matching':['explicit_resource_id','unique_source_key']+
               (['unique_normalized_doi'] if i==1 else []),
             'source_bindings':[{'id':'catalog','kind':'metadata-snapshot'},
               {'id':'drop','kind':'file-snapshot','source_root_ref':'synthetic/drop'}]}
    sql(f"insert into kb_collections(id,name,path,metadata_schema_json) values('{cid}','Synthetic M1','m1-test-{i}',{quote(json.dumps({'resource_profile':profile}))}::jsonb);")
    sql(f"insert into kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection','{cid}','user','{actor}',array['manage']::kb_grant_action[],'{actor}');")

def command(cid, op, payload, *, request=None, as_actor=actor, error=None):
    request=request or str(uuid.uuid4())
    body={'reason':'synthetic acceptance',**payload}
    statement=f"select api.kb_resource_command('{as_actor}','{cid}',{quote(op)},'{request}',{quote(json.dumps(body))}::jsonb);"
    out=sql('set role service_role; '+statement,error=error)
    return json.loads(out) if not error else None

def mutate(cid,op,r,**payload):
    return command(cid,op,{'entry_id':r['entry_id'],'expected_revision':r['revision'],**payload})

def create(cid,key,metadata=None):
    return command(cid,'upsert',{'binding_id':'catalog','external_key':key,'metadata':metadata or {},'expected_revision':0})

def attach(cid,r,h='a',candidate=None,**extra):
    c={'candidate_id':candidate or str(uuid.uuid4()),'binding_id':'drop','relative_locator':'test.pdf',
       'sha256':h*64,'size':811,'stable':True,'pdf_valid':True,**extra}
    return mutate(cid,'attach',r,candidate=c),c

def approve(cid,r,c):
    return mutate(cid,'review',r,decision='approve',candidate_id=c['candidate_id'])

def reserve(cid,r):
    return mutate(cid,'reserve',r,approved_revision=r['approved_revision'])

def publish(cid,r,**extra):
    relative='m1-test-'+str(collections.index(cid))+'/'+r['document_id']+'.pdf'
    return mutate(cid,'publish',r,approved_revision=r['approved_revision'],document_id=r['document_id'],
                  sha256=r['approved_sha256'],size=r['approved_size'],copy_verified=True,
                  raw_relative_path=relative,raw_uri='nas://raw/'+relative,**extra)

# Schema permission boundary: even the gateway has no direct writes to new business tables.
for role in ('anon','authenticated','service_role'):
    for table in ('private.kb_resource_entries','private.kb_resource_document_links','private.kb_resource_requests'):
        check(f"not has_table_privilege('{role}','{table}','SELECT,INSERT,UPDATE,DELETE')",role+' '+table+' no direct access')
# Execute each denied table operation, including gateway SQL access (RLS bypass
# does not bypass missing table ACL). WHERE false still requires the privilege.
for role in ('anon','authenticated','service_role'):
    for table in ('kb_resource_entries','kb_resource_document_links','kb_resource_requests'):
        for statement in (f"select * from private.{table} limit 0", f"insert into private.{table} default values", f"update private.{table} set collection_id=collection_id where false" if table != 'kb_resource_document_links' else f"update private.{table} set entry_id=entry_id where false", f"delete from private.{table} where false"):
            sql(f"set role {role}; "+statement+';', error='permission denied')
for role in ('anon','authenticated'):
    sql(f"set role {role}; select api.kb_resource_command('{actor}','{collections[0]}','upsert',gen_random_uuid(),'{{}}');",error='permission denied')
command(collections[0],'upsert',{},as_actor=outsider,error='RESOURCE_FORBIDDEN')

# S01 file first, no document before complete metadata and review.
r=create(collections[0],'file-first')
r,c=attach(collections[0],r)
mutate_payload={'entry_id':r['entry_id'],'expected_revision':r['revision'],'decision':'approve','candidate_id':c['candidate_id']}
command(collections[0],'review',mutate_payload,error='RESOURCE_REQUIRED_FIELD_MISSING')
check('not exists(select from kb_documents where primary_collection_id='+quote(collections[0])+')','no placeholder documents')
r=mutate(collections[0],'upsert',r,binding_id='catalog',metadata={'title':'A','organization':'Synthetic','report_year':2026})
r=approve(collections[0],r,c)
request=str(uuid.uuid4()); payload={'entry_id':r['entry_id'],'expected_revision':r['revision'],'approved_revision':r['approved_revision']}
a=command(collections[0],'reserve',payload,request=request)
b=command(collections[0],'reserve',payload,request=request)
assert a==b
command(collections[0],'reserve',{**payload,'reason':'different'},request=request,error='RESOURCE_REQUEST_CONFLICT')
# New request repairs/reuses reservation after a simulated process stop; no IO or transaction was retained.
r=reserve(collections[0],r); assert r['document_id']==a['document_id']
check(f"not exists(select from kb_jobs where document_id='{r['document_id']}')",'reservation never queues')
relative='m1-test-0/'+r['document_id']+'.pdf'
pp={'entry_id':r['entry_id'],'expected_revision':r['revision'],'approved_revision':r['approved_revision'],
    'document_id':r['document_id'],'sha256':r['approved_sha256'],'size':811,'copy_verified':True,
    'raw_relative_path':relative,'raw_uri':'nas://raw/'+relative}
for change in ({'sha256':'b'*64},{'size':810},{'copy_verified':False},{'raw_uri':'file:///outside/test.pdf'}, {'raw_relative_path':'../escape.pdf'}):
    command(collections[0],'publish',{**pp,**change},error='RESOURCE_PUBLICATION_INVALID')
publish_request=str(uuid.uuid4())
r=command(collections[0],'publish',pp,request=publish_request)
published_receipt=r.copy()
assert publish(collections[0],r)==r
check(f"(select count(*) from kb_jobs where document_id='{r['document_id']}')=1",'crash repair/replay queues once')
check(f"(select count(*) from pgmq.q_kb_parse_queue where message->>'job_id'='{r['job_id']}')=1",'exactly one PGMQ message')
first_document=r['document_id']; first_job=r['job_id']

# Same hash in two entries must fail; cross-collection same hash must remain distinct.
r2=create(collections[0],'different-entry',{'title':'B','organization':'Synthetic','report_year':2026})
r2,c2=attach(collections[0],r2); r2=approve(collections[0],r2,c2)
command(collections[0],'reserve',{'entry_id':r2['entry_id'],'expected_revision':r2['revision'],
    'approved_revision':r2['approved_revision']},error='RESOURCE_DOCUMENT_CONFLICT')

# S02 metadata-first and S03 third profile use exactly the same command functions.
for i,meta in ((1,{'title':'Journal','doi':'https://doi.org/10.9999/Synthetic'}),
               (2,{'title':'Report','organization':'Synthetic','source_ref':'REF-1'})):
    x=create(collections[i],'metadata-first',meta)
    x,cx=attach(collections[i],x); x=approve(collections[i],x,cx); x=reserve(collections[i],x); x=publish(collections[i],x)
    assert x['document_id']!=first_document
    check(f"(select dedupe_scope from kb_documents where id='{x['document_id']}')='{collections[i]}'",'server collection dedupe scope '+str(i))

# S05 conflict is durable, human selection is explicit, and stale clients cannot write.
r,new_candidate=attach(collections[0],r,h='b')
assert r['review_state']=='conflict' and r['approved_revision'] is None
command(collections[0],'review',{'entry_id':r['entry_id'],'expected_revision':1,'decision':'approve',
    'candidate_id':new_candidate['candidate_id']},error='RESOURCE_REVISION_CONFLICT')
r=approve(collections[0],r,new_candidate); r=reserve(collections[0],r)
# Put the old job in a leased state to prove the actual finalization RPC rejects it after replacement.
sql(f"update kb_jobs set status='running',locked_by='m1-old-worker',locked_until=now()+interval '1 hour' where id='{first_job}';")
r=publish(collections[0],r)
assert r['document_id']!=first_document and r['content_revision']==2
check(f"(select status='cancelled' from kb_jobs where id='{first_job}')",'replacement cancels old leased work')
check(f"(select document_version>=2 from kb_documents where id='{first_document}')",'replacement fences old document version')
check(f"not exists(select from register_parse_two_stage_task('{first_job}','m1-old-worker','task','http://local/submit','http://local/status','kb_parse_queue',1))",'stale worker registration rejected')

check(f"not exists(select from complete_parse_local_ready_and_enqueue_s3_check('{first_job}','m1-old-worker','{first_document}',1,'file:///synthetic/manifest.json',gen_random_uuid()))",'stale worker completion rejected')
check(f"not exists(select from replay_parse_local_ready_from_artifact('{first_job}','m1-old-worker','{first_document}',1,'file:///synthetic/manifest.json',gen_random_uuid()))",'stale artifact replay rejected')

assert command(collections[0],'publish',pp,request=publish_request)==published_receipt
current=json.loads(sql(f"select api.kb_resource_get('{actor}','{collections[0]}','{r['entry_id']}');"))
assert any(l['document_id']==first_document and not l['active'] and not l['approval_current'] for l in current['links'])
print('PASS historical receipt is distinct from authorized current state',flush=True)

# S07 overridden fields retain human authority; source proposal does not revoke approval.
r=mutate(collections[0],'override',r,fields={'title':'Human title'})
assert r['review_state']=='pending'
r=approve(collections[0],r,new_candidate)
approved=r['approved_revision']
r=mutate(collections[0],'upsert',r,binding_id='catalog',metadata={'title':'New source title','organization':'Synthetic','report_year':2026})
assert r['review_state']=='approved' and r['approved_revision']==approved
check(f"(select (source_metadata||manual_overrides)->>'title'='Human title' from private.kb_resource_entries where id='{r['entry_id']}')",'machine proposal cannot replace human override')
r=mutate(collections[0],'override',r,release_fields=['title'])
assert r['review_state']=='pending'

# Reapproval of unchanged bytes retains content identity and starts a new document generation.
r=approve(collections[0],r,new_candidate)
prior_document=r.get('document_id') or sql(f"select document_id from private.kb_resource_document_links where entry_id='{r['entry_id']}' and active")
prior_version=int(sql(f"select document_version from kb_documents where id='{prior_document}'"))
r=reserve(collections[0],r)
assert r['document_id']==prior_document and r['content_revision']==2
check(f"(select document_version>{prior_version} from kb_documents where id='{prior_document}')",'same bytes reapproval retains ID and increments processing version')
r=publish(collections[0],r)
check(f"(select metadata_json#>>'{{metadata,title}}'='New source title' from kb_documents where id='{prior_document}')",'reapproved processing snapshot follows current effective metadata')

# Malformed/unfinished file observations are rejected before any document is allocated.
for extra in ({'size':0},{'stable':False},{'pdf_valid':False},{'sha256':'fake'},
              {'relative_locator':'../test.pdf'},{'relative_locator':'%2e%2e/test.pdf'}):
    invalid={**new_candidate,**extra}
    command(collections[0],'attach',{'entry_id':r['entry_id'],'expected_revision':r['revision'],'candidate':invalid},error='RESOURCE_CANDIDATE_INVALID')

# Read permissions also cover observations, not only PDF processing commands.
sql(f"set role service_role; select api.kb_resource_get('{outsider}','{collections[0]}','{r['entry_id']}');",error='RESOURCE_FORBIDDEN')
check(f"(api.kb_resource_get('{actor}','{collections[0]}','{r['entry_id']}')->'effective_metadata'->>'title')='New source title'",'authorized current projection')

# Deletion owns its cleanup queue even when resource content is replaced concurrently.
deleting_document=r['document_id']
delete_job=sql(f"select job_id from request_delete('{deleting_document}','{actor}','synthetic delete','m1-delete-interaction');")
r,delete_candidate=attach(collections[0],r,h='f'); r=approve(collections[0],r,delete_candidate)
r=reserve(collections[0],r); r=publish(collections[0],r)
check(f"(select status='queued' from kb_jobs where id='{delete_job}')",'resource replacement preserves delete job')
check(f"(select status='delete_queued' and deleted_at is not null from kb_documents where id='{deleting_document}')",'resource replacement preserves deleted document state')

# Scoped read permission cannot be promoted to approval by forging actor data in the payload.
reader=str(uuid.uuid4())
sql(f"insert into kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection','{collections[0]}','user','{reader}',array['read']::kb_grant_action[],'{actor}');")
command(collections[0],'review',{'entry_id':r['entry_id'],'actor_id':actor,'expected_revision':r['revision'],'decision':'approve','candidate_id':delete_candidate['candidate_id']},as_actor=reader,error='RESOURCE_FORBIDDEN')
check(f"api.kb_resource_get('{reader}','{collections[0]}','{r['entry_id']}') is not null",'reader can inspect authorized resource')
sql(f"update kb_grants set expires_at=now()-interval '1 second' where principal_id='{reader}';")
sql(f"set role service_role; select api.kb_resource_get('{reader}','{collections[0]}','{r['entry_id']}');",error='RESOURCE_FORBIDDEN')

# Current field provenance must retain each editor, not attribute all overrides to the last one.
editor=str(uuid.uuid4())
sql(f"insert into kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection','{collections[0]}','user','{editor}',array['manage']::kb_grant_action[],'{actor}');")
provenance=create(collections[0],'provenance',{'title':'Source','organization':'Source org','report_year':2026})
provenance=mutate(collections[0],'override',provenance,fields={'title':'Editor one'})
provenance=command(collections[0],'override',{'entry_id':provenance['entry_id'],'expected_revision':provenance['revision'],'fields':{'organization':'Editor two'}},as_actor=editor)
check(f"(select field_provenance#>>'{{manual,title,actor_id}}'='{actor}' and field_provenance#>>'{{manual,organization,actor_id}}'='{editor}' from private.kb_resource_entries where id='{provenance['entry_id']}')",'manual overrides retain field-specific provenance')

# Exact serialized 64 KiB request limit: valid request at boundary, one byte over rejected.
limit_payload={'expected_revision':0,'binding_id':'catalog','external_key':'boundary','metadata':{},'reason':'x'}
base_size=int(sql('select octet_length('+quote(json.dumps(limit_payload))+'::jsonb::text);'))
limit_payload['reason']='x'*(65536-base_size+1)
command(collections[0],'upsert',limit_payload)
limit_payload['reason']+='x'
command(collections[0],'upsert',limit_payload,error='RESOURCE_PAYLOAD_INVALID')
print('PASS exact 65536/65537 JSONB request boundary',flush=True)

# Real multi-session races: same idempotency key produces exactly one result/entry.
request=str(uuid.uuid4())
payload={'expected_revision':0,'binding_id':'catalog','external_key':'race','metadata':{}}
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    outcomes=list(pool.map(lambda _: command(collections[2],'upsert',payload,request=request),range(6)))
assert all(x==outcomes[0] for x in outcomes)
check(f"(select count(*) from private.kb_resource_entries where collection_id='{collections[2]}' and external_key='race')=1",'six SQL sessions converge on one registration')
# Concurrent distinct requests with the same expected revision: only one may consume it.
x=outcomes[0]
def competing(title):
    try: return command(collections[2],'override',{'entry_id':x['entry_id'],'expected_revision':x['revision'],'fields':{'title':title}})
    except AssertionError as exc:
        assert 'RESOURCE_REVISION_CONFLICT' in str(exc); return 'conflict'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: outcomes=list(pool.map(competing,['left','right']))
assert sum(x=='conflict' for x in outcomes)==1
print('PASS concurrent CAS rejects one stale writer',flush=True)

# Different resources race for the same content hash: exactly one reservation owns it.
ready=[]
for key in ('hash-race-left','hash-race-right'):
    x=create(collections[2],key,{'title':key,'source_ref':key,'organization':'Synthetic'})
    x,cx=attach(collections[2],x,h='c'); ready.append(approve(collections[2],x,cx))
def competing_hash(x):
    try: return reserve(collections[2],x)
    except AssertionError as exc:
        assert 'RESOURCE_DOCUMENT_CONFLICT' in str(exc); return 'conflict'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: outcomes=list(pool.map(competing_hash,ready))
assert sum(x=='conflict' for x in outcomes)==1
winner=next(x for x in outcomes if x!='conflict')
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: published=list(pool.map(lambda _: publish(collections[2],winner),range(4)))
assert all(x==published[0] for x in published)
check(f"(select count(*) from kb_jobs where document_id='{winner['document_id']}')=1",'concurrent publication queues once')

# DOI matching is normalized but never infers identity from title or filename.
cid=collections[1]
j=create(cid,'doi-original',{'title':'Original','doi':'10.9999/Other'})
j2=command(cid,'upsert',{'expected_revision':j['revision'],'binding_id':'catalog','external_key':'doi-alias',
                       'metadata':{'title':'Original','doi':'https://doi.org/10.9999/OTHER'}})
assert j2['entry_id']==j['entry_id']
command(cid,'upsert',{'expected_revision':0,'binding_id':'catalog','external_key':'mode-error','legacy_ref':{'table':'journals','id':str(uuid.uuid4())}},error='RESOURCE_LEGACY_DISABLED_OR_MISMATCH')

# Versioned profile upgrades require an explicit privileged CAS rebind, preserving identity/history.
sql(f"update kb_collections set metadata_schema_json=jsonb_set(metadata_schema_json,'{{resource_profile,version}}','2') where id='{cid}';")
command(cid,'upsert',{'entry_id':j2['entry_id'],'expected_revision':j2['revision'],'binding_id':'catalog','metadata':{}},error='RESOURCE_PROFILE_CHANGED')
check(f"(api.kb_resource_get('{actor}','{cid}','{j2['entry_id']}')->>'profile_stale')::boolean",'profile change is visible and fails closed')
j2=mutate(cid,'rebind',j2)
assert j2['entry_id']==j['entry_id'] and j2['review_state']=='pending'
check(f"(api.kb_resource_get('{actor}','{cid}','{j2['entry_id']}')->'profile_json'->>'version')='2'",'profile rebind retains stable resource identity')

# Existing legacy tables are the only writable fact source. The adapter re-reads by UUID.
for table,fields,insert,change in (
 ('journals',{'title':'string','doi':'string','authors':'array','published_date':'string'},
  "insert into journals(id,title,doi,authors,date) values({id},'Synthetic legacy journal','10.9999/legacy-m1','[\"Writer\"]','2026-10-13')",
  "update journals set title='Changed legacy journal' where id={id}"),
 ('esg_meta',{'title':'string','organization':'string','report_year':'integer'},
  "insert into esg_meta(id,report_title,company_name,report_end_date) values({id},'Synthetic ESG','Synthetic company','2025-12-31')",
  "update esg_meta set report_title='Changed ESG' where id={id}"),
 ('reports',{'title':'string','organization':'array','source_ref':'string','published_date':'date'},
  "insert into reports(id,title,issuing_organization,url,release_date) values({id},'Synthetic report','[\"Synthetic\"]','fixture:report','2026-01-01')",
  "update reports set title='Changed report' where id={id}")):
    cid=str(uuid.uuid4()); row=str(uuid.uuid4())
    legacy_profile={'id':'legacy-'+table,'version':1,'metadata_mode':'legacy_ref','legacy_enabled':True,
      'legacy_table':table,'fields':fields,'required_fields':['title'],'matching':['unique_source_key'],
      'source_bindings':[{'id':'catalog','kind':'metadata-snapshot'},{'id':'drop','kind':'file-snapshot'}]}
    sql(f"insert into kb_collections(id,name,path,metadata_schema_json) values('{cid}','Synthetic legacy','m1-legacy-{table}',{quote(json.dumps({'resource_profile':legacy_profile}))});")
    sql(f"insert into kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('collection','{cid}','user','{actor}',array['manage']::kb_grant_action[],'{actor}');")
    sql(insert.format(id=quote(row)))
    x=command(cid,'upsert',{'expected_revision':0,'binding_id':'catalog','external_key':row,'legacy_ref':{'table':table,'id':row}})
    x,cx=attach(cid,x,h='d'); x=approve(cid,x,cx)
    sql(change.format(id=quote(row)))
    command(cid,'reserve',{'entry_id':x['entry_id'],'expected_revision':x['revision'],'approved_revision':x['approved_revision']},error='RESOURCE_SOURCE_CHANGED')
    x=mutate(cid,'upsert',x,binding_id='catalog'); assert x['review_state']=='pending'
    x=mutate(cid,'override',x,fields={'title':'Human legacy title'}); x=approve(cid,x,cx)
    sql(change.replace('Changed','Newest').format(id=quote(row)))
    old_approval=x['approved_revision']; x=mutate(cid,'upsert',x,binding_id='catalog')
    assert x['review_state']=='approved' and x['approved_revision']==old_approval
    check(f"(api.kb_resource_get('{actor}','{cid}','{x['entry_id']}')->'effective_metadata'->>'title')='Human legacy title'",table+' preserves human override across legacy writer refresh')
    column='report_title' if table=='esg_meta' else 'title'
    check(f"(select {column} like 'Newest%' from {table} where id='{row}')",table+' source was not overwritten by resource RPC')
    command(cid,'upsert',{'entry_id':x['entry_id'],'expected_revision':x['revision'],'binding_id':'catalog','metadata':{'title':'illegal'}},error='RESOURCE_LEGACY_READ_ONLY')

# Replaying a previously successful request after revocation must reveal no historical receipt.
sql(f"update kb_grants set revoked_at=now() where principal_id='{actor}' and resource_id='{collections[2]}';")
command(collections[2],'upsert',payload,request=request,error='RESOURCE_FORBIDDEN')
# Requests cannot exceed the 64 KiB serialized JSON boundary.
command(collections[0],'upsert',{'reason':'x'*65536,'expected_revision':0},error='RESOURCE_PAYLOAD_INVALID')
check("exists(select from kb_audit_events where action='kb.resource.review' and payload_json ? 'reason')",'actor/reason and immutable approval input audited')
print('Resource contract SQL and concurrency qualification passed.',flush=True)
