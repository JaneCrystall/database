/** Only external providers are doubled; Supabase SDK/Auth/PostgREST stay real. */
export const observations: Array<{provider: string; operation: string; value?: unknown}> = [];
export let fixture: Record<string, any> = {};
export function configure(value: Record<string, any>) { fixture = value; observations.length = 0; }
export function chunk(index: string): Record<string, any> {
  const ids = fixture.resource_ids;
  const base = {text: `synthetic content ${fixture.marker}`, page_number: 1, date: 1704067200};
  if (index === 'esg') return {...base, rec_id: ids.esg, title: fixture.marker, company_name: 'Synthetic Company', publication_date: 1704067200};
  if (index === 'standard') return {...base, rec_id: ids.standards, title: fixture.marker, standard_number: 'SYN-001', organization: 'Synthetic Organization', effective_date: 1704067200};
  if (index === 'sci') return {...base, doi: fixture.journal_doi, journal: 'SYNTHETIC JOURNAL'};
  if (index === 'edu') return {...base, rec_id: ids.education, name: fixture.edu_name, course: fixture.edu_course, chapter_number: 1};
  throw new Error('Unexpected synthetic provider index');
}
export class Client {
  constructor(_options: unknown) {}
  async search(value: any) {
    observations.push({provider: 'opensearch', operation: 'search', value});
    const metadata = chunk(value.index);
    const id = `${metadata.rec_id ?? metadata.doi}_1`;
    return {body: {hits: {hits: [{_id: id, _source: metadata}]}}};
  }
  async mget(value: unknown) { observations.push({provider:'opensearch',operation:'mget',value}); return {body:{docs:[]}}; }
  async index(value: unknown) { observations.push({provider:'opensearch',operation:'log',value}); return {body:{result:'created'}}; }
}
export function AwsSigv4Signer(_value: unknown) { return {}; }
export function defaultProvider() { return async () => ({accessKeyId:'synthetic',secretAccessKey:'synthetic'}); }
export class Pinecone {
  constructor(_options: unknown) {}
  index(_name: string) { return {namespace: (name: string) => ({query: async (value: unknown) => {
    observations.push({provider:'pinecone',operation:'query',value});
    const metadata = chunk(name);
    return {matches:[{id:`${metadata.rec_id ?? metadata.doi}_1`,score:1,metadata}]};
  }})}; }
}
export class Redis {
  constructor(_options: unknown) {}
  async exists(_key: string) { observations.push({provider:'redis',operation:'exists'}); return 0; }
  async set(_key: string, _value: unknown, _options: unknown) { return 'OK'; }
  async get(_key: string) { return null; }
  async setex(_key: string, _ttl: unknown, _value: unknown) { return 'OK'; }
}
export default class OpenAI {
  constructor(_options: unknown) {}
  responses = {create: async (_value: unknown) => {
    observations.push({provider:'openai',operation:'responses'});
    return {output_text: JSON.stringify({semantic_query:fixture.marker,lexical_query:fixture.marker,semantic_query_en:fixture.marker,lexical_query_en:fixture.marker})};
  }};
  embeddings = {create: async (_value: unknown) => {
    observations.push({provider:'openai',operation:'embedding'});
    return {data:[{embedding:[0.1,0.2,0.3]}]};
  }};
}
