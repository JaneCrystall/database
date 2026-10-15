/** Drive the real copied Next Route Handlers over HTTP, with real Supabase SDK. */
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
process.on('uncaughtException',error=>{
 const label=error?.code==='ERR_ASSERTION'?String(error.message).split('\n')[0]:'Unexpected Next consumer execution error';
 const observed=Number.isInteger(error.actual)&&error.actual>=100&&error.actual<=599?error.actual:undefined;
 console.log(JSON.stringify({schema_version:1,failed:true,consumer:'Next',assertion:label,http_status:observed}));
 process.exitCode=1;
});
const target=JSON.parse(await readFile(process.argv[2],'utf8'));
const base=process.argv[3];
const require=createRequire(new URL('./package.json',import.meta.url));
const {createServerClient}=require('@supabase/ssr');
const {createClient}=require('@supabase/supabase-js');
const url=target.api_url??target.supabase_url;
const key=target.publishable_key??target.anon_key;
assert(url&&!url.includes('qyyqlnwqwgvzxnccnbgm')&&target.project_ref!=='qyyqlnwqwgvzxnccnbgm','Production target refused');
const service=createClient(url,target.service_role_key,{auth:{persistSession:false,autoRefreshToken:false}});
const cookieValues=new Map();
const client=createServerClient(url,key,{cookies:{getAll:()=>[...cookieValues].map(([name,value])=>({name,value})),setAll:values=>values.forEach(({name,value})=>cookieValues.set(name,value))}});
const login=await client.auth.signInWithPassword(target.user);
assert(!login.error&&login.data.session,'Synthetic Next actor login failed');
const cookie=[...cookieValues].map(([name,value])=>`${name}=${value}`).join('; ');
const f=target.fixtures;
const tables={education:'edu_meta',esg:'esg_meta',standards:'standards',reports:'reports',internalUse:'internal_use',greenDeal:'green_deal_meta'};
const titleKeys={education:'name',esg:'report_title',standards:'title',reports:'title',internalUse:'title',greenDeal:'title'};
const results=[];
async function request(path,method='GET',body,authenticated=true){
 const response=await fetch(base+path,{method,headers:{...(authenticated?{cookie}:{}),'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
 const data=await response.json();return {status:response.status,data};
}
async function row(table,id){const result=await service.from(table).select('*').eq('id',id).single();assert(!result.error,'Fixture readback failed');return result.data;}
try {
 for(const [name,table] of Object.entries(tables)){
  const path=`/api/kb/resources/${name}`;
  const before=await row(table,f.resource_ids[name]);
  async function assertUnchanged(){
   assert.deepEqual(await row(table,f.resource_ids[name]),before,`${name} denied request changed fixture`);
   const absent=await service.from(table).select('id').eq(titleKeys[name],`${f.marker}deniedinsert`);
   assert(!absent.error&&absent.data.length===0,`${name} INSERT left residue`);
  }
  let result=await request(`${path}?q=${encodeURIComponent(f.marker)}&page=1&pageSize=10&sort=${encodeURIComponent(titleKeys[name])}&dir=asc`);
  assert.equal(result.status,200,`${name} list HTTP failed`);
  if(name==='greenDeal')assert.equal(result.data.total,0,'greenDeal policyless table must be empty');
  else assert(result.data.data.some(item=>String(item.id)===String(f.resource_ids[name])),`${name} fixture missing from authenticated search`);
  const anonymous=await request(path,'GET',undefined,false);assert.equal(anonymous.status,401,`${name} anonymous read admitted`);
  const post=await request(path,'POST',{[titleKeys[name]]:`${f.marker}deniedinsert`});
  assert.equal(post.status,403,`${name} INSERT must return forbidden`);
  await assertUnchanged();
  const patch=await request(`${path}/${f.resource_ids[name]}`,'PATCH',{[titleKeys[name]]:`${f.marker}deniedupdate`});
  assert.equal(patch.status,403,`${name} UPDATE must return forbidden`);
  await assertUnchanged();
  const deletion=await request(`${path}/${f.resource_ids[name]}`,'DELETE');
  assert.equal(deletion.status,403,`${name} DELETE must return forbidden`);
  await assertUnchanged();
  for(const denied of [post,patch,deletion]){
   assert.deepEqual(denied.data,{error:'Resource permission denied.'},`${name} permission response must be safe`);
  }
  for(const [method,endpoint] of [['POST',path],['PATCH',`${path}/${f.resource_ids[name]}`],['DELETE',`${path}/${f.resource_ids[name]}`]]){
   const denied=await request(endpoint,method,{[titleKeys[name]]:`${f.marker}deniedinsert`},false);
   assert.equal(denied.status,401,`${name} anonymous mutation must require authentication`);
   assert.deepEqual(denied.data,{error:'Authentication required.'},`${name} anonymous response must be safe`);
   await assertUnchanged();
  }
  results.push({consumer:`Next resources:${name}`,passed:true,readonly_mutations_denied:true,post_status:post.status,patch_status:patch.status,delete_status:deletion.status,anonymous_mutations_status:401,safe_errors:true,unchanged_rows:true});
 }
 let result=await request(`/api/kb/resources/thuHumanities?q=${encodeURIComponent(f.thu_title)}&page=1&pageSize=10`);
 assert.equal(result.status,200,'thu admin list HTTP failed');
 assert(result.data.data.some(item=>String(item.id)===String(f.thu_document_id)&&item.title===f.thu_title),'thu derived fixture missing');
 for(const [method,path] of [['POST','/api/kb/resources/thuHumanities'],['PATCH',`/api/kb/resources/thuHumanities/${f.thu_document_id}`],['DELETE',`/api/kb/resources/thuHumanities/${f.thu_document_id}`]]){
  result=await request(path,method,{title:'readonly'});assert.equal(result.status,405,'thu readonly method admitted');
 }
 results.push({consumer:'Next resources:thuHumanities',passed:true,admin_scoped_read:true,readonly_405:true});
 // S9: actual API-key management service calls retain create/list/rotate/revoke.
 const keyPath='/api/kb/admin/api-keys';
 const created=await request(keyPath,'POST',{name:'S9 synthetic',client_id:f.marker,scopes:['kb:read'],collection_scope:[]});
 assert.equal(created.status,200,'API-key create failed');
 const first=created.data.apiKey.id;
 let second;
 try {
  assert(!JSON.stringify(created.data.apiKey).includes('token_hash'),'API-key metadata leaks hash');
  const listed=await request(keyPath);
  assert.equal(listed.status,200,'API-key list failed');
  assert(listed.data.data.some(x=>x.id===first),'Created API-key missing');
  const rotated=await request(`${keyPath}/${first}/rotate`,'POST',{});
  assert.equal(rotated.status,200,'API-key rotate failed');
  second=rotated.data.apiKey.id;
  assert(second!==first,'Rotation did not create replacement');
  const revoked=await request(`${keyPath}/${second}/revoke`,'POST',{reason:'S9 synthetic cleanup'});
  assert.equal(revoked.status,200,'API-key revoke failed');
  assert(revoked.data.revoked,'API-key not revoked');
  results.push({consumer:'Next API-key lifecycle',passed:true});
 }finally{
  const deleted=await service.from('kb_api_keys').delete().in('id',[first,second].filter(Boolean));
  assert(!deleted.error,'API-key fixture cleanup failed');
 }
 const docs=[crypto.randomUUID(),crypto.randomUUID()];
 const jobIds=[crypto.randomUUID(),crypto.randomUUID()];
 try {
  for(let i=0;i<2;i++) {
   const inserted=await service.from('kb_documents').insert({id:docs[i],primary_collection_id:f.thu_collection_id,dedupe_scope:docs[i],original_filename:'s9-next.pdf',file_ext:'pdf',sha256:'a'.repeat(64),created_by:target.user.id,owner_user_id:target.user.id});
   assert(!inserted.error,'Worker document fixture failed');
   const seeded=await service.from('kb_jobs').insert({id:jobIds[i],document_id:docs[i],document_version:1,stage:i===0?'index':'delete',status:'running',locked_by:'s9-next',locked_until:new Date(Date.now()+300000).toISOString()});
   assert(!seeded.error,'Worker job fixture failed');
  }
  const workers=await request('/api/s9-workers','POST',{indexJob:jobIds[0],deleteJob:jobIds[1],documentId:docs[0]});
  assert.equal(workers.status,200,'Next worker adapters failed');
  assert.equal(workers.data.failedIndex.status,'dead','Index fail callback changed');
  assert.equal(workers.data.failedDelete,'dead','Delete fail callback changed');
  assert.deepEqual(workers.data.records,[],'Index ledger read changed');
  results.push({consumer:'Next actual index and delete adapters',passed:true});
 }finally{
  const jobsClean=await service.from('kb_jobs').delete().in('id',jobIds);assert(!jobsClean.error,'Worker jobs cleanup failed');
  const docsClean=await service.from('kb_documents').delete().in('id',docs);assert(!docsClean.error,'Worker documents cleanup failed');
 }
 const jobs=await request('/api/kb/admin/jobs?page=1&pageSize=10');
 assert.equal(jobs.status,200,'Next Jobs service RPC failed');
 results.push({consumer:'Next Jobs',passed:true});
 if(target.outsider){
  await client.auth.signOut();
  const outsider=await client.auth.signInWithPassword(target.outsider);
  assert(!outsider.error&&outsider.data.session,'Synthetic outsider login failed');
  const outsiderCookie=[...cookieValues].map(([name,value])=>`${name}=${value}`).join('; ');
  const denied=await fetch(base+'/api/kb/resources/thuHumanities',{headers:{cookie:outsiderCookie}});
  assert.equal(denied.status,403,'thu outsider without capabilities was admitted');
  results.push({consumer:'Next resources:thuHumanities-outsider',passed:true,status:403});
 }
 console.log(JSON.stringify({schema_version:1,runtime:'Next exact Route Handlers + real HTTP/Auth/PostgREST',mode:target.mode,results}));
}finally{await client.auth.signOut();}
