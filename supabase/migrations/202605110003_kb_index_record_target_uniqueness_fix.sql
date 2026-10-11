drop index if exists public.kb_index_records_record_id_idx;

create unique index if not exists kb_index_records_active_target_record_idx
on public.kb_index_records (
  document_id,
  document_version,
  record_id,
  search_partition_id,
  opensearch_concrete_index,
  pinecone_index_name,
  pinecone_namespace
)
where deleted_at is null
  and search_partition_id is not null
  and opensearch_concrete_index is not null
  and pinecone_index_name is not null
  and pinecone_namespace is not null;

create or replace function public.enqueue_due_retry_wakeups(p_limit integer default 100)
returns table (
  job_id uuid,
  pgmq_queue text,
  next_retry_at timestamptz,
  retry_wakeup_msg_id bigint,
  enqueued boolean
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_job record;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_queue text;
  v_msg_id bigint;
  v_message_exists boolean;
begin
  for v_job in
    select j.*
    from public.kb_jobs j
    where j.status = 'failed'::public.kb_job_status
      and j.next_retry_at is not null
      and j.next_retry_at <= now()
    order by j.next_retry_at, j.priority desc, j.created_at
    limit v_limit
    for update skip locked
  loop
    v_queue := public.kb_queue_for_stage(v_job.stage);
    v_message_exists := false;

    if v_job.retry_wakeup_msg_id is not null and v_queue is not null then
      begin
        execute format(
          'select exists (select 1 from pgmq.%I where msg_id = $1)',
          'q_' || v_queue
        )
        using v_job.retry_wakeup_msg_id
        into v_message_exists;
      exception
        when undefined_table then
          v_message_exists := false;
      end;
    end if;

    if v_queue is null then
      v_msg_id := null;
    elsif v_job.retry_wakeup_msg_id is null or not v_message_exists then
      select pgmq.send(
        v_queue,
        jsonb_build_object(
          'job_id', v_job.id::text,
          'message_kind', 'retry_wakeup',
          'next_retry_at', v_job.next_retry_at
        ),
        0
      )
      into v_msg_id;

      update public.kb_jobs
      set retry_wakeup_msg_id = v_msg_id
      where id = v_job.id;
    else
      v_msg_id := v_job.retry_wakeup_msg_id;
    end if;

    job_id := v_job.id;
    pgmq_queue := v_queue;
    next_retry_at := v_job.next_retry_at;
    retry_wakeup_msg_id := v_msg_id;
    enqueued := v_queue is not null and (v_job.retry_wakeup_msg_id is null or not v_message_exists);
    return next;
  end loop;
end;
$$;
