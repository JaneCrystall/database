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
  with document_status_rollup as materialized (
    select
      d.status,
      count(*)::bigint as document_count
    from public.kb_documents d
    group by d.status
  ),
  two_stage_jobs as materialized (
    select
      j.id,
      coalesce(j.payload_json #>> '{two_stage,state}', 'UNKNOWN') as state,
      coalesce(j.payload_json #>> '{two_stage,state}', '') not in (
        'SUCCESS',
        'FAILURE',
        'REVOKED'
      ) as is_active
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    where j.stage = 'parse'::public.kb_job_stage
      and j.status = 'running'::public.kb_job_status
      and d.deleted_at is null
      and j.payload_json #>> '{two_stage,task_id}' is not null
  ),
  job_source as not materialized (
    select
      j.stage,
      j.status,
      j.updated_at,
      j.next_retry_at,
      j.locked_until,
      (
        j.status <> 'dead'::public.kb_job_status
        or d.status is distinct from 'deleted'::public.kb_document_status
      ) as health_included,
      (
        j.status = 'dead'::public.kb_job_status
        and d.status = 'deleted'::public.kb_document_status
      ) as ignored_deleted_dead,
      t.id is not null as is_two_stage_running_parse,
      coalesce(t.is_active, false) as is_active_two_stage_running_parse
    from public.kb_jobs j
    left join public.kb_documents d on d.id = j.document_id
    left join two_stage_jobs t on t.id = j.id
  ),
  job_rollup as materialized (
    select
      s.stage,
      s.status,
      s.health_included,
      s.ignored_deleted_dead,
      count(*)::bigint as job_count,
      count(*) filter (
        where s.health_included
          and s.status in (
            'failed'::public.kb_job_status,
            'dead'::public.kb_job_status
          )
          and s.updated_at >= now() - interval '24 hours'
      )::bigint as failed_jobs_24h_count,
      count(*) filter (
        where s.health_included
          and s.status = 'failed'::public.kb_job_status
          and s.next_retry_at <= now()
      )::bigint as retry_due_count,
      count(*) filter (
        where s.health_included
          and s.status = 'failed'::public.kb_job_status
          and s.next_retry_at > now()
      )::bigint as retry_future_count,
      count(*) filter (
        where s.health_included
          and s.status = 'dead'::public.kb_job_status
      )::bigint as dead_job_count,
      min(s.next_retry_at) filter (
        where s.health_included
          and s.status = 'failed'::public.kb_job_status
          and s.next_retry_at <= now()
      ) as oldest_due_retry_at,
      count(*) filter (
        where s.status = 'running'::public.kb_job_status
          and s.locked_until < now()
          and not s.is_active_two_stage_running_parse
      )::bigint as stale_running_count,
      count(*) filter (
        where s.is_two_stage_running_parse
      )::bigint as two_stage_count,
      count(*) filter (
        where s.is_two_stage_running_parse
          and s.locked_until < now()
      )::bigint as two_stage_expired_lock_count,
      max(s.updated_at) filter (
        where s.health_included
      ) as latest_updated_at
    from job_source s
    group by
      s.stage,
      s.status,
      s.health_included,
      s.ignored_deleted_dead
  ),
  job_stage_status_rollup as materialized (
    select
      r.stage,
      r.status,
      sum(r.job_count)::bigint as job_count
    from job_rollup r
    where r.health_included
    group by r.stage, r.status
  ),
  job_stage_rollup as materialized (
    select
      r.stage,
      coalesce(sum(r.job_count) filter (where r.health_included), 0)::bigint as health_job_count,
      coalesce(sum(r.retry_due_count), 0)::bigint as retry_due_count,
      coalesce(sum(r.retry_future_count), 0)::bigint as retry_future_count,
      coalesce(sum(r.dead_job_count), 0)::bigint as dead_job_count,
      coalesce(sum(r.job_count) filter (where r.ignored_deleted_dead), 0)::bigint as ignored_deleted_dead_count,
      max(r.latest_updated_at) as latest_updated_at
    from job_rollup r
    group by r.stage
  ),
  two_stage_state_rollup as materialized (
    select
      t.state,
      count(*)::bigint as job_count
    from two_stage_jobs t
    group by t.state
  ),
  job_totals as (
    select
      coalesce(sum(r.failed_jobs_24h_count), 0)::bigint as failed_jobs_24h_count,
      coalesce(sum(r.stale_running_count), 0)::bigint as stale_running_count,
      coalesce(sum(r.retry_due_count), 0)::bigint as retry_due_count,
      coalesce(sum(r.retry_future_count), 0)::bigint as retry_future_count,
      coalesce(sum(r.dead_job_count), 0)::bigint as dead_job_count,
      min(r.oldest_due_retry_at) as oldest_due_retry_at,
      coalesce(sum(r.job_count) filter (where r.ignored_deleted_dead), 0)::bigint as ignored_deleted_dead_count,
      coalesce(sum(r.two_stage_count), 0)::bigint as two_stage_count,
      coalesce(sum(r.two_stage_expired_lock_count), 0)::bigint as two_stage_expired_lock_count
    from job_rollup r
  )
  select jsonb_build_object(
    'checked_at', now(),
    'documents_by_status', coalesce((
      select jsonb_object_agg(d.status::text, d.document_count)
      from document_status_rollup d
    ), '{}'::jsonb),
    'jobs_by_stage_status', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'stage', r.stage,
          'status', r.status,
          'count', r.job_count
        )
        order by r.stage, r.status
      )
      from job_stage_status_rollup r
    ), '[]'::jsonb),
    'failed_jobs_24h', t.failed_jobs_24h_count,
    'stale_running_jobs', t.stale_running_count,
    'retry_backlog', jsonb_build_object(
      'due_count', t.retry_due_count,
      'future_count', t.retry_future_count,
      'dead_job_count', t.dead_job_count,
      'oldest_due_retry_at', t.oldest_due_retry_at,
      'by_stage', coalesce((
        select jsonb_object_agg(
          r.stage::text,
          jsonb_build_object(
            'due', r.retry_due_count,
            'future', r.retry_future_count,
            'dead', r.dead_job_count
          )
        )
        from job_stage_rollup r
        where r.health_job_count > 0
      ), '{}'::jsonb)
    ),
    'ignored_deleted_dead_jobs', jsonb_build_object(
      'count', t.ignored_deleted_dead_count,
      'by_stage', coalesce((
        select jsonb_object_agg(r.stage::text, r.ignored_deleted_dead_count)
        from job_stage_rollup r
        where r.ignored_deleted_dead_count > 0
      ), '{}'::jsonb)
    ),
    'two_stage_running_parse_jobs', jsonb_build_object(
      'count', t.two_stage_count,
      'expired_lock_count', t.two_stage_expired_lock_count,
      'by_state', coalesce((
        select jsonb_object_agg(r.state, r.job_count)
        from two_stage_state_rollup r
      ), '{}'::jsonb)
    ),
    'queue_depths', jsonb_build_object(
      'kb_parse_queue', public.kb_queue_depth('kb_parse_queue'),
      'kb_s3_ready_queue', public.kb_queue_depth('kb_s3_ready_queue'),
      'kb_index_queue', public.kb_queue_depth('kb_index_queue'),
      'kb_delete_queue', public.kb_queue_depth('kb_delete_queue')
    ),
    'latest_job_activity', coalesce((
      select jsonb_object_agg(r.stage::text, r.latest_updated_at)
      from job_stage_rollup r
      where r.health_job_count > 0
    ), '{}'::jsonb)
  ) as health_json
  from job_totals t;
end;
$$;
