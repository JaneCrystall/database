---
docType: reference
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When qualifying S9 consumer identities or requesting target read-only evidence."
whenToUpdate: "When consumer revisions, local role probes, owner decisions or target evidence change."
checkPaths:
  - tests/consumers/unstructure_role_boundary.py
  - tests/consumers/worker_role_contract.json
  - tests/consumers/test_worker_role_boundary.py
lastReviewedAt: 2026-10-15
lastReviewedCommit: 1d98ac400ff07d0829f59f177290e0a1ff8799d2
---

# S9 role and consumer evidence

This extends [S9's ACL contract](legacy-permissions.md), not its migration.
No application SQL, RLS policy, deployed role or worker is changed. A local
LOGIN probe is **not** evidence of the deployed login. S9 remains incomplete
until the actual deployment-to-role mapping and preview qualification exist.

## Evidence levels and owner statement

- **Source:** tracked code determines credential selection, calls and worker ID
  construction. It does not establish which process/version is deployed.
- **Local:** owned disposable runtime, synthetic rows and synthetic LOGIN;
  role flags, identities and denied calls are tested, not inferred from owner
  sessions. Existing service-role consumer evidence remains a separate category.
- **Owner confirmation (2026-10-15):** users query through skills/Edge Functions;
  the owner reports no independent deployments or direct-database callers.
  Record these query users as indirect consumers of the existing service chain,
  not as new database principals per person. This closes the owner-questionnaire
  item; it is not a live credential or deployment inventory.
- **Owner policy decision (2026-10-15):** `internal_use` may be read by all
  authenticated users. Preserve that reader boundary; it does not authorize
  anonymous reads or ordinary-user writes. This records intent only, with no
  permission or RLS change. Target enforcement still needs verification.
- **Target:** none read this round. No .env, credentials, NAS, production rows,
  live APIs, or 142/148 services inspected. Actual role mapping is still unknown.

## Reviewed source versions

| Repository | Exact source revision |
| --- | --- |
| Unstructure | `c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67` |
| Next | `1c28a030bbcb138cb98592a467cff5c737a0d2bb` |
| Edge | `4ef643da900ab1faf5eaaaa9c27b27f0343a159a` |
| CLI | `fee12538aca7bc35f8dfb0da3bbd7d5836a61124` |
| Skills | `5e692461708a4e02c1012086a59d2bd75da99673` |

Selected files match those revisions; unrelated dirty sibling files are not
qualified. Receipts bind the actual imported adapter bytes by SHA-256. These
are source versions, not a claim about installed CLI/skill or hosted versions.

## Identity and consumer matrix

| Consumer / path | Source-selected database identity | Permission demand and evidence boundary |
| --- | --- | --- |
| Skill → CLI → Edge search | Skill/CLI sends HTTP API key or bearer; Edge determines the DB role | `agent-skills/tiangong-kb-sci-search/SKILL.md` and CLI `src/edge-search.ts` show Functions HTTP calls. SCI standalone wrapper pins CLI 0.0.62; managed research uses its own locked broker. Endpoint overrides and installed versions need inventory, not a live search. This evidence concerns query paths, not every CLI command. |
| Edge edu/ESG/standard/SCI | Publishable client plus authenticated user session; authorization flow varies by handler | Preserved SELECT/RLS and invoker full-text functions. Existing local Edge harness covers these actual handlers; provider transports are doubles. No proof of all other search handlers or deployed keys. |
| Edge course bearer path | `SUPABASE_SECRET_KEYS.default` creates service client; publishable client separately validates user sessions | `verify_kb_api_key`; explicit service EXECUTE survives S9. Existing bearer valid/invalid/revoked probes are real local DB calls. Redis always misses in the harness. A skill query key is not itself proof of the downstream DB role. |
| Next ordinary resources | Cookie/session authenticated role via SSR client | Six legacy resource groups: SELECT remains; writes return safe 403 with PR #89. Anonymous writes 401. |
| Next admin/APIkey/THU | Server-side `SUPABASE_SERVICE_ROLE_KEY`; application actor/capability checks remain distinct | Backend CRUD/controlled RPCs and read-only THU route; service-role failure stays 500, not an ordinary-user 403. |
| Next index/delete workers | `createServiceRoleClient()` via PostgREST | Queue wrappers, claim/start, heartbeat, complete/fail/archive, index-record RPCs and direct reads of jobs/documents/collections/search partitions. Existing harness covers selected adapters, not full external indexing/deletion. No deployment role inferred from environment variable name alone. |
| Unstructure parse / submitter / finalizer / s3-ready | Direct psycopg login selected from DSN/config; no code-level `SET ROLE` | Queue + control-plane RPCs + direct snapshot reads. New local LOGIN probe separates these three access layers. |
| Unstructure reconciler / snapshot commands | Same config-selected direct login | SELECT jobs/documents/collections through existing RLS; reconciler additionally replay + archive-by-ID. RPC-only grants do not authorize these reads. No PDF/NAS scanning performed. |
| Journal collection and legacy processing scripts | Collector and scripts' configured direct DB login, not necessarily `journals_reader` | Existing journal qualification proves selected collector behavior under fixture credentials. Scripts under Unstructure `src/journals` use `POSTGRES_USER`; no source-only claim about deployed login, schedules or role membership. |
| `journals_reader`, `out_user` | Named roles from captured SQL, not a proven consumer mapping | Reader probe and out_user isolated RLS denial remain valid. Real LOGIN/inheritance/owner mapping still required; do not assume these names identify an active process. |

Source anchors:
[Unstructure config](https://github.com/tiangong-ai/unstructure/blob/c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67/src/kb_parse_worker/config.py),
[control plane](https://github.com/tiangong-ai/unstructure/blob/c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67/src/kb_parse_worker/control_plane.py),
[queue](https://github.com/tiangong-ai/unstructure/blob/c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67/src/kb_parse_worker/queue.py),
[snapshot](https://github.com/tiangong-ai/unstructure/blob/c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67/src/kb_parse_worker/snapshot.py),
[reconciler](https://github.com/tiangong-ai/unstructure/blob/c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67/src/kb_parse_worker/reconciler.py),
[Next service client](https://github.com/tiangong-ai/web-app/blob/1c28a030bbcb138cb98592a467cff5c737a0d2bb/lib/supabase/service-role.ts),
[Edge course](https://github.com/tiangong-ai/edge-functions/blob/4ef643da900ab1faf5eaaaa9c27b27f0343a159a/supabase/functions/course_search/index.ts),
[CLI transport](https://github.com/tiangong-ai/cli-toolkit/blob/fee12538aca7bc35f8dfb0da3bbd7d5836a61124/src/edge-search.ts).

Unstructure configuration precedence is `DATABASE_URL` → `SUPABASE_DB_URL` →
`KB_DATABASE_URL`, then discrete `POSTGRES_*`/`SUPABASE_DB_*` fields. Environment
loading can use `src/.env` and dotenv discovery; templates do not fix a DB login.
`KB_PARSE_WORKER_ID` or `hostname-pid` supplies a **lease identifier**, not a
PostgreSQL identity. Next worker IDs similarly come from runtime configuration;
no worker ID is an authentication boundary between holders of shared credentials.

## Local role probe and the newly reproduced gaps

Run `tests/consumers/unstructure_role_boundary.py --target <owned-local-target>`
with the existing KB Python environment. It rejects preview/production, remote
Docker, ownership/port mismatches and inactive sessions before importing adapters
or connecting. It creates a random LOGIN with no role memberships, NOINHERIT,
NOSUPERUSER and NOBYPASSRLS; `session_user=current_user` is asserted. Passwords
are ephemeral, never printed or written to a report. Role/grants are removed in
finally; synthetic rows belong to the disposable stack and vanish on stop.

The grant list in `worker_role_contract.json` describes **test phases**, not an
approved production role. No grants are added to migration history. The function
negative matrix covers the 18 restricted plus six supporting RPCs, not every
public function. The retained esg_full_text/standards_full_text PUBLIC grants
still apply to the synthetic role; this is not an entire-database least-privilege
certificate.

| Phase | Observed result / meaning |
| --- | --- |
| Before explicit grants | All seven S9 RPC calls denied with 42501. Other restricted functions/support RPCs remain denied (trigger functions checked by effective EXECUTE only). |
| Seven S9 grants | Seven unchanged real control-plane adapters pass register/claim/state/local/S3/fail/replay, including wrong owner denial and replay deduplication. This is a true nonowner LOGIN test, not postgres followed by SET ROLE. |
| Six support RPC grants added | Actual claim, heartbeat, complete-local/enqueue-S3, complete-S3, archive and archive-by-ID adapters pass; unrelated table writes, TRUNCATE and SET ROLE service_role remain denied. |
| Queue and snapshot without direct grants | The same role cannot call `pgmq.read` or load the actual snapshot query. Seven or thirteen successful RPCs do not establish whole-worker readiness. |
| Existing service_role | Snapshot read succeeds, but direct `pgmq.read` fails **42501, schema pgmq** in the reconstructed local chain. No schema USAGE or queue SELECT/UPDATE is present for this role. BYPASSRLS does not bypass schema ACL. |
| Test-only pgmq USAGE + read EXECUTE + two queue SELECT/UPDATE grants | No row is returned despite an owner-visible queued fixture: queue RLS has no matching policy. This would look like an idle poll even with pending jobs, so queue emptiness must not be accepted as a successful worker check. Unrelated index queue access stays denied. Runtime read resolves to `pgmq.read(text,integer,integer,jsonb)` (INVOKER), with a default fourth argument; don't infer a three-argument function signature from the Python call. |
| Test-only SELECT on the three snapshot tables | Zero jobs visible under existing RLS; the real snapshot adapter still cannot obtain its fixture. SELECT alone does not close the custom-role gap. |

Both queue and snapshot RLS gaps are **existing access-model constraints**, not
introduced by S9's new REVOKEs. They now have discriminating local evidence.
The standard SQL smoke suite uses controlled database functions; it cannot
substitute for the direct Python queue/snapshot path. The prior seven-adapter
service-role receipt did not cover these paths either.

Do not fix this by granting service_role membership/BYPASSRLS or broad table
access automatically. First establish the deployed login and exact effective
permissions. If a dedicated worker role is desired, controlled queue/snapshot
interfaces or reviewed role-specific RLS require a separately scoped decision.
This round proves a compatibility gap under the tested identity, not an observed
production outage. It does not restart a worker to discover its credentials.

The seven S9 names include legacy `mark_parse_local_ready` and
`mark_processed_s3_ready` adapters. Current worker orchestration instead uses
`complete_parse_local_ready_and_enqueue_s3_check` and `complete_s3_ready_check`.
`archive_job_message` is present in the adapter module but current orchestration
uses archive-by-ID. Keep adapter coverage separate from active orchestration.
The snapshot query is used by normal worker processing, not only recovery.

## Pending target read packet — NOT EXECUTED OR AUTHORIZED

The requested outputs below are metadata/identity facts only. Agree target,
operator and time window before any execution; no connection from this round.

| ID / target | Exact scope of proposed read | Output / purpose |
| --- | --- | --- |
| R1: existing Knowledge Base Supabase project `qyyqlnwqwgvzxnccnbgm` (confirm binding before connection) | `pg_roles` flags (not pg_authid/passwords), relevant `pg_auth_members` including INHERIT/SET options; public/pgmq/api/private schema ACL; 24 public table + column ACL/RLS/policy metadata; 18 restricted and six supporting public RPC ACL/security/search_path; pgmq read signatures/ACL + four worker queue q/a table ACL/RLS; owner-specific public/pgmq default ACL; enum USAGE where relevant | Actual role → effective operation matrix for anon/authenticated/service_role, real worker login, journals_reader/out_user, owner. Use privilege predicates; **do not invoke worker/queue RPCs**, which mutate state. Capture installed PG/pgmq versions. No function bodies, business rows or arbitrary SQL logs. |
| R2: same project migration ledgers | Version/name metadata from Supabase migration ledger and filename metadata from legacy kb_schema_migrations; no stored SQL statement export | Identify installed chain/pending S9 and prevent historical replay; no repair/push. |
| R3: 192.168.1.142 Next deployment under `/home/dell/projects/`, and existing 192.168.1.148 Next/Unstructure deployment (exact directories/process names to be confirmed) | Selected process names/status, executable/cwd, release SHA/image digest; credential **source variable name and nonsecret role mapping only**. Operator parses locally and reports DB host/project, login username, session_user/current_user, role flags; never transmits DSN/password/token or full env/process dumps. Installed skill/CLI source and endpoint versions only if maintained here. | Bind actual processes to source and R1 role. No restart, PM2 save/reload, sync, checkout, NAS scan or test job. Stopped processes stay stopped; templates are not proof of active identity. |
| R4: existing Edge deployment targeting the same KB project | Function names/deployed versions; source-to-project binding; which credential class maps to service role vs user-session flow, confirmed by operator without secret values. Relevant existing routes: edu/esg/standard/sci/course plus any additionally enabled query endpoints | Bind skill/CLI endpoint → deployed handler → DB role. No secret list values, sign-in attempts, live skill queries, redeploy or cache writes. No Management API writes. |
| R5: remaining owner decisions | Confirm journals_reader/out_user owners/use. Already confirmed: no independent deployments/direct DB callers; internal_use is readable by all authenticated users | Complete remaining policy intent and verify target enforcement of the confirmed reader scope. Do not change RLS while collecting evidence. |

If role mapping remains ambiguous, an optional, separately approved short
`pg_stat_activity` **aggregate** by usename/application_name can corroborate
active clients. Exclude query text, SQL literals and unrelated sessions. Absence
of an idle/stopped client never proves it does not exist. No query logging or
pg_stat_statements is enabled for this task.

For R1, run only reviewed SELECTs in a read-only transaction with bounded
statement/lock timeouts. A SELECT that calls a mutating function is excluded.
If privilege to inspect metadata is missing, report the gap; do not grant extra
roles. Receipts stay private until reviewed and sanitized. Later preview tests
must reproduce the actual role mapping without copying production credentials.

## Acceptance disposition

Source consumer inventory and owner questionnaire are recorded. Dedicated LOGIN
RPC evidence and negative dependency boundaries are now stronger. AC2 still
needs actual-role mapping and complete worker qualification; AC4 still needs
out_user intent/target facts and target enforcement of the confirmed internal_use
reader scope; the owner classification decision is closed. AC5's known caller
list includes skill/Edge users, while deployed identity confirmation remains.
AC6/8 still require exact preview/release versions and authorized integration.
No merge, root pin update, migration or 142/148 action follows from this report.
