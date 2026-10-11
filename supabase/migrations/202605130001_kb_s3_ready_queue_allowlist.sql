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
  if p_queue not in (
    'kb_parse_queue',
    'kb_s3_ready_queue',
    'kb_index_queue',
    'kb_delete_queue'
  ) then
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

create or replace function public.read_queue_messages(
  p_queue text,
  p_vt integer default 1800,
  p_qty integer default 25
)
returns table (
  msg_id bigint,
  read_ct integer,
  enqueued_at timestamptz,
  vt timestamptz,
  message jsonb
)
language plpgsql
security definer
set search_path = public, pgmq, pg_temp
as $$
begin
  if p_queue not in (
    'kb_parse_queue',
    'kb_s3_ready_queue',
    'kb_index_queue',
    'kb_delete_queue'
  ) then
    raise exception 'unsupported queue %', p_queue;
  end if;

  if p_vt is null or p_vt <= 0 then
    raise exception 'visibility timeout must be positive';
  end if;

  if p_qty is null or p_qty <= 0 or p_qty > 500 then
    raise exception 'queue read quantity must be between 1 and 500';
  end if;

  return query
  select
    r.msg_id,
    r.read_ct,
    r.enqueued_at,
    r.vt,
    r.message
  from pgmq.read(p_queue, p_vt, p_qty) as r;
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
      and p.proname = 'read_queue_messages'
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
