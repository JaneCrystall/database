---
docType: contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When reviewing S9 legacy permissions or preparing its separately authorized release."
whenToUpdate: "When legacy ACLs, worker identities or release qualification change."
checkPaths: [supabase/migrations/*_narrow_legacy_public_permissions.sql, tests/runtime/legacy_permissions*, tests/schema/legacy_acl_policy.json, tests/consumers/**]
lastReviewedAt: 2026-10-15
lastReviewedCommit: 33c3b417182b72349e36d0b6cf44a26e4be31c2c
---

# S9 legacy public access boundary

Issue: https://github.com/tiangong-ai/database/issues/17. This is an isolated
qualification candidate, not release authorization. No merge, deployment,
142/148 operation, table relocation or M1-03 change is included.

Baseline `5908ca9` granted ordinary API roles six unnecessary mutation/object
privileges on 23 tables. A rollback-scoped synthetic reproduction demonstrated
that `anon` could actually TRUNCATE `edu_meta`: RLS does not protect TRUNCATE.
It also returned HTTP 200 for an internal API-key RPC using an ordinary role.
New SQL/HTTP regressions failed before the appended migration and pass after it.

## Exact decision

The new migration revokes INSERT, UPDATE, DELETE, REFERENCES, TRIGGER and
TRUNCATE from PUBLIC, anon and authenticated on the 23 listed tables. It keeps
SELECT and existing RLS, including policyless empty results. This intentionally
changes UPDATE/DELETE that previously affected zero rows into permission errors.
The original Next handler mapped DB 42501 to HTTP 500. The paired candidate for
[Next #88](https://github.com/tiangong-ai/web-app/issues/88) now maps session
permission denial to safe 403. The updated consumer harness requires exact 403
for POST/PATCH/DELETE in all six categories, exact 401 for anonymous writes,
fixed error bodies and unchanged stored rows/no insert residue. Real local
HTTP/Auth/PostgREST qualification passed with the paired candidate; neither
candidate is merged or deployed. S9 release still requires the qualified Next
revision, not an older checkout that returns 500.
No existing ordinary write policy is lost: these tables had SELECT-only or no
policies. Management SELECT remains policyless/empty; further interface/schema
reorganization belongs to S2–S8. It does not silently enable business writes.

It revokes EXECUTE from those three principals on 18 exact function signatures.
Two invoker full-text functions retain their existing ACLs for active Edge
consumers. Revoking only explicit anon/authenticated grants would leave the
PUBLIC inheritance path open. No function body, signature, default argument,
owner, search_path, volatility, trigger, policy or existing migration changes.
All twelve affected SECURITY DEFINER functions already pin search_path. The
normalizer and timestamp-only invoker helper with no configured search_path
remain unchanged; S9 does not convert any function to SECURITY DEFINER.

`tests/schema/legacy_acl_policy.json` is the machine-readable reviewed scope.
`public_catalog.expected.json` changes only 18 function ACLs and 23 table ACLs;
`pre_resource_catalog.expected.json` remains the immutable prior-generation
expectation. All 24 tables, 72 public functions and enums remain in place.

## Twenty-four tables

In every row except `kb_index_records`, current anon/authenticated ACL = SELECT
plus the six privileges above; target = SELECT, subject to the existing policy.
Service_role retains its current seven privileges; PostgreSQL ownership rights
remain with postgres. This task removes untrusted access, not all backend trust.

| Table | Responsibility / observed consumer | Ordinary target and reason |
|---|---|---|
| edu_meta | Education catalog; Next, Edge education | SELECT; authenticated read policy |
| edu_textbooks | Textbook metadata; catalog reader | SELECT; authenticated read policy |
| esg_category | ESG taxonomy; Next resource options | SELECT; authenticated read policy |
| esg_country | ESG country dictionary; Next options | SELECT; authenticated read policy |
| esg_meta | ESG reports; Next and Edge full-text | SELECT; authenticated read, FORCE RLS remains true |
| green_deal_meta | Green Deal catalog; Next | SELECT; no policy, preserve empty reads |
| internal_use | Internal library metadata; Next | SELECT; existing authenticated policy preserved; owner confirmed all authenticated users may read and online catalog confirmed TO authenticated USING (true) (2026-10-15); no user data queried |
| journals | Paper metadata; journal pipeline, SCI Edge | SELECT; authenticated policy and journals_reader SELECT preserved |
| journals_issn | Journal reference metadata | SELECT; authenticated policy |
| reports | Report metadata; Next | SELECT; authenticated policy |
| standards | Standards metadata; Next and Edge | SELECT; authenticated policy |
| user_roles | Legacy per-user role record | SELECT; only user_id = auth.uid(); not the KB grant system |
| kb_collections | Collection hierarchy/profile; Next, workers | SELECT but no ordinary policy; backend stays functional |
| kb_documents | Document lifecycle; Next, workers | SELECT but no ordinary policy |
| kb_api_keys | Hashed token lifecycle; Next, course Edge | SELECT but no ordinary policy; service direct CRUD and auth RPCs retained |
| kb_audit_events | Internal audit trail; admin RPC | SELECT but no ordinary policy |
| kb_grants | KB authorization records; capability RPCs | SELECT but no ordinary policy |
| kb_group_members | KB principal membership; authorization RPCs | SELECT but no ordinary policy |
| kb_groups | KB principal groups; admin service | SELECT but no ordinary policy |
| kb_jobs | Execution state/leases; workers, Jobs admin | SELECT but no ordinary policy |
| kb_query_logs | Search telemetry | SELECT but no ordinary policy |
| kb_schema_migrations | Legacy operational ledger | SELECT but no ordinary policy; no ledger reconciliation |
| kb_search_partitions | Search backend routing | SELECT but no ordinary policy; service routing preserved |
| kb_index_records | Index cleanup ledger; index/delete workers | Already backend-only; no ACL change |

All tables keep RLS. **Only esg_meta has FORCE RLS in this baseline**; S1's
initial all-false summary was corrected in its issue addendum. Ten business
read policies and user_roles self-read remain unchanged. out_user retains
SELECT on category/country and CRUD on esg_meta; no direct out_user policy is
added. Its real membership/usage is unknown, so retaining its explicit grants
must not be described as proving its production effective access.

## Twenty previously open functions

All rows except full-text target owner/service_role EXECUTE; other explicitly
granted named roles (if any on the actual target) are not revoked. A role that
relied only on PUBLIC loses that inherited access and needs explicit review.

| Function | Purpose and caller boundary |
|---|---|
| claim_parse_two_stage_task | Worker takes eligible expired/unlocked parse task and obtains payload/URLs |
| register_parse_two_stage_task | Worker records external task and archives queue message |
| mark_parse_two_stage_task_state | Worker updates async state/lease |
| mark_parse_local_ready | Worker publishes local artifact metadata |
| mark_processed_s3_ready | Worker finalizes artifact/job/document |
| fail_job_v2 | Worker records failure and optionally retry wakeup |
| replay_parse_local_ready_from_artifact | Trusted repair operation, enqueue/idempotent S3-ready recovery |
| verify_kb_api_key | Next/Edge service verifies full token hash/scopes/revocation, updates usage |
| authorize_kb_api_key_collection_action | Service token plus collection/action authorization; audit effects |
| has_service_role | Legacy user_roles boolean helper; arbitrary UUID is not caller authentication |
| resolve_document_search_partition | Backend document routing; no ordinary-user filter |
| resolve_query_search_partitions | Backend query routing; no ordinary-user filter |
| kb_default_collection_search_partition | Internal collection trigger |
| kb_normalize_collection_path | Internal path normalization helper |
| kb_set_updated_at | Internal timestamp trigger |
| set_created_by | Existing metadata trigger |
| set_last_updated_by | Existing metadata trigger |
| set_last_updated_time | Existing metadata trigger |
| esg_full_text | Preserve invoker EXECUTE and RLS; Edge uses publishable client with session |
| standards_full_text | Preserve invoker EXECUTE and RLS; Edge uses publishable client with session |

`has_service_role` does not govern KB management. Current capability evaluation
uses kb_grants/kb_group_members; removing ordinary execution of this legacy
helper does not replace those checks with user_roles.

## Worker identity versus consistency

A `p_worker_id` string is not proof of identity. The database role must first
have EXECUTE. Service credentials are trusted backend credentials; they can
still supply another worker's ID. S9 does not promise per-worker isolation
between holders of the same credential.

| RPC | Existing consistency checks and effects, unchanged |
|---|---|
| claim | Running parse, undeleted, task_id exists (no explicit document-version comparison), lock null/expired; updates owner/expiry and returns task payload |
| register | Running parse, matching locked_by, nonexpired lease, undeleted; archives transport; no explicit document-version comparison and SQL NULL comparisons are not an identity guard |
| mark state | Running parse, matching owner, future lease, task_id; no joined document/version guard; updates payload and lease |
| mark local | Running parse, matching owner, future lease, job/document version match, undeleted; updates document artifact |
| mark S3 | Same lock/version/deletion guards; finishes job and updates document |
| fail v2 | Running + matching owner; **no expiry check**; version constrains document update, not job failure; no explicit deleted guard |
| replay | Matching job/document version, parse, undeleted; failed/dead or expired running; running NULL/future lease rejected; no owner comparison (repair); deduplicates follow-up job/message |

These pre-existing differences are documented, not normalized in this ACL fix.
Deletion triggers can cancel jobs; clearing a synthetic deleted_at alone does
not restore a job. Regression fixtures explicitly restore only their own rows.

## Roles, schemas and unresolved target facts

Local replay evidence: public USAGE includes PUBLIC/API roles/journals_reader;
CREATE is held by pg_database_owner. private/api USAGE is only postgres and
service_role. postgres and service_role have BYPASSRLS, ordinary API roles,
out_user and journals_reader do not. authenticator can SET ROLE to anon,
authenticated and service_role (NOINHERIT). No additional membership for those
ordinary/named roles appears in this isolated replay. This is **not** a capture
of production role membership, schema ACL or default ACL.

Local pg_default_acl inspection also finds broad postgres-owned public table/
function defaults. They are intentionally **not fixed by S9**: future objects
can regain broad privileges. This existing-object migration is not a global
least-privilege guarantee. Default-ACL policy and future-object regression need
a separate reviewed scope; target default ACLs are an explicit release check.

No schema privileges, memberships, defaults, login secrets or BYPASSRLS flags
are changed. Effective-privilege tests include a fresh untrusted role to catch
PUBLIC access, actual denied SQL, real Auth JWT HTTP, and a dedicated synthetic
worker granted only public USAGE + one worker EXECUTE (no direct table read).
Unknown real worker login roles and unexpected inherited/column grants must be
reviewed before release; if effective anon/user privileges remain after a
catalog-only revoke, stop rather than silently applying wider role changes.

## Validation and consumer limits

The ordinary local gate runs SQL denial tests and real Auth/PostgREST worker
flows both after fresh replay and populated prior-chain upgrade. Existing
smokes cover token authorization, routing, triggers, Jobs/index/delete, queue
lifecycle, retry, RLS and audit. Exact catalog equality detects unrelated changes.

The separate consumer harness executes actual Next resource/API-key/Jobs
routes, Edge search handlers including course bearer verification, journal
code, and Unstructure's seven actual psycopg adapters. Supabase/Auth/PostgREST
are real; external search/LLM/Redis providers are doubles. Course Redis always
misses: revocation with a previously cached token and cache TTL remain existing
release risks, not solved or claimed tested here. These tests do not parse PDF,
read NAS, contact external indexes or establish deployed consumer versions.
HTTP/adapter fixtures commit only in the owned disposable stack; stop destroys
that stack and its synthetic rows. The generic catalog fixture cleanup alone
does not remove the S9 worker scenarios.

## Release and recovery gates

This candidate must remain unmerged. Before any separately authorized release:

1. Bind exact migration/source SHAs, database target, migration history, backup,
   application/worker revisions and deployment ordering. Include the qualified
   Next #88 error mapping and matching consumer expectation. Verify hosted pending
   migration set; never replay the historic baseline or expand this to S2–S8.
2. Read target schema/table/function/column/default ACLs and role memberships
   with authorized read-only access. Identify actual Next/Edge service identity,
   Unstructure direct-DB login and inherited roles, journals_reader and out_user.
   Verify target enforcement of the owner-confirmed internal_use reader scope
   (all authenticated users). Owner reports no independent deployments/direct
   DB callers; this does not replace the deployed identity inventory.
3. Stage the same versions on a verified preview, repeat SQL/HTTP/consumer gates,
   and ensure worker identities have only required explicit grants. No missing
   role should be invented or broad service_role membership granted by default.
4. Stop for unknown active consumer/role, unexpected privileges, blocked normal
   calls, schema/body/policy drift, missing backup, or failing preview. Do not
   merge merely because the local tests pass; main can trigger hosted deployment.

Recovery is a reviewed **forward compensation** for an identified legitimate
role and exact function/table operation, followed by the same negative tests.
Do not restore PUBLIC, anon/authenticated writes, TRUNCATE or all old grants.
The transaction-scoped dedicated-worker test exercises such a minimal grant
and proves unrelated function/table access stays denied; rollback removes the
test role/grant. A production compensation cannot be preapproved without its
actual consumer role. Table/data rollback is unnecessary for this ACL-only
migration; do not edit an applied migration or claim a backup restore was tested.


## Follow-up identity qualification

See [role/consumer evidence and authorized online follow-up](s9-role-consumer-evidence.md). A true synthetic LOGIN proves seven S9 and six support adapters with explicit grants, while direct pgmq/snapshot paths expose additional schema/RLS dependencies. The online read confirms service_role lacks pgmq USAGE too, but a temporary PM2 identity probe using 148's current worker configuration connects as postgres (BYPASSRLS, not SUPERUSER) with the required object privileges. This narrows the current-identity compatibility concern; it does not qualify full processing, historical PM2 overrides, a new 142 role or post-S9 behavior. Both Next deployments still contain pre-#89 resource-store code. No permissions, application code or migrations were changed; the probe was stopped and removed.


The subsequent [development-validation round](s9-development-validation.md)
qualifies complete local worker scheduling against the same S9 migration,
including a non-superuser capability-equivalent direct login and the paired
Next #89 index/delete schedulers. Its external transports are doubles; hosted
source/identity binding, preview, rollout and operational qualification remain
separate release gates. This does not authorize merge or permission changes.
