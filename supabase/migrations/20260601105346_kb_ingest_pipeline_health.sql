create or replace function public.get_kb_ingest_pipeline_health(
  p_actor_id uuid,
  p_collection_id uuid
)
returns table (health_json jsonb)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_authorized boolean;
begin
  select public.can_collection_action(
    p_actor_id,
    p_collection_id,
    'upload'::public.kb_grant_action
  )
  into v_authorized;

  if coalesce(v_authorized, false) is false then
    return;
  end if;

  return query
  with target_collection as (
    select id, path
    from public.kb_collections
    where id = p_collection_id
  ),
  scoped_collections as (
    select c.id
    from public.kb_collections c
    join target_collection tc
      on c.id = tc.id
      or c.path like tc.path || '/%'
  ),
  scoped_jobs as (
    select j.*
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    join scoped_collections c on c.id = d.primary_collection_id
    where d.deleted_at is null
      and (
        j.status <> 'dead'::public.kb_job_status
        or d.status is distinct from 'deleted'::public.kb_document_status
      )
  ),
  two_stage_running_parse_jobs as (
    select j.*
    from scoped_jobs j
    where j.stage = 'parse'::public.kb_job_stage
      and j.status = 'running'::public.kb_job_status
      and j.payload_json #>> '{two_stage,task_id}' is not null
  ),
  counts as (
    select
      count(*) filter (where status = 'queued'::public.kb_job_status)::integer as total_queued,
      count(*) filter (where status = 'running'::public.kb_job_status)::integer as total_running,
      count(*) filter (
        where status = 'running'::public.kb_job_status
          and locked_until < now()
          and not exists (
            select 1
            from two_stage_running_parse_jobs t
            where t.id = scoped_jobs.id
              and coalesce(t.payload_json #>> '{two_stage,state}', '') not in ('SUCCESS', 'FAILURE', 'REVOKED')
          )
      )::integer as stale_running
    from scoped_jobs
  ),
  pressure as (
    select
      case
        when stale_running > 0 or total_queued >= 100 then 'paused'
        when total_queued >= 25 or total_running >= 25 then 'degraded'
        else 'ok'
      end as pressure
    from counts
  )
  select jsonb_build_object(
    'healthy', pressure.pressure = 'ok',
    'pressure', pressure.pressure,
    'recommendedAction', case
      when pressure.pressure = 'ok' then 'continue'
      when pressure.pressure = 'degraded' then 'slow_down'
      else 'pause_top_up'
    end,
    'recommendedPollAfterSeconds', case
      when pressure.pressure = 'ok' then 5
      when pressure.pressure = 'degraded' then 60
      else 120
    end,
    'reason', case
      when pressure.pressure = 'ok' then null
      else 'backpressure'
    end,
    'checkedAt', now()
  )
  from counts, pressure;
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'get_kb_ingest_pipeline_health'
  loop
    execute format('revoke all on function %I.%I(%s) from public', r.nspname, r.proname, r.args);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %I.%I(%s) from anon', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on function %I.%I(%s) from authenticated', r.nspname, r.proname, r.args);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %I.%I(%s) to service_role', r.nspname, r.proname, r.args);
    end if;
  end loop;
end $$;
