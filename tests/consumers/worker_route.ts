/** Test-only local route: invokes unchanged worker adapters, no external indexes. */
import { SupabaseIndexWorkerStore } from '@/lib/kb/index-worker-supabase';
import { SupabaseDeleteWorkerStore } from '@/lib/kb/delete-worker-supabase';
export async function POST(request: Request) {
  const {indexJob, deleteJob, documentId} = await request.json();
  const index = new SupabaseIndexWorkerStore();
  const deletion = new SupabaseDeleteWorkerStore();
  const records = await index.listActiveIndexRecords({documentId});
  const partitions = await index.listActiveSearchPartitions();
  const failedIndex = await index.failJob({jobId:indexJob,workerId:'s9-next',retryable:false,error:'synthetic'});
  const failedDelete = await deletion.failJob({jobId:deleteJob,workerId:'s9-next',retryable:false,error:'synthetic'});
  return Response.json({records,partitionCount:partitions.length,failedIndex,failedDelete});
}
