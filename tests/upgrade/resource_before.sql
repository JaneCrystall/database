-- Synthetic prior-schema records; this file only runs in the disposable local gate.
insert into public.kb_collections(id,name,path) values
 ('81000000-0000-4000-8000-000000000001','Synthetic upgrade collection','m1-upgrade');
insert into public.journals(id,title,doi,authors,date) values
 ('81000000-0000-4000-8000-000000000002','Synthetic upgrade journal','10.9999/m1-upgrade','["Synthetic author"]','2026-10-13');
insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,file_ext,file_size,sha256,created_by,owner_user_id) values
 ('81000000-0000-4000-8000-000000000003','81000000-0000-4000-8000-000000000001',
  '81000000-0000-4000-8000-000000000001','synthetic.pdf','.pdf',811,repeat('e',64),
  '81000000-0000-4000-8000-000000000004','81000000-0000-4000-8000-000000000004');
create schema m1_upgrade_proof;
create table m1_upgrade_proof.rows_before as
 select 'collections' kind,to_jsonb(c) snapshot from public.kb_collections c where c.id='81000000-0000-4000-8000-000000000001'
 union all select 'journals',to_jsonb(j) from public.journals j where j.id='81000000-0000-4000-8000-000000000002'
 union all select 'documents',to_jsonb(d) from public.kb_documents d where d.id='81000000-0000-4000-8000-000000000003';
