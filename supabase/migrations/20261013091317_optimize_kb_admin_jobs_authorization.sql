-- Keep the six-argument RPC, row shape, ordering, filters and ACL intact.
-- Resolve user/group grants once, matching kb_actor_can_access_admin_document
-- and the existing Documents RPC; do not change single-document authorization.
create or replace function public.list_kb_admin_jobs(
  p_actor_id uuid,
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 25,
  p_offset integer default 0,
  p_sort text default 'updated_at',
  p_dir text default 'desc'
)
returns table (
  id uuid,
  document_id uuid,
  document_version integer,
  document_filename text,
  collection_path text,
  stage public.kb_job_stage,
  status public.kb_job_status,
  priority integer,
  attempt_count integer,
  max_attempts integer,
  locked_by text,
  locked_until timestamptz,
  next_retry_at timestamptz,
  pgmq_queue text,
  pgmq_msg_id bigint,
  last_error text,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_sort text := coalesce(nullif(p_sort, ''), 'updated_at');
  v_dir text := lower(coalesce(nullif(p_dir, ''), 'desc'));
  v_failed_only boolean := coalesce((v_filters->>'failed_only')::boolean, false);
  v_stale_running boolean := coalesce((v_filters->>'stale_running')::boolean, false);
begin
  if jsonb_typeof(v_filters) <> 'object' then
    raise exception 'filters must be a JSON object';
  end if;

  if v_dir not in ('asc', 'desc') then
    raise exception 'sort direction must be asc or desc';
  end if;

  return query
  with actor_principals as materialized (
    select *
    from public.kb_actor_principals(p_actor_id)
  ),
  active_grants as materialized (
    select
      g.resource_type,
      g.resource_id,
      g.actions,
      grant_collection.path as grant_collection_path
    from public.kb_grants g
    join actor_principals p
      on p.principal_type = g.principal_type
     and p.principal_id = g.principal_id
    left join public.kb_collections grant_collection
      on grant_collection.id = g.resource_id
     and g.resource_type = 'subtree'
    where p_actor_id is not null
      and g.effect = 'allow'
      and g.revoked_at is null
      and (g.expires_at is null or g.expires_at > now())
  ),
  scoped as (
    select
      j.*,
      d.original_filename as document_filename,
      c.path as collection_path,
      count(*) over() as total_count
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    join public.kb_collections c on c.id = d.primary_collection_id
    where p_actor_id is not null
      and (
        (
          d.deleted_at is null
          and (
            d.created_by = p_actor_id
            or d.owner_user_id = p_actor_id
            or d.visibility = 'public'
            or exists (
              select 1
              from active_grants g
              where g.actions && array[
                  'read'::public.kb_grant_action,
                  'manage'::public.kb_grant_action
                ]
                and (
                  (g.resource_type = 'document' and g.resource_id = d.id)
                  or (g.resource_type = 'collection' and g.resource_id = d.primary_collection_id)
                  or (
                    g.resource_type = 'subtree'
                    and g.grant_collection_path is not null
                    and (
                      c.path = g.grant_collection_path
                      or c.path like g.grant_collection_path || '/%'
                    )
                  )
                )
            )
          )
        )
        or exists (
          select 1
          from active_grants g
          where g.actions && array[
              'reindex'::public.kb_grant_action,
              'delete'::public.kb_grant_action,
              'manage'::public.kb_grant_action
            ]
            and (
              (g.resource_type = 'document' and g.resource_id = d.id)
              or (g.resource_type = 'collection' and g.resource_id = d.primary_collection_id)
              or (
                g.resource_type = 'subtree'
                and g.grant_collection_path is not null
                and (
                  c.path = g.grant_collection_path
                  or c.path like g.grant_collection_path || '/%'
                )
              )
            )
        )
      )
      and (
        not (v_filters ? 'stage')
        or j.stage = (v_filters->>'stage')::public.kb_job_stage
      )
      and (
        not (v_filters ? 'status')
        or j.status = (v_filters->>'status')::public.kb_job_status
      )
      and (
        not (v_filters ? 'document_id')
        or j.document_id = (v_filters->>'document_id')::uuid
      )
      and (
        not (v_filters ? 'locked_by')
        or j.locked_by = v_filters->>'locked_by'
      )
      and (
        not v_failed_only
        or j.status in ('failed'::public.kb_job_status, 'dead'::public.kb_job_status)
      )
      and (
        not v_stale_running
        or (j.status = 'running'::public.kb_job_status and j.locked_until < now())
      )
  )
  select
    scoped.id,
    scoped.document_id,
    scoped.document_version,
    scoped.document_filename,
    scoped.collection_path,
    scoped.stage,
    scoped.status,
    scoped.priority,
    scoped.attempt_count,
    scoped.max_attempts,
    scoped.locked_by,
    scoped.locked_until,
    scoped.next_retry_at,
    scoped.pgmq_queue,
    scoped.pgmq_msg_id,
    scoped.last_error,
    scoped.created_at,
    scoped.started_at,
    scoped.finished_at,
    scoped.updated_at,
    scoped.total_count
  from scoped
  order by
    case when v_sort = 'created_at' and v_dir = 'asc' then scoped.created_at end asc nulls last,
    case when v_sort = 'created_at' and v_dir = 'desc' then scoped.created_at end desc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'asc' then scoped.updated_at end asc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'desc' then scoped.updated_at end desc nulls last,
    case when v_sort = 'locked_until' and v_dir = 'asc' then scoped.locked_until end asc nulls last,
    case when v_sort = 'locked_until' and v_dir = 'desc' then scoped.locked_until end desc nulls last,
    case when v_sort = 'next_retry_at' and v_dir = 'asc' then scoped.next_retry_at end asc nulls last,
    case when v_sort = 'next_retry_at' and v_dir = 'desc' then scoped.next_retry_at end desc nulls last,
    case when v_sort = 'attempt_count' and v_dir = 'asc' then scoped.attempt_count end asc nulls last,
    case when v_sort = 'attempt_count' and v_dir = 'desc' then scoped.attempt_count end desc nulls last,
    scoped.updated_at desc,
    scoped.id
  limit v_limit
  offset v_offset;
end;
$$;
