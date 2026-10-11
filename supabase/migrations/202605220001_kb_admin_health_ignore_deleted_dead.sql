create or replace function public.get_kb_admin_health(p_actor_id uuid)
returns table (health_json jsonb)
language plpgsql
stable
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_caps record;
begin
  select *
  into v_caps
  from public.get_kb_admin_capabilities(p_actor_id)
  limit 1;

  if coalesce(v_caps.can_view_health, false) is false then
    return;
  end if;

  return query
  with health_jobs as (
    select j.*
    from public.kb_jobs j
    left join public.kb_documents d on d.id = j.document_id
    where j.status <> 'dead'::public.kb_job_status
       or d.status is distinct from 'deleted'::public.kb_document_status
  ),
  ignored_deleted_dead_jobs as (
    select j.*
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    where j.status = 'dead'::public.kb_job_status
      and d.status = 'deleted'::public.kb_document_status
  ),
  two_stage_running_parse_jobs as (
    select j.*
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    where j.stage = 'parse'::public.kb_job_stage
      and j.status = 'running'::public.kb_job_status
      and d.deleted_at is null
      and j.payload_json #>> '{two_stage,task_id}' is not null
  )
  select jsonb_build_object(
    'checked_at', now(),
    'documents_by_status', coalesce((
      select jsonb_object_agg(status::text, count)
      from (
        select status, count(*)::bigint
        from public.kb_documents
        group by status
      ) s
    ), '{}'::jsonb),
    'jobs_by_stage_status', coalesce((
      select jsonb_agg(jsonb_build_object('stage', stage, 'status', status, 'count', count))
      from (
        select stage, status, count(*)::bigint
        from health_jobs
        group by stage, status
        order by stage, status
      ) s
    ), '[]'::jsonb),
    'failed_jobs_24h', (
      select count(*)::bigint
      from health_jobs
      where status in ('failed'::public.kb_job_status, 'dead'::public.kb_job_status)
        and updated_at >= now() - interval '24 hours'
    ),
    'stale_running_jobs', (
      select count(*)::bigint
      from public.kb_jobs j
      where j.status = 'running'::public.kb_job_status
        and j.locked_until < now()
        and not exists (
          select 1
          from two_stage_running_parse_jobs t
          where t.id = j.id
            and coalesce(t.payload_json #>> '{two_stage,state}', '') not in ('SUCCESS', 'FAILURE', 'REVOKED')
        )
    ),
    'retry_backlog', jsonb_build_object(
      'due_count', (
        select count(*)::bigint
        from health_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at <= now()
      ),
      'future_count', (
        select count(*)::bigint
        from health_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at > now()
      ),
      'dead_job_count', (
        select count(*)::bigint
        from health_jobs
        where status = 'dead'::public.kb_job_status
      ),
      'oldest_due_retry_at', (
        select min(next_retry_at)
        from health_jobs
        where status = 'failed'::public.kb_job_status
          and next_retry_at <= now()
      ),
      'by_stage', coalesce((
        select jsonb_object_agg(stage::text, jsonb_build_object('due', due_count, 'future', future_count, 'dead', dead_count))
        from (
          select
            stage,
            count(*) filter (where status = 'failed'::public.kb_job_status and next_retry_at <= now())::bigint as due_count,
            count(*) filter (where status = 'failed'::public.kb_job_status and next_retry_at > now())::bigint as future_count,
            count(*) filter (where status = 'dead'::public.kb_job_status)::bigint as dead_count
          from health_jobs
          group by stage
        ) s
      ), '{}'::jsonb)
    ),
    'ignored_deleted_dead_jobs', jsonb_build_object(
      'count', (
        select count(*)::bigint
        from ignored_deleted_dead_jobs
      ),
      'by_stage', coalesce((
        select jsonb_object_agg(stage::text, count)
        from (
          select stage, count(*)::bigint
          from ignored_deleted_dead_jobs
          group by stage
          order by stage
        ) s
      ), '{}'::jsonb)
    ),
    'two_stage_running_parse_jobs', jsonb_build_object(
      'count', (
        select count(*)::bigint
        from two_stage_running_parse_jobs
      ),
      'expired_lock_count', (
        select count(*)::bigint
        from two_stage_running_parse_jobs
        where locked_until < now()
      ),
      'by_state', coalesce((
        select jsonb_object_agg(state, count)
        from (
          select coalesce(payload_json #>> '{two_stage,state}', 'UNKNOWN') as state,
                 count(*)::bigint
          from two_stage_running_parse_jobs
          group by coalesce(payload_json #>> '{two_stage,state}', 'UNKNOWN')
          order by state
        ) s
      ), '{}'::jsonb)
    ),
    'queue_depths', jsonb_build_object(
      'kb_parse_queue', public.kb_queue_depth('kb_parse_queue'),
      'kb_s3_ready_queue', public.kb_queue_depth('kb_s3_ready_queue'),
      'kb_index_queue', public.kb_queue_depth('kb_index_queue'),
      'kb_delete_queue', public.kb_queue_depth('kb_delete_queue')
    ),
    'latest_job_activity', coalesce((
      select jsonb_object_agg(stage::text, latest_updated_at)
      from (
        select stage, max(updated_at) as latest_updated_at
        from health_jobs
        group by stage
      ) s
    ), '{}'::jsonb)
  ) as health_json;
end;
$$;
