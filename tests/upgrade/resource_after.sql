do $$
begin
 if (select snapshot from m1_upgrade_proof.rows_before where kind='collections') is distinct from
    (select to_jsonb(c) from public.kb_collections c where c.id='81000000-0000-4000-8000-000000000001')
 or (select snapshot from m1_upgrade_proof.rows_before where kind='journals') is distinct from
    (select to_jsonb(j) from public.journals j where j.id='81000000-0000-4000-8000-000000000002')
 or (select snapshot from m1_upgrade_proof.rows_before where kind='documents') is distinct from
    (select to_jsonb(d) from public.kb_documents d where d.id='81000000-0000-4000-8000-000000000003') then
   raise exception 'prior-schema rows changed during resource migration';
 end if;
 if exists(select from private.kb_resource_entries where collection_id='81000000-0000-4000-8000-000000000001') then
   raise exception 'resource migration must not backfill/activate an existing collection';
 end if;
end $$;
