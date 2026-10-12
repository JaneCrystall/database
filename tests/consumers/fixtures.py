#!/usr/bin/env python3
"""Synthetic consumer fixtures for an explicitly validated local/preview target."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import sys
from urllib.error import HTTPError
from urllib.request import Request,urlopen
import uuid
try:
    from .runtime import load_private,private_json,validate_target
except ImportError:  # Direct script entrypoint.
    from runtime import load_private,private_json,validate_target


def auth_request(target,method,path,body=None,*,allow_missing=False):
    validate_target(target)
    request=Request(target['api_url']+'/auth/v1/'+path,method=method,
        headers={'apikey':target['service_role_key'],'Authorization':'Bearer '+target['service_role_key'],'Content-Type':'application/json'},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urlopen(request,timeout=30) as response:
            raw=response.read()
            return json.loads(raw) if raw else {}
    except HTTPError as error:
        if allow_missing and method=='DELETE' and path.startswith('admin/users/') and error.code==404:
            return {'already_absent':True}
        raise RuntimeError(f'Synthetic Auth operation failed with HTTP {error.code}; response withheld') from None


def setup(path):
    target=load_private(path);validate_target(target)
    import psycopg2
    from psycopg2.extras import Json
    if 'fixtures' in target:raise RuntimeError('Fixture manifest already exists; clean it before a new run')
    run=target['run_id'];marker='synthetic'+run
    uid=lambda:str(uuid.uuid4())
    resource_ids={name:uid() for name in ('education','esg','standards','reports','internalUse','greenDeal')}
    fixtures={'marker':marker,'resource_ids':resource_ids,'edu_secondary_id':uid(),'edu_course':marker+'course',
      'edu_secondary_course':marker+'other','edu_name':marker,'esg_meta_query':marker,'standard_meta_query':marker,
      'journal_id':uid(),'journal_doi':'10.99999/'+run+'-edge','journal_title':marker+'journal',
      'journal_authors':['Synthetic Author One','Synthetic Author Two'],'textbook_id':uid(),
      'country_code':'SYN','category_code':'SYN001','thu_collection_id':uid(),'thu_document_id':uid(),
      'thu_grant_id':uid(),'thu_title':marker+'humanities','user_role_id':uid()}
    target['fixtures']=fixtures;target['fixture_users']=[];private_json(path,target)
    try:
        for name in ('user','outsider'):
            user={'email':f'{name}-{run}@example.invalid','password':secrets.token_urlsafe(28)}
            result=auth_request(target,'POST','admin/users',{'email':user['email'],'password':user['password'],'email_confirm':True})
            user['id']=result['id'];target[name]=user;target['fixture_users'].append(user['id']);private_json(path,target)
        with psycopg2.connect(target['db_url'],connect_timeout=15) as conn:
            with conn.cursor() as cur:
                cur.execute("set local statement_timeout='20s'")
                cur.execute('insert into public.esg_country(code,name) values(%s,%s)',(fixtures['country_code'],marker+'country'))
                cur.execute('insert into public.esg_category(code,name) values(%s,%s)',(fixtures['category_code'],marker+'category'))
                cur.execute('insert into public.edu_meta(id,name,course,type,language,file_type,chapter_number,description,upload_time) values(%s,%s,%s,%s,%s,%s,%s,%s,now()),(%s,%s,%s,%s,%s,%s,%s,%s,now())',
                    (resource_ids['education'],marker,fixtures['edu_course'],'lecture','eng','pdf',1,marker+'description',
                     fixtures['edu_secondary_id'],marker+'second',fixtures['edu_secondary_course'],'textbook','chi_sim','pdf',2,marker+'second'))
                cur.execute('insert into public.edu_textbooks(id,title,authors,isbn_number,category,language) values(%s,%s,%s,%s,%s,%s)',(fixtures['textbook_id'],marker,Json(['Synthetic Author']),'9780000000000',Json(['Synthetic']),'eng'))
                cur.execute('insert into public.esg_meta(id,report_title,company_name,company_name_en,country,language,category_new,report_url,publication_date,uploaded_time) values(%s,%s,%s,%s,%s,%s,%s,%s,now(),now())',
                    (resource_ids['esg'],marker,marker+'company',marker+'company',fixtures['country_code'],'eng',Json([marker]),'https://example.invalid/'+run))
                cur.execute('insert into public.standards(id,title,standard_number,issuing_organization,language,url,effective_date,uploaded_time) values(%s,%s,%s,%s,%s,%s,now(),now())',
                    (resource_ids['standards'],marker,marker+'standard',Json([marker+'issuer']),'eng','https://example.invalid/'+run))
                cur.execute('insert into public.reports(id,title,issuing_organization,language,url,release_date,uploaded_time) values(%s,%s,%s,%s,%s,now(),now())',
                    (resource_ids['reports'],marker,Json([marker+'issuer']),'eng','https://example.invalid/'+run))
                cur.execute('insert into public.internal_use(id,title,tag,language,file_type,uploaded_time) values(%s,%s,%s,%s,%s,now())', (resource_ids['internalUse'],marker,marker+'tag','eng','pdf'))
                cur.execute('insert into public.green_deal_meta(id,title,celex_number,form,issue_agency,authors,publish_date,upload_time) values(%s,%s,%s,%s,%s,%s,now(),now())',
                    (resource_ids['greenDeal'],marker,marker+'celex','synthetic',marker+'agency','Synthetic Author'))
                cur.execute('insert into public.journals(id,doi,title,journal,authors,date,abstract) values(%s,%s,%s,%s,%s,%s,%s)',
                    (fixtures['journal_id'],fixtures['journal_doi'],fixtures['journal_title'],marker+'journal',Json(fixtures['journal_authors']),'2026-01-01','Synthetic existing abstract; preserve.'))
                cur.execute('insert into public.kb_collections(id,name,path,content_type) values(%s,%s,%s,%s)',
                    (fixtures['thu_collection_id'],marker,'/course/thu_humanities/'+marker,'synthetic'))
                cur.execute('insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,sha256,created_by,owner_user_id,metadata_json) values(%s,%s,%s,%s,%s,%s,%s,%s,%s)',
                    (fixtures['thu_document_id'],fixtures['thu_collection_id'],marker,marker+'.pdf','pdf',hashlib.sha256(marker.encode()).hexdigest(),target['user']['id'],target['user']['id'],Json({'title':fixtures['thu_title'],'path_2':'Synthetic Faculty','path_3':'Synthetic Course'})))
                cur.execute("insert into public.kb_grants(id,resource_type,resource_id,principal_type,principal_id,actions,created_by) values(%s,'collection',%s,'user',%s,array['manage'::public.kb_grant_action],%s)",
                    (fixtures['thu_grant_id'],fixtures['thu_collection_id'],target['user']['id'],target['user']['id']))
                cur.execute('insert into public.user_roles(id,user_id,role) values(%s,%s,%s)',(fixtures['user_role_id'],target['user']['id'],'synthetic_reader'))
        target['fixture_state']='ready';private_json(path,target)
        print(json.dumps({'status':'ready','run_id':run,'synthetic_users':2,'resource_categories':6}))
    except Exception:
        cleanup(path)
        raise


def cleanup(path):
    target=load_private(path);validate_target(target)
    import psycopg2
    from psycopg2 import sql
    f=target.get('fixtures',{});ids=f.get('resource_ids',{})
    if f:
        with psycopg2.connect(target['db_url'],connect_timeout=15) as conn:
            with conn.cursor() as cur:
                cur.execute("set local statement_timeout='20s'")
                for table,key in [('kb_grants','thu_grant_id'),('kb_documents','thu_document_id'),('kb_collections','thu_collection_id'),('user_roles','user_role_id'),('journals','journal_id'),('edu_textbooks','textbook_id')]:
                    cur.execute(sql.SQL('delete from public.{} where id=%s').format(sql.Identifier(table)),(f.get(key),))
                    cur.execute(sql.SQL('select count(*) from public.{} where id=%s').format(sql.Identifier(table)),(f.get(key),));assert cur.fetchone()[0]==0
                for name,table in [('education','edu_meta'),('esg','esg_meta'),('standards','standards'),('reports','reports'),('internalUse','internal_use'),('greenDeal','green_deal_meta')]:
                    cur.execute(sql.SQL('delete from public.{} where id=%s').format(sql.Identifier(table)),(ids.get(name),))
                    cur.execute(sql.SQL('select count(*) from public.{} where id=%s').format(sql.Identifier(table)),(ids.get(name),));assert cur.fetchone()[0]==0
                cur.execute('delete from public.edu_meta where id=%s',(f.get('edu_secondary_id'),))
                cur.execute('select count(*) from public.edu_meta where id=%s',(f.get('edu_secondary_id'),));assert cur.fetchone()[0]==0
                cur.execute('delete from public.esg_category where code=%s and name=%s',(f.get('category_code'),f['marker']+'category'))
                cur.execute('delete from public.esg_country where code=%s and name=%s',(f.get('country_code'),f['marker']+'country'))
        for user_id in target.get('fixture_users',[]):auth_request(target,'DELETE','admin/users/'+user_id,allow_missing=True)
    target['fixture_state']='cleaned';private_json(path,target)
    print(json.dumps({'status':'cleaned','run_id':target['run_id']}))


def main():
    p=argparse.ArgumentParser();p.add_argument('operation',choices=['setup','cleanup']);p.add_argument('--target',type=Path,required=True);a=p.parse_args()
    (setup if a.operation=='setup' else cleanup)(a.target)
if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('Fixture operation failed: '+type(exc).__name__+'; target and diagnostics withheld.',file=sys.stderr);raise SystemExit(1)
