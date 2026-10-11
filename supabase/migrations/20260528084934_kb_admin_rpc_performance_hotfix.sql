create index if not exists kb_documents_active_updated_idx
on public.kb_documents (updated_at desc, id)
where deleted_at is null;

create index if not exists kb_documents_active_created_idx
on public.kb_documents (created_at desc, id)
where deleted_at is null;

create index if not exists kb_audit_events_created_idx
on public.kb_audit_events (created_at desc, id);

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
      d.*,
      c.path as collection_path,
      count(*) over() as total_count
    from public.kb_documents d
    join public.kb_collections c on c.id = d.primary_collection_id
    where p_actor_id is not null
      and (v_include_deleted or d.deleted_at is null)
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
      a.*,
      count(*) over() as total_count
    from public.kb_audit_events a
    left join public.kb_documents d on d.id = a.document_id
    left join public.kb_collections document_collection
      on document_collection.id = d.primary_collection_id
    left join public.kb_collections event_collection
      on event_collection.id = a.collection_id
    where p_actor_id is not null
      and (
        a.actor_id = p_actor_id
        or (
          a.document_id is not null
          and d.id is not null
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
                        and document_collection.path is not null
                        and (
                          document_collection.path = g.grant_collection_path
                          or document_collection.path like g.grant_collection_path || '/%'
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
                    and document_collection.path is not null
                    and (
                      document_collection.path = g.grant_collection_path
                      or document_collection.path like g.grant_collection_path || '/%'
                    )
                  )
                )
            )
          )
        )
        or (
          a.collection_id is not null
          and event_collection.id is not null
          and exists (
            select 1
            from active_grants g
            where g.actions && array[
                'read'::public.kb_grant_action,
                'reindex'::public.kb_grant_action,
                'delete'::public.kb_grant_action,
                'manage'::public.kb_grant_action
              ]
              and (
                (g.resource_type = 'collection' and g.resource_id = event_collection.id)
                or (
                  g.resource_type = 'subtree'
                  and g.grant_collection_path is not null
                  and (
                    event_collection.path = g.grant_collection_path
                    or event_collection.path like g.grant_collection_path || '/%'
                  )
                )
              )
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

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    alter role service_role set statement_timeout = '20s';
  end if;
end $$;

notify pgrst, 'reload config';
