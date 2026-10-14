-- Business conflicts require a terminal HTTP response, not transaction replay.
-- Keep the private SQL protocol and genuine serialization failures unchanged.
begin;

create or replace function api.kb_resource_command(
  p_actor_id uuid,p_collection_id uuid,p_operation text,p_request_id uuid,p_payload jsonb
) returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
begin
  return private.kb_resource_command(p_actor_id,p_collection_id,p_operation,p_request_id,p_payload);
exception when serialization_failure then
  if sqlerrm = any(array[
    'RESOURCE_APPROVAL_REQUIRED',
    'RESOURCE_DOCUMENT_ALREADY_PROCESSING',
    'RESOURCE_DOCUMENT_CONFLICT',
    'RESOURCE_LIFECYCLE_BUSY',
    'RESOURCE_MATCH_CONFLICT',
    'RESOURCE_PROFILE_CHANGED',
    'RESOURCE_REQUEST_CONFLICT',
    'RESOURCE_RESERVATION_REQUIRED',
    'RESOURCE_REVISION_CONFLICT',
    'RESOURCE_SECONDARY_SOURCE_PROPOSAL',
    'RESOURCE_SOURCE_CHANGED'
  ]) then
    raise exception using errcode='PT409',message=sqlerrm;
  end if;
  raise;
end $$;

notify pgrst, 'reload schema';
commit;
