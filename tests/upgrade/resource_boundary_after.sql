do $$
declare t text; s text; actual jsonb; replay jsonb; saved jsonb;
begin
 foreach t in array array['kb_resource_entries','kb_resource_document_links','kb_resource_requests','kb_documents','kb_jobs','kb_audit_events'] loop
  s:=case when t like 'kb_resource_%' then 'private' else 'public' end;
  execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from %I.%I x',s,t) into actual;
  if actual is distinct from (select value from m1_upgrade_proof.resource_state where key=t) then raise exception 'schema move changed rows: %',t; end if;
  if s='private' and to_jsonb((s||'.'||t)::regclass::oid) is distinct from (select value from m1_upgrade_proof.resource_state where key='oid:'||t) then raise exception 'table identity changed: %',t; end if;
 end loop;
 select value into replay from m1_upgrade_proof.resource_state where key='replay';
 select value into saved from m1_upgrade_proof.resource_state where key='getter';
 -- The real gateway role can still replay old receipts and read current state.
 set local role service_role;
 actual:=api.kb_resource_command((replay->>'actor')::uuid,(replay->>'collection')::uuid,'upsert',(replay->>'request')::uuid,replay->'payload');
 if actual is distinct from replay->'receipt' then raise exception 'old receipt changed'; end if;
 actual:=api.kb_resource_get((replay->>'actor')::uuid,(replay->>'collection')::uuid,(saved->>'id')::uuid);
 if actual is distinct from saved then raise exception 'current getter state changed'; end if;
 reset role;
end $$;
