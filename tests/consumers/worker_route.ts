/** Test-only local route: invokes unchanged worker adapters, no external indexes. */
import { SupabaseIndexWorkerStore } from '@/lib/kb/index-worker-supabase';
import { SupabaseDeleteWorkerStore } from '@/lib/kb/delete-worker-supabase';
import { runIndexWorkerOnce } from '@/lib/kb/index-worker';
import { runDeleteWorkerOnce } from '@/lib/kb/delete-worker';
export async function POST(request: Request) {
  const {indexJob, deleteJob, documentId, action, collectionId, artifactId, fault} = await request.json();
  const index = new SupabaseIndexWorkerStore();
  const deletion = new SupabaseDeleteWorkerStore();
  if (action) {
    // External artifact/index transports are doubles. Stores, orchestration,
    // lease checks, record ledger, completion and queue archival stay real.
    const artifacts = {
      async readManifest() { return {document_id:documentId,document_version:1,
        artifact_uuid:artifactId,collection_id:collectionId,collection_path:'/s9-flow',
        chunk_count:1,artifacts:{chunks_pkl:'synthetic.pkl'}}; },
      async readChunks() { return [{chunkId:'synthetic-chunk',chunkIndex:0,
        text:'Synthetic S9 worker',pageNumber:1,embedding:[1,0,0],metadata:{}}]; },
    };
    const options = {workerId:'s9-next-flow',batchSize:1,lockSeconds:30,
      visibilityTimeoutSeconds:30,heartbeatIntervalMs:1000,jobTimeoutMs:15000};
    const effects: string[] = [];
    if (action === 'index') {
      const result = await runIndexWorkerOnce({store:index,artifacts,target:{
        async write(records) {
          if (fault) throw new Error('synthetic transport unavailable');
          effects.push(...records.map(record=>record.id));
          return {opensearchCount:records.length,pineconeCount:records.length};
        },
        async delete(records) { return records.length; },
      }},options);
      return Response.json({result,effects});
    }
    if (action === 'delete') {
      const result = await runDeleteWorkerOnce({store:deletion,artifacts,target:{
        async cleanup(_snapshot,recordIds) {
          if (fault) throw new Error('synthetic cleanup unavailable');
          effects.push(...recordIds);
          return {recordIds,opensearchDeleted:recordIds.length,pineconeDeleted:recordIds.length,
            s3Deleted:1,localDeleted:[],skipped:[]};
        },
      }},options);
      return Response.json({result,effects});
    }
    return Response.json({error:'unknown test action'},{status:400});
  }
  const records = await index.listActiveIndexRecords({documentId});
  const partitions = await index.listActiveSearchPartitions();
  const failedIndex = await index.failJob({jobId:indexJob,workerId:'s9-next',retryable:false,error:'synthetic'});
  const failedDelete = await deletion.failJob({jobId:deleteJob,workerId:'s9-next',retryable:false,error:'synthetic'});
  return Response.json({records,partitionCount:partitions.length,failedIndex,failedDelete});
}
