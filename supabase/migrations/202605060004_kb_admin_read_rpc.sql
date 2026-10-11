alter table public.kb_documents
  add column if not exists metadata_reviewed_at timestamptz,
  add column if not exists metadata_reviewed_by uuid,
  add column if not exists metadata_review_note text;

create index if not exists kb_documents_metadata_review_idx
on public.kb_documents (metadata_status, metadata_confidence, updated_at desc);

create or replace function public.kb_actor_has_any_grant_action(
  p_actor_id uuid,
  p_actions public.kb_grant_action[]
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    exists (
      select 1
      from public.kb_grants g
      join public.kb_actor_principals(p_actor_id) p
        on p.principal_type = g.principal_type
       and p.principal_id = g.principal_id
      where p_actor_id is not null
        and p_actions is not null
        and g.effect = 'allow'
        and g.revoked_at is null
        and (g.expires_at is null or g.expires_at > now())
        and (
          g.actions && p_actions
          or 'manage'::public.kb_grant_action = any(g.actions)
        )
    ),
    false
  )
$$;

create or replace function public.kb_actor_can_access_admin_document(
  p_actor_id uuid,
  p_document_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.can_read_document(p_actor_id, p_document_id)
      or public.can_document_action(p_actor_id, p_document_id, 'reindex')
      or public.can_document_action(p_actor_id, p_document_id, 'delete')
$$;

create or replace function public.get_kb_admin_capabilities(p_actor_id uuid)
returns table (
  can_view_console boolean,
  can_view_all_documents boolean,
  can_retry boolean,
  can_reindex boolean,
  can_reparse boolean,
  can_delete boolean,
  can_review_metadata boolean,
  can_view_health boolean,
  role text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_read boolean;
  v_has_operator boolean;
  v_has_delete boolean;
  v_has_manage boolean;
  v_owns_documents boolean;
begin
  v_has_read := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['read'::public.kb_grant_action]
  );
  v_has_operator := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['reindex'::public.kb_grant_action]
  );
  v_has_delete := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['delete'::public.kb_grant_action]
  );
  v_has_manage := public.kb_actor_has_any_grant_action(
    p_actor_id,
    array['manage'::public.kb_grant_action]
  );

  select exists (
    select 1
    from public.kb_documents d
    where p_actor_id is not null
      and d.deleted_at is null
      and (d.created_by = p_actor_id or d.owner_user_id = p_actor_id)
  )
  into v_owns_documents;

  return query
  select
    (p_actor_id is not null and (v_has_read or v_has_operator or v_has_delete or v_has_manage or v_owns_documents)) as can_view_console,
    (v_has_read or v_has_operator or v_has_delete or v_has_manage) as can_view_all_documents,
    (v_has_operator or v_has_manage) as can_retry,
    (v_has_operator or v_has_manage) as can_reindex,
    (v_has_operator or v_has_manage) as can_reparse,
    (v_has_delete or v_has_manage) as can_delete,
    (v_has_operator or v_has_manage) as can_review_metadata,
    (v_has_operator or v_has_delete or v_has_manage) as can_view_health,
    case
      when v_has_manage or v_has_delete then 'admin'
      when v_has_operator then 'operator'
      when v_has_read or v_owns_documents then 'support'
      else 'none'
    end as role;
end;
$$;

