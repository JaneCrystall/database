alter type public.kb_job_stage add value if not exists 's3_ready';

do $$
begin
  if not exists (select 1 from pgmq.meta where queue_name = 'kb_s3_ready_queue') then
    perform pgmq.create('kb_s3_ready_queue');
  end if;
end $$;

alter table if exists pgmq.q_kb_s3_ready_queue enable row level security;
alter table if exists pgmq.a_kb_s3_ready_queue enable row level security;
