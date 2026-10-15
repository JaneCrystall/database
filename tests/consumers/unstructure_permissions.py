#!/usr/bin/env python3
"""Execute unchanged Unstructure adapters using a disposable local service role."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import uuid
from runtime import load_private, validate_target

root=Path(__file__).resolve().parents[3]
source=root/'unstructure/src/kb_parse_worker/control_plane.py'
target=load_private(Path(sys.argv[1])); validate_target(target)
assert target['mode']=='local', 'Local only; fixtures are removed with the owned stack'
spec=importlib.util.spec_from_file_location('s9_control_plane',source)
cp=importlib.util.module_from_spec(spec); sys.modules[spec.name]=cp; spec.loader.exec_module(cp)
conn=cp.connect(target['db_url'])
cid,actor=str(uuid.uuid4()),str(uuid.uuid4())
def sql(query,args=()):
    with conn.cursor() as cur:
        cur.execute(query,args)
        row=cur.fetchone() if cur.description else None
    conn.commit()
    return row
sql("insert into public.kb_collections(id,name,path) values(%s,'S9 adapter',%s)",(cid,'/s9-adapter/'+cid))
def fixture():
    doc,job=str(uuid.uuid4()),str(uuid.uuid4())
    sql("insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,sha256,created_by,owner_user_id,status) values(%s,%s,%s,'s9-adapter.pdf','pdf',%s,%s,%s,'parse_queued')",(doc,cid,doc,'a'*64,actor,actor))
    sql("insert into public.kb_jobs(id,document_id,document_version,stage,status,locked_by,locked_until) values(%s,%s,1,'parse','running','s9-adapter',now()+interval '5 minutes')",(job,doc))
    return doc,job
try:
    doc,job=fixture(); msg=sql("select pgmq.send('kb_parse_queue',jsonb_build_object('job_id',%s))",(job,))[0]
    sql('set role service_role')
    assert cp.register_parse_two_stage_task(conn,job,'s9-adapter','s9-task','http://synthetic.invalid/task','http://synthetic.invalid/status','kb_parse_queue',msg,300,{}).job_id==job
    assert cp.claim_parse_two_stage_task(conn,'s9-adapter',300).job_id==job
    assert cp.mark_parse_two_stage_task_state(conn,job,'s9-adapter','STARTED',None,300)
    artifact=str(uuid.uuid4())
    assert cp.mark_parse_local_ready(conn,job,'s9-adapter',doc,1,'nas://synthetic/adapter',artifact,'b'*64,1,{})
    assert cp.mark_processed_s3_ready(conn,job,'s9-adapter',doc,1,'synthetic/adapter','b'*64,artifact,'nas://synthetic/adapter',1)
    sql('reset role'); doc,job=fixture(); sql('set role service_role')
    assert cp.fail_job(conn,job,'s9-adapter',False,'synthetic').job_status=='dead'
    assert cp.replay_parse_local_ready_from_artifact(conn,job,'s9-repair',doc,1,'nas://synthetic/replay',str(uuid.uuid4()),'c'*64,1,{}, {},'S9 qualification').parse_job_status=='succeeded'
    print(json.dumps({'consumer':'Unstructure seven actual adapters','passed':True,'role':'service_role','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'cleanup':'owned local stack stop'}))
finally:
    conn.close()
