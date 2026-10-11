create extension if not exists pgcrypto;

do $$
begin
  create type kb_document_status as enum (
    'received',
    'raw_stored',
    'parse_queued',
    'parsing',
    'parsed',
    'index_queued',
    'indexing',
    'completed',
    'failed',
    'delete_queued',
    'deleting',
    'deleted'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_job_stage as enum (
    'parse',
    'index',
    'delete',
    'archive_raw'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_job_status as enum (
    'queued',
    'running',
    'succeeded',
    'failed',
    'dead',
    'cancelled'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_document_visibility as enum (
    'private',
    'shared',
    'public'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_metadata_status as enum (
    'pending',
    'extracted',
    'low_confidence',
    'failed',
    'not_applicable'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_resource_type as enum (
    'document',
    'collection',
    'subtree'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_principal_type as enum (
    'user',
    'group',
    'org'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_grant_action as enum (
    'read',
    'upload',
    'delete',
    'reindex',
    'manage',
    'share'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_grant_effect as enum (
    'allow'
  );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type kb_retention_policy as enum (
    'delete_immediately',
    'retain_for_days',
    'archive_only'
  );
exception
  when duplicate_object then null;
end $$;

create or replace function kb_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists kb_collections (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  parent_id uuid references kb_collections(id) on delete restrict,
  path text not null unique,
  content_type text,
  default_raw_storage text not null default 'self_hosted_nas',
  parse_worker_region text,
  index_namespace text,
  metadata_schema_json jsonb not null default '{}'::jsonb,
  raw_retention_policy kb_retention_policy not null default 'delete_immediately',
  raw_retention_days integer not null default 0 check (raw_retention_days >= 0),
  processed_retention_policy kb_retention_policy not null default 'delete_immediately',
  processed_retention_days integer not null default 0 check (processed_retention_days >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (name <> ''),
  check (path <> '')
);

drop trigger if exists kb_collections_set_updated_at on kb_collections;
create trigger kb_collections_set_updated_at
before update on kb_collections
for each row execute function kb_set_updated_at();

create table if not exists kb_documents (
  id uuid primary key default gen_random_uuid(),
  primary_collection_id uuid not null references kb_collections(id) on delete restrict,
  document_version integer not null default 1 check (document_version > 0),
  dedupe_scope text not null,
  original_filename text not null,
  file_ext text,
  file_size bigint check (file_size is null or file_size >= 0),
  sha256 text not null,
  status kb_document_status not null default 'received',
  visibility kb_document_visibility not null default 'private',
  created_by uuid not null,
  owner_user_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  raw_uri text,
  raw_storage_region text,
  raw_archive_s3_key text,
  processed_manifest_local_uri text,
  processed_manifest_s3_key text,
  metadata_json jsonb not null default '{}'::jsonb,
  metadata_status kb_metadata_status not null default 'pending',
  metadata_confidence numeric(5, 4) check (
    metadata_confidence is null
    or (metadata_confidence >= 0 and metadata_confidence <= 1)
  ),
  duplicate_uploads jsonb not null default '[]'::jsonb,
  chunk_count integer check (chunk_count is null or chunk_count >= 0),
  parse_time timestamptz,
  index_time timestamptz,
  opensearch_indexed boolean not null default false,
  pinecone_indexed boolean not null default false,
  deleted_at timestamptz,
  deleted_by uuid,
  delete_generation integer not null default 0 check (delete_generation >= 0),
  delete_requested_at timestamptz,
  delete_completed_at timestamptz,
  last_error text,
  last_error_stage kb_job_stage,
  check (dedupe_scope <> ''),
  check (sha256 <> ''),
  check (jsonb_typeof(duplicate_uploads) = 'array')
);

create unique index if not exists kb_documents_active_dedupe_idx
on kb_documents (dedupe_scope, sha256)
where deleted_at is null;

create index if not exists kb_documents_collection_status_idx
on kb_documents (primary_collection_id, status);

create index if not exists kb_documents_owner_idx
on kb_documents (owner_user_id, created_at desc);

create index if not exists kb_documents_deleted_at_idx
on kb_documents (deleted_at)
where deleted_at is not null;

drop trigger if exists kb_documents_set_updated_at on kb_documents;
create trigger kb_documents_set_updated_at
before update on kb_documents
for each row execute function kb_set_updated_at();

create table if not exists kb_jobs (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references kb_documents(id) on delete cascade,
  document_version integer not null check (document_version > 0),
  stage kb_job_stage not null,
  status kb_job_status not null default 'queued',
  priority integer not null default 100,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  locked_by text,
  locked_until timestamptz,
  pgmq_queue text,
  pgmq_msg_id bigint,
  last_error text,
  payload_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  check (attempt_count <= max_attempts),
  check (jsonb_typeof(payload_json) = 'object')
);

create index if not exists kb_jobs_status_stage_priority_idx
on kb_jobs (status, stage, priority, created_at);

create index if not exists kb_jobs_document_idx
on kb_jobs (document_id, document_version, stage, status);

create index if not exists kb_jobs_locked_until_idx
on kb_jobs (locked_until)
where status = 'running';

create unique index if not exists kb_jobs_active_stage_idx
on kb_jobs (document_id, document_version, stage)
where status in ('queued', 'running', 'failed');

drop trigger if exists kb_jobs_set_updated_at on kb_jobs;
create trigger kb_jobs_set_updated_at
before update on kb_jobs
for each row execute function kb_set_updated_at();

create table if not exists kb_grants (
  id uuid primary key default gen_random_uuid(),
  resource_type kb_resource_type not null,
  resource_id uuid not null,
  principal_type kb_principal_type not null,
  principal_id uuid not null,
  actions kb_grant_action[] not null,
  effect kb_grant_effect not null default 'allow',
  expires_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(actions) > 0)
);

create index if not exists kb_grants_resource_idx
on kb_grants (resource_type, resource_id);

create index if not exists kb_grants_principal_idx
on kb_grants (principal_type, principal_id);

create index if not exists kb_grants_expires_at_idx
on kb_grants (expires_at)
where expires_at is not null;

drop trigger if exists kb_grants_set_updated_at on kb_grants;
create trigger kb_grants_set_updated_at
before update on kb_grants
for each row execute function kb_set_updated_at();

create table if not exists kb_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (name <> '')
);

drop trigger if exists kb_groups_set_updated_at on kb_groups;
create trigger kb_groups_set_updated_at
before update on kb_groups
for each row execute function kb_set_updated_at();

create table if not exists kb_group_members (
  group_id uuid not null references kb_groups(id) on delete cascade,
  user_id uuid not null,
  role text not null default 'member',
  created_at timestamptz not null default now(),
  primary key (group_id, user_id),
  check (role <> '')
);

create index if not exists kb_group_members_user_idx
on kb_group_members (user_id);

create table if not exists kb_audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  action text not null,
  document_id uuid references kb_documents(id) on delete set null,
  collection_id uuid references kb_collections(id) on delete set null,
  scope_json jsonb not null default '{}'::jsonb,
  request_id text,
  payload_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (action <> ''),
  check (jsonb_typeof(scope_json) = 'object'),
  check (jsonb_typeof(payload_json) = 'object')
);

create index if not exists kb_audit_events_actor_created_idx
on kb_audit_events (actor_id, created_at desc);

create index if not exists kb_audit_events_document_created_idx
on kb_audit_events (document_id, created_at desc);

create index if not exists kb_audit_events_request_idx
on kb_audit_events (request_id)
where request_id is not null;

create table if not exists kb_query_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  scope_json jsonb not null default '{}'::jsonb,
  mode text not null,
  rewrite_mode text,
  rewrite_applied boolean,
  original_query text not null,
  semantic_query text,
  full_text_query text,
  filters_json jsonb not null default '{}'::jsonb,
  top_k integer check (top_k is null or top_k > 0),
  ext_k integer check (ext_k is null or ext_k > 0),
  result_count integer check (result_count is null or result_count >= 0),
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  created_at timestamptz not null default now(),
  check (jsonb_typeof(scope_json) = 'object'),
  check (jsonb_typeof(filters_json) = 'object')
);

create index if not exists kb_query_logs_actor_created_idx
on kb_query_logs (actor_id, created_at desc);
