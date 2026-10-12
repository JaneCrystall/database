/** Execute unchanged Edge handlers under Deno with real HTTP/Auth/PostgREST. */
import {configure, observations} from './external_mocks/providers.ts';

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
const target = JSON.parse(await Deno.readTextFile(Deno.args[0]));
const url = target.api_url ?? target.supabase_url;
const key = target.publishable_key ?? target.anon_key;
assert(url && key && target.user && target.fixtures, 'Incomplete consumer target');
assert(!url.includes('qyyqlnwqwgvzxnccnbgm') && target.project_ref!=='qyyqlnwqwgvzxnccnbgm', 'Production target refused');
configure(target.fixtures);
for (const [name, value] of Object.entries({
  REMOTE_SUPABASE_URL:url, REMOTE_SUPABASE_PUBLISHABLE_KEY:key,
  SUPABASE_URL:url,SUPABASE_PUBLISHABLE_KEY:key,
  OPENAI_API_KEY:'synthetic',OPENAI_EMBEDDING_MODEL:'synthetic',
  PINECONE_API_KEY_US_EAST_1:'synthetic',PINECONE_INDEX_NAME:'synthetic',
  PINECONE_NAMESPACE_EDU:'edu',PINECONE_NAMESPACE_ESG:'esg',
  PINECONE_NAMESPACE_STANDARD:'standard',PINECONE_NAMESPACE_SCI:'sci',
  OPENSEARCH_REGION:'synthetic',OPENSEARCH_DOMAIN:'http://127.0.0.1:1',
  OPENSEARCH_EDU_INDEX_NAME:'edu',OPENSEARCH_ESG_INDEX_NAME:'esg',
  OPENSEARCH_STANDARD_INDEX_NAME:'standard',OPENSEARCH_SCI_INDEX_NAME:'sci',
  UPSTASH_REDIS_URL:'http://127.0.0.1:1',UPSTASH_REDIS_TOKEN:'synthetic',
  EMAIL_AUTH_L1_ENABLED:'false',
})) Deno.env.set(name,String(value));

const originalServe = Deno.serve;
const handlers = new Map<string,(request: Request)=>Response|Promise<Response>>();
let loading = '';
(Deno as any).serve = (handler: any) => {
  handlers.set(loading,handler);
  return {finished:Promise.resolve(),shutdown:async()=>{}};
};
for (const name of ['edu_search','esg_search','standard_search','sci_search']) {
  loading=name;
  await import(new URL(`./functions/${name}/index.ts`,import.meta.url).href);
}
(Deno as any).serve = originalServe;
const server = originalServe({hostname:'127.0.0.1',port:0,onListen:()=>{}},async request=>{
  const handler=handlers.get(new URL(request.url).pathname.slice(1));
  if (!handler) return new Response('not found',{status:404});
  try {return await handler(request);} catch (_) {return Response.json({error:'handler failed'},{status:500});}
});
const base=`http://127.0.0.1:${server.addr.port}`;
const results: Array<Record<string,unknown>>=[];
async function request(name:string,body:unknown,authorized=true) {
  const response=await fetch(`${base}/${name}`,{method:'POST',headers:{'content-type':'application/json',
    email:target.user.email,password:authorized?target.user.password:'synthetic-invalid-password'},body:JSON.stringify(body)});
  const text=await response.text();
  let data;try{data=JSON.parse(text);}catch(_){data=null;}
  return {status:response.status,data};
}
try {
  const fixture=target.fixtures;
  let response=await request('edu_search',{action:'list_filter_options',fields:['course','name','chapter_number'],filter:{course:[fixture.edu_course]}});
  assert(response.status===200,'edu facet authenticated HTTP failed');
  assert(response.data.matched_records>=1,'edu facet returned no synthetic records');
  assert(response.data.options.name.some((item:any)=>item.value===fixture.edu_name),'edu facet name does not include synthetic fixture');
  assert(response.data.options.course.some((item:any)=>item.value===fixture.edu_course),'edu facet course mismatch');
  results.push({consumer:'edu_search:list_filter_options',passed:true});
  response=await request('edu_search',{action:'list_filter_options'},false);
  assert(response.status===401,'edu invalid credentials did not fail');
  results.push({consumer:'edu_search:unauthorized',passed:true});
  for (const [name,index,meta] of [['esg_search','esg',fixture.esg_meta_query],['standard_search','standard',fixture.standard_meta_query]]) {
    observations.length=0;
    response=await request(name,{query:fixture.marker,meta_contains:meta,topK:2,extK:0});
    assert(response.status===200 && Array.isArray(response.data) && response.data.length>0,`${name} nonempty real handler HTTP failed`);
    assert(JSON.stringify(response.data).includes(fixture.marker),`${name} result lacks synthetic content`);
    const search=observations.find(item=>item.provider==='opensearch'&&item.operation==='search')?.value as any;
    const expected=index==='esg'?fixture.resource_ids.esg:fixture.resource_ids.standards;
    assert(JSON.stringify(search?.body?.query?.bool?.filter).includes(expected),`${name} actual RPC ids not used in external filter`);
    assert(observations.some(item=>item.operation==='embedding'),`${name} skipped embedding code`);
    results.push({consumer:name,passed:true,real_database_metadata_filter:true});
    observations.length=0;
    response=await request(name,{query:fixture.marker,meta_contains:`${fixture.marker}nomatch`,topK:2,extK:0});
    assert(response.status===200 && response.data?.message==='No records found matching the metadata filters.',`${name} real metadata no-match did not stop search`);
    assert(!observations.some(item=>item.operation==='search'||item.operation==='query'),`${name} no-match still queried external index`);
    results.push({consumer:`${name}:metadata-no-match`,passed:true});
  }
  observations.length=0;
  response=await request('sci_search',{query:fixture.marker,topK:2,extK:0,getMeta:true});
  assert(response.status===200 && Array.isArray(response.data) && response.data.length>0,'sci nonempty real handler HTTP failed');
  const rendered=JSON.stringify(response.data);
  assert(rendered.includes(fixture.journal_title)&&rendered.includes(fixture.journal_doi),'sci did not hydrate title/DOI from real journal');
  for (const author of fixture.journal_authors) assert(rendered.includes(author),'sci journal author missing');
  results.push({consumer:'sci_search:getMeta',passed:true,real_database_hydration:true});
  console.log(JSON.stringify({schema_version:1,runtime:'Deno exact Edge source + local HTTP; external SDK doubles only',mode:target.mode,results}));
} finally {await server.shutdown();}
