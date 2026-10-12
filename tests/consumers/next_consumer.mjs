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
  let result=await request(`${path}?q=${encodeURIComponent(f.marker)}&page=1&pageSize=10&sort=${encodeURIComponent(titleKeys[name])}&dir=asc`);
  assert.equal(result.status,200,`${name} list HTTP failed`);
  if(name==='greenDeal')assert.equal(result.data.total,0,'greenDeal policyless table must be empty');
  else assert(result.data.data.some(item=>String(item.id)===String(f.resource_ids[name])),`${name} fixture missing from authenticated search`);
  const anonymous=await request(path,'GET',undefined,false);assert.equal(anonymous.status,401,`${name} anonymous read admitted`);
  const post=await request(path,'POST',{[titleKeys[name]]:`${f.marker}deniedinsert`});
  assert(post.status>=400,`${name} read-only principal INSERT admitted`);
  const patch=await request(`${path}/${f.resource_ids[name]}`,'PATCH',{[titleKeys[name]]:`${f.marker}deniedupdate`});
  assert(patch.status>=400,`${name} read-only principal UPDATE admitted`);
  const deletion=await request(`${path}/${f.resource_ids[name]}`,'DELETE');
  assert(deletion.status>=200,'Invalid deletion response');
  assert.deepEqual(await row(table,f.resource_ids[name]),before,`${name} denied UPDATE/DELETE changed fixture`);
  const absent=await service.from(table).select('id').eq(titleKeys[name],`${f.marker}deniedinsert`);
  assert(!absent.error&&absent.data.length===0,`${name} INSERT left residue`);
  results.push({consumer:`Next resources:${name}`,passed:true,readonly_mutations_denied:true,delete_status:deletion.status});
 }
 let result=await request(`/api/kb/resources/thuHumanities?q=${encodeURIComponent(f.thu_title)}&page=1&pageSize=10`);
 assert.equal(result.status,200,'thu admin list HTTP failed');
 assert(result.data.data.some(item=>String(item.id)===String(f.thu_document_id)&&item.title===f.thu_title),'thu derived fixture missing');
 for(const [method,path] of [['POST','/api/kb/resources/thuHumanities'],['PATCH',`/api/kb/resources/thuHumanities/${f.thu_document_id}`],['DELETE',`/api/kb/resources/thuHumanities/${f.thu_document_id}`]]){
  result=await request(path,method,{title:'readonly'});assert.equal(result.status,405,'thu readonly method admitted');
 }
 results.push({consumer:'Next resources:thuHumanities',passed:true,admin_scoped_read:true,readonly_405:true});
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