create or replace function public.list_kb_admin_documents(
  p_actor_id uuid,
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 25,
  p_offset integer default 0,
  p_sort text default 'updated_at',
  p_dir text default 'desc'
)
returns table (
  id uuid,
  primary_collection_id uuid,
  collection_path text,
  document_version integer,
  original_filename text,
  file_ext text,
  file_size bigint,
  sha256 text,
  status public.kb_document_status,
  visibility public.kb_document_visibility,
  created_by uuid,
  owner_user_id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  metadata_status public.kb_metadata_status,
  metadata_confidence numeric,
  last_error text,
  last_error_stage public.kb_job_stage,
  opensearch_indexed boolean,
  pinecone_indexed boolean,
  deleted_at timestamptz,
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
  v_q text := nullif(btrim(v_filters->>'q'), '');
  v_include_deleted boolean := coalesce((v_filters->>'include_deleted')::boolean, false);
begin
  if jsonb_typeof(v_filters) <> 'object' then
    raise exception 'filters must be a JSON object';
  end if;

  if v_dir not in ('asc', 'desc') then
    raise exception 'sort direction must be asc or desc';
  end if;

  return query
  with scoped as (
    select
      d.*,
      c.path as collection_path,
      count(*) over() as total_count
    from public.kb_documents d
    join public.kb_collections c on c.id = d.primary_collection_id
    where public.kb_actor_can_access_admin_document(p_actor_id, d.id)
      and (v_include_deleted or d.deleted_at is null)
      and (
        not (v_filters ? 'status')
        or d.status = (v_filters->>'status')::public.kb_document_status
      )
      and (
        not (v_filters ? 'last_error_stage')
        or d.last_error_stage = (v_filters->>'last_error_stage')::public.kb_job_stage
      )
      and (
        not (v_filters ? 'primary_collection_id')
        or d.primary_collection_id = (v_filters->>'primary_collection_id')::uuid
      )
      and (
        not (v_filters ? 'owner_user_id')
        or d.owner_user_id = (v_filters->>'owner_user_id')::uuid
      )
      and (
        not (v_filters ? 'created_by')
        or d.created_by = (v_filters->>'created_by')::uuid
      )
      and (
        not (v_filters ? 'metadata_status')
        or d.metadata_status = (v_filters->>'metadata_status')::public.kb_metadata_status
      )
      and (
        not (v_filters ? 'metadata_confidence_lte')
        or d.metadata_confidence <= (v_filters->>'metadata_confidence_lte')::numeric
      )
      and (
        not (v_filters ? 'created_from')
        or d.created_at >= (v_filters->>'created_from')::timestamptz
      )
      and (
        not (v_filters ? 'created_to')
        or d.created_at <= (v_filters->>'created_to')::timestamptz
      )
      and (
        v_q is null
        or d.original_filename ilike '%' || v_q || '%'
        or d.sha256 ilike '%' || v_q || '%'
        or d.id::text = v_q
      )
  )
  select
    scoped.id,
    scoped.primary_collection_id,
    scoped.collection_path,
    scoped.document_version,
    scoped.original_filename,
    scoped.file_ext,
    scoped.file_size,
    scoped.sha256,
    scoped.status,
    scoped.visibility,
    scoped.created_by,
    scoped.owner_user_id,
    scoped.created_at,
    scoped.updated_at,
    scoped.metadata_status,
    scoped.metadata_confidence,
    scoped.last_error,
    scoped.last_error_stage,
    scoped.opensearch_indexed,
    scoped.pinecone_indexed,
    scoped.deleted_at,
    scoped.total_count
  from scoped
  order by
    case when v_sort = 'created_at' and v_dir = 'asc' then scoped.created_at end asc nulls last,
    case when v_sort = 'created_at' and v_dir = 'desc' then scoped.created_at end desc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'asc' then scoped.updated_at end asc nulls last,
    case when v_sort = 'updated_at' and v_dir = 'desc' then scoped.updated_at end desc nulls last,
    case when v_sort = 'original_filename' and v_dir = 'asc' then scoped.original_filename end asc nulls last,
    case when v_sort = 'original_filename' and v_dir = 'desc' then scoped.original_filename end desc nulls last,
    case when v_sort = 'status' and v_dir = 'asc' then scoped.status::text end asc nulls last,
    case when v_sort = 'status' and v_dir = 'desc' then scoped.status::text end desc nulls last,
    case when v_sort = 'metadata_confidence' and v_dir = 'asc' then scoped.metadata_confidence end asc nulls last,
    case when v_sort = 'metadata_confidence' and v_dir = 'desc' then scoped.metadata_confidence end desc nulls last,
    scoped.updated_at desc,
    scoped.id
  limit v_limit
  offset v_offset;
end;
$$;

create or replace function public.get_kb_admin_document_detail(
  p_actor_id uuid,
  p_document_id uuid
)
returns table (
  document_json jsonb,
  jobs_json jsonb,
  audit_events_json jsonb
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.kb_actor_can_access_admin_document(p_actor_id, p_document_id) then
    return;
  end if;

  return query
  select
    (
      select to_jsonb(d) || jsonb_build_object(
        'collection_path', c.path,
        'collection_name', c.name
      )
      from public.kb_documents d
      join public.kb_collections c on c.id = d.primary_collection_id
      where d.id = p_document_id
    ) as document_json,
    coalesce((
      select jsonb_agg(to_jsonb(j) order by j.created_at desc)
      from public.kb_jobs j
      where j.document_id = p_document_id
    ), '[]'::jsonb) as jobs_json,
    coalesce((
      select jsonb_agg(to_jsonb(a) order by a.created_at desc)
      from (
        select *
        from public.kb_audit_events
        where document_id = p_document_id
        order by created_at desc
        limit 100
      ) a
    ), '[]'::jsonb) as audit_events_json;
end;
$$;

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
  with scoped as (
    select
      j.*,
      d.original_filename as document_filename,
      c.path as collection_path,
      count(*) over() as total_count
    from public.kb_jobs j
    join public.kb_documents d on d.id = j.document_id
    join public.kb_collections c on c.id = d.primary_collection_id
    where public.kb_actor_can_access_admin_document(p_actor_id, d.id)
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
    case when v_sort = 'attempt_count' and v_dir = 'asc' then scoped.attempt_count end asc nulls last,
    case when v_sort = 'attempt_count' and v_dir = 'desc' then scoped.attempt_count end desc nulls last,
    scoped.updated_at desc,
    scoped.id
  limit v_limit
  offset v_offset;
end;
$$;

create or replace function public.list_kb_admin_audit_events(
  p_actor_id uuid,
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table (
  id uuid,
  actor_id uuid,
  action text,
  document_id uuid,
  collection_id uuid,
  scope_json jsonb,
  request_id text,
  payload_json jsonb,
  created_at timestamptz,
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
begin
  if jsonb_typeof(v_filters) <> 'object' then
    raise exception 'filters must be a JSON object';
  end if;

  return query
  with scoped as (
    select
      a.*,
      count(*) over() as total_count
    from public.kb_audit_events a
    where (
        a.actor_id = p_actor_id
        or (a.document_id is not null and public.kb_actor_can_access_admin_document(p_actor_id, a.document_id))
        or (
          a.collection_id is not null
          and (
            public.can_collection_action(p_actor_id, a.collection_id, 'read')
            or public.can_collection_action(p_actor_id, a.collection_id, 'reindex')
            or public.can_collection_action(p_actor_id, a.collection_id, 'delete')
          )
        )
      )
      and (
        not (v_filters ? 'action')
        or a.action = v_filters->>'action'
      )
      and (
        not (v_filters ? 'actor_id')
        or a.actor_id = (v_filters->>'actor_id')::uuid
      )
      and (
        not (v_filters ? 'document_id')
        or a.document_id = (v_filters->>'document_id')::uuid
      )
      and (
        not (v_filters ? 'request_id')
        or a.request_id = v_filters->>'request_id'
      )
  )
  select
    scoped.id,
    scoped.actor_id,
    scoped.action,
    scoped.document_id,
    scoped.collection_id,
    scoped.scope_json,
    scoped.request_id,
    scoped.payload_json,
    scoped.created_at,
    scoped.total_count
  from scoped
  order by scoped.created_at desc, scoped.id
  limit v_limit
  offset v_offset;
end;
$$;

create or replace function public.kb_queue_depth(p_queue text)
returns bigint
language plpgsql
stable
security definer
set search_path = public, pgmq, pg_temp
as $$
declare
  v_depth bigint := 0;
begin
  if p_queue not in ('kb_parse_queue', 'kb_index_queue', 'kb_delete_queue') then
    raise exception 'unsupported queue %', p_queue;
  end if;

  execute format('select count(*)::bigint from pgmq.%I', 'q_' || p_queue)
  into v_depth;

  return coalesce(v_depth, 0);
exception
  when undefined_table then
    return 0;
end;
$$;

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
        from public.kb_jobs
        group by stage, status
        order by stage, status
      ) s
    ), '[]'::jsonb),
    'failed_jobs_24h', (
      select count(*)::bigint
      from public.kb_jobs
      where status in ('failed'::public.kb_job_status, 'dead'::public.kb_job_status)
        and updated_at >= now() - interval '24 hours'
    ),
    'stale_running_jobs', (
      select count(*)::bigint
      from public.kb_jobs
      where status = 'running'::public.kb_job_status
        and locked_until < now()
    ),
    'queue_depths', jsonb_build_object(
      'kb_parse_queue', public.kb_queue_depth('kb_parse_queue'),
      'kb_index_queue', public.kb_queue_depth('kb_index_queue'),
      'kb_delete_queue', public.kb_queue_depth('kb_delete_queue')
    ),
    'latest_job_activity', coalesce((
      select jsonb_object_agg(stage::text, latest_updated_at)
      from (
        select stage, max(updated_at) as latest_updated_at
        from public.kb_jobs
        group by stage
      ) s
    ), '{}'::jsonb)
  ) as health_json;
end;
$$;

create or replace function public.review_kb_document_metadata(
  p_actor_id uuid,
  p_document_id uuid,
  p_metadata_json jsonb,
  p_metadata_status public.kb_metadata_status,
  p_metadata_confidence numeric,
  p_reason text,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'metadata review reason is required';
  end if;

  if p_metadata_json is not null and jsonb_typeof(p_metadata_json) <> 'object' then
    raise exception 'metadata_json must be a JSON object';
  end if;

  select
    id,
    primary_collection_id,
    metadata_json,
    metadata_status,
    metadata_confidence
  into v_before
  from public.kb_documents
  where id = p_document_id;

  if not found then
    raise exception 'document % was not found', p_document_id;
  end if;

  if not public.can_document_action(p_actor_id, p_document_id, 'reindex') then
    perform public.write_kb_audit_event(
      p_actor_id,
      'kb.auth_denied',
      p_document_id,
      v_before.primary_collection_id,
      jsonb_build_object(
        'resource_type', 'document',
        'resource_id', p_document_id,
        'requested_action', 'metadata_review'
      ),
      p_request_id,
      jsonb_build_object('reason', 'missing reindex or manage grant')
    );
    return false;
  end if;

  update public.kb_documents
  set metadata_json = coalesce(p_metadata_json, metadata_json),
      metadata_status = p_metadata_status,
      metadata_confidence = p_metadata_confidence,
      metadata_reviewed_at = now(),
      metadata_reviewed_by = p_actor_id,
      metadata_review_note = p_reason
  where id = p_document_id;

  perform public.write_kb_audit_event(
    p_actor_id,
    'kb.metadata_reviewed',
    p_document_id,
    v_before.primary_collection_id,
    jsonb_build_object('resource_type', 'document', 'resource_id', p_document_id),
    p_request_id,
    jsonb_build_object(
      'reason', p_reason,
      'before', jsonb_build_object(
        'metadata_json', v_before.metadata_json,
        'metadata_status', v_before.metadata_status,
        'metadata_confidence', v_before.metadata_confidence
      ),
      'after', jsonb_build_object(
        'metadata_json', coalesce(p_metadata_json, v_before.metadata_json),
        'metadata_status', p_metadata_status,
        'metadata_confidence', p_metadata_confidence
      )
    )
  );

  return true;
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
      and p.proname in (
        'kb_actor_has_any_grant_action',
        'kb_actor_can_access_admin_document',
        'get_kb_admin_capabilities',
        'list_kb_admin_documents',
        'get_kb_admin_document_detail',
        'list_kb_admin_jobs',
        'list_kb_admin_audit_events',
        'kb_queue_depth',
        'get_kb_admin_health',
        'review_kb_document_metadata'
      )
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
