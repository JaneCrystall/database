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
lastReviewedCommit: 697163cba2e52fe0416e37341cd5b532f104b383
---

# S9 role and consumer evidence

This extends [S9's ACL contract](legacy-permissions.md), not its migration.
No application SQL, RLS policy, deployed role or worker is changed. A local
synthetic LOGIN probe is **not** evidence of the deployed login. The authorized
online follow-up below adds current-configuration identity evidence; S9 remains
incomplete until the remaining deployment mapping and preview qualification exist.
The latest development-only result is recorded in
[S9 development validation](s9-development-validation.md); earlier rounds below
retain their original evidence limits.

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
  permission or RLS change. Catalog enforcement was subsequently checked in the
  authorized follow-up below; no business-row query was performed.
- **Initial local round:** no online information was read. The separate,
  subsequently authorized online round is dated and scoped below; it does not
  retroactively upgrade the synthetic identity evidence.

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
| `journals_reader`, `out_user` | Named roles from captured SQL, not a proven consumer mapping | Reader probe and out_user isolated RLS denial remain valid. Online role attributes and owner retirement confirmation are recorded below; do not equate retained grants with active use. |

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

## Original target read packet — authorization and results below

The original request below was metadata/identity only. The owner subsequently
authorized its execution on 2026-10-15. Remaining unknowns are not implicitly
authorized writes or permission changes.

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

## Initial local acceptance disposition

Source consumer inventory and owner questionnaire are recorded. Dedicated LOGIN
RPC evidence and negative dependency boundaries are now stronger. AC2 still
needs actual-role mapping and complete worker qualification; AC4 still needs
out_user intent/target facts and target enforcement of the confirmed internal_use
reader scope; the owner classification decision is closed. AC5's known caller
list includes skill/Edge users, while deployed identity confirmation remains.
AC6/8 still require exact preview/release versions and authorized integration.
No merge, root pin update, migration or 142/148 action follows from this report.

## Authorized online follow-up — 2026-10-15

The owner authorized the read packet, then confirmed all KB workers are stopped,
were previously on 148, and will later move to 142. The owner additionally
authorized a short PM2 start/check/stop. This was implemented as a **separate
configuration/identity probe**, not by starting the consuming worker loops.
The owner subsequently confirmed `journals_reader` and `out_user` are retired,
with cleanup deferred to separate work. Their existing roles, memberships and
grants are retained; this is owner attestation, not a credential-revocation audit.
No password/token/configuration value was displayed, exported or retained.
The probe let the existing application loader use its existing configuration
internally for normal authentication. No credential file or process environment
was dumped, no secret-management API was queried, and no key was decoded.

Only identity/catalog SELECTs and session-local read-only/timeout settings were
used. No queue/RPC operation, business row, PDF/NAS access, external search,
permission change, merge, deployment or Next restart occurred. Remote mutations
were limited to the explicitly authorized temporary probe and its cleanup.

### Target and effective permission findings

Knowledge Base project binding was verified through the connector before SQL.
PostgreSQL is **17.6**, pgmq **1.5.1**. SQL used read-only transactions with bounded
timeouts. Both original ledgers were read without exporting stored statements:
45 Supabase versions through `20261014162521`; 34 legacy filenames. The explicit
ACL capture `20261012035302` is recorded; S9 `20261015081907` is **not applied**.
Live ACLs independently confirm the expected pre-S9 broad grants.

| Observed item | Finding / consequence |
| --- | --- |
| Old public tables | 24 exist with RLS enabled. anon/authenticated retain all six S9-targeted mutation/object privileges on 23 tables; kb_index_records remains excluded from these ordinary grants. In particular, 23 effective TRUNCATE grants remain. No destructive call was attempted. |
| Internal public functions | All 18 S9 targets remain executable by anon/authenticated and PUBLIC-inheriting roles. Six support functions are separately restricted. service_role and postgres have EXECUTE on all 24 inspected functions. These are privilege predicates, not live RPC invocations. |
| pgmq direct read | `pgmq.read(text,integer,integer,jsonb)` is INVOKER with default PUBLIC EXECUTE. service_role has no schema USAGE or SELECT/UPDATE on the four inspected parse/S3 queue/archive tables; postgres does. Queue RLS is enabled with no policies. PUBLIC EXECUTE alone does not make the queue callable. |
| Snapshot tables | jobs/documents/collections have RLS with no ordinary reader policies. postgres owns them and has BYPASSRLS; service_role has SELECT and BYPASSRLS. Neither fact makes a new custom role viable. |
| internal_use | SELECT policy is `TO authenticated USING (true)`; no ordinary write policy or anon read policy was found. Reader intent matches the owner's decision. The old table-level mutation/TRUNCATE grants remain for S9 to remove. This is catalog proof, not a user-session data query. |
| journals_reader | LOGIN, INHERIT, no SUPERUSER/BYPASSRLS; journals SELECT and its explicit read policy exist. No general worker/queue entitlement. Owner confirms retired; separate cleanup, no grants changed here. |
| out_user | NOLOGIN, no BYPASSRLS; one named login inherits this role. ESG SELECT and esg_meta DML grants exist, but no matching RLS policy permits that role. Owner confirms retired; membership observation is not proof of active use or revocation. |
| Additional legacy identities | A separate admin login has BYPASSRLS and inherits authenticated; two named logins inherit standard_user. Personal role names stay in the private receipt. Do not revoke these or assume the owner's no-external-consumers statement means the roles do not exist. Their intended use still needs an owner decision. |
| Column/default/enum privileges | No explicit public column ACLs were found. Broad public defaults for postgres/supabase_admin still grant ordinary roles future table/sequence/function privileges. Enum USAGE and effective schema/table/function matrices were captured. Future-object default hardening remains separate scope. |

The isolated captured baseline deliberately creates journals_reader as NOLOGIN
(`tests/test_legacy_schema.py` asserts this); live LOGIN is an observed difference,
not proof the isolated role reproduces every deployed property. Preserve both
evidence levels and use live attributes for the retirement follow-up.

A one-time connection aggregate contained two postgres/Supavisor sessions and
no identified KB application class. No query text, client SQL, raw application
strings or business data was read. This cannot identify a stopped worker or
prove absence of other consumers. Role membership also does **not** inherit the
special LOGIN/SUPERUSER/BYPASSRLS attributes; inspect the effective role's own
flags rather than inferring them from service_role membership.

### Deployment and actual current-configuration identity

| Host / consumer | Observed deployment facts | Remaining limit |
| --- | --- | --- |
| 142 Next | `/home/dell/projects/tiangong-ai-next`; user systemd `tiangong-next.service` active/running, PID 4162748 on 7300. The dell PM2 daemon has no apps. | It is currently systemd-managed, despite the expected PM2 arrangement. No manager conversion was performed. |
| 148 Next | `/home/david/apps/tiangong-ai-next`; PM2 `tiangong-kb-next` online, PM2 app PID 3437, Next PID 3628 on 7300. No KB workers in that PM2 list. | Stale PID files are historical remnants, not running-worker evidence. Other users/containers are not exhaustively certified absent. |
| Both Next checkouts | Same BUILD_ID `nhfBW00kDQ7S1bodJHUWO`; service/server client and index/delete adapter hashes match reviewed local files. Both resource-store hashes match pre-#89 `0420f0a`, not #89 `1c28a03`. | Selected source/BUILD_ID equality does not identify the complete release SHA or prove which credential class the running processes use. Later release must include the paired 403 fix. |
| 148 Unstructure checkout | `/home/david/projects/TianGong-AI-Unstructure`, HEAD `07f65ef100300d7cb44996476af8a033a9ae8bbc`; existing .venv Python available. config/control-plane/queue/snapshot bytes match reviewed local source despite different repository HEAD. | No claim of complete repository/build parity or historical PM2 environment parity. |

Both deployed package.json hashes are
`f20df19b20bbc957a23a6d0493f26890af906dc9571db23e8223baf47f47fcd3`,
matching historical `7060634`, and differ from reviewed Next #89. Selected
application files matching newer source does not qualify this dependency/build
combination. A later release must rebuild from a clean, exact reviewed commit
and lockfile; do not reuse the current deployment directory as a release proof.

At **18:44:34 Asia/Shanghai** the PM2 probe using that Unstructure configuration
established `session_user=current_user=postgres`, LOGIN/INHERIT/BYPASSRLS true,
**SUPERUSER false**. It used the discrete-field configuration branch and the
pooler. This role has public/pgmq/api/private USAGE, all thirteen worker/support
RPC EXECUTEs plus pgmq.read EXECUTE, and SELECT/UPDATE on the inspected queue
and snapshot tables. Together with ownership/BYPASSRLS, the catalog explains
why the synthetic custom-role and service_role direct-queue gaps do not apply
to this current configured postgres identity.

The initial two probes exited before catalog reads because startup options did
not persist through the connection path. The successful probe enforced and
verified **transaction_read_only=on, statement_timeout=5s, lock_timeout=1s**
inside its transaction; observed startup defaults were off/2min. It rolled back
and closed. This changes only the diagnostic transaction, not server defaults.
All attempts had no autorestart and a 30-second outer timeout. The final probe
was explicitly stopped/deleted; temporary script/log files were removed.
The 148 Next PID and unrelated existing PM2 app were unchanged; 142 was
observed running and received no probe or service operation.

This is observed identity for **a new connection using today's checkout/config
loading path**. It does not prove historical PM2 overrides, the future 142
identity, full worker initialization/processing, or behavior after S9. Predicting
that S9 preserves this postgres role's grants is narrower than certifying a
production worker restart. Do not replace this with the false claim that
postgres is a superuser on hosted Supabase.

### Edge consumers and evidence limits

The same project reports 18 active Edge Functions. Relevant query versions:
edu 144, ESG 155, SCI 141, course 12, standard 97, patent/report 129,
textbook 51, internal 65, Green Deal 19, SCI-fast 14. Other enabled names include
internet_search, question_generation, kg_generate, info_extract,
synology-file-manager and two auth-bench-68 functions. No handler was invoked,
secret read, function body downloaded or deployment modified.

Version and bundle digest metadata establishes enabled deployment inventory,
not an exact source-commit or runtime key-role binding. Existing source/harness
proof covers the stated subset only; unreviewed enabled endpoints and the two
benchmark endpoints require owner/deployment mapping before a complete consumer
claim. `verify_jwt=false` alone does not establish missing authorization because
some handlers implement application authentication.

### Remaining blockers and proposed disposition

1. **Narrow the direct-worker blocker:** current 148 configuration uses postgres
   with the required ACL/RLS capabilities. No grant repair is indicated for that
   identity by this read-only evidence. Keep the runtime/preview gate open; test
   the same role properties with synthetic fixtures against S9 before release.
   Future migration to a dedicated role on 142 requires a separate design for
   controlled queue/snapshot access and RLS. Do not broaden grants in S9.
2. **Keep the paired application gate:** both deployed resource-store files are
   pre-#89. Any later S9 rollout must pair the reviewed Next #89 fix, exact source
   versions and preview tests. Do not deploy database ACL changes alone.
3. **Close the answered policy items, defer legacy cleanup:** internal_use's
   intended and catalog reader boundary are established; the owner confirms no
   independent deployments/direct callers and stopped KB workers. The owner also
   confirms journals_reader/out_user are retired, with later separate cleanup.
   Additional unnamed legacy identities are not automatically certified retired
   by that named-role confirmation. Do not delete roles or broaden S9 here.
4. **Finish deployed consumer mapping:** Next/Edge runtime credential class,
   exact deployed source mapping and enabled endpoint coverage remain partial.
   Use nonsecret operator/deployment evidence and controlled preview checks;
   no passwords/tokens are needed in an audit receipt.
5. **Separate operations decisions:** converting 142 Next from systemd to PM2,
   migrating/re-enabling workers, least-privilege role design, default-ACL
   hardening and benchmark-endpoint cleanup are not implemented by this audit.
   Coordinate the intended runtime/role before the 142 worker migration. Repeat
   identity verification after configuration changes: adding a higher-priority
   DSN variable can change the login selected over today's discrete fields.

AC2 is stronger but not fully closed: configuration identity and effective
capabilities are observed, full worker and post-S9 behavior remain unqualified.
The named legacy-role intent and internal_use classification questions in AC4
are closed by owner confirmation plus catalog evidence; credential retirement
enforcement is separate follow-up. AC5 remains partial for full deployed mappings; AC6/8
for exact preview/release and authorized integration. PR #18 was draft at this observation;
Next #89, migration bytes, M1-03 and root gitlinks are unchanged.

Private receipts are retained under the operator's `s9-online-20261015` artifact
directory, not committed as remote metadata dumps. SHA-256 anchors:

- Role/ACL/ledger/Edge metadata: `707985f7eeff827fc860f7c5b5f7bb2b277feab9c11e54d0f0fb06573c3b72d6`.
- Effective privilege matrix: `3768fa1a757b1d58c19643942a8f93b7a5820419f0a43c8c5b9bad19184303c9`.
- Successful identity receipt: `31e229bec09af2f3b4eb9251402ecf2f926a7d3f3ca36dbf294ebe2cb2c9ef88`.
- Exact diagnostic script: `e4941d7ad9d38e3b1b3ade1d19977bfc883ac8c992aaa66b4b18e2c36a1ce789`.

## Deployed Edge source supplement — 2026-10-15

The owner authorized deployed-source/identity inspection and Preview acceptance,
with no secret-value inspection, merge, production mutation or 142/148 action.
Supabase `get_edge_function` returned the five deployed bundles absent from the
local entrypoint inventory. Review output and retained local snapshots mask
string literals except allowlisted environment/role/table identifiers; comments
are removed. No secret/configuration values were requested, handlers invoked,
NAS contacted or production data queried in this supplement.

| Deployed entrypoint | Version / gateway JWT | Source-defined identity and database dependency | S9 implication |
| --- | --- | --- | --- |
| `internet_search` | 95 / false | Publishable-client bootstrap; password sign-in on an auth-cache miss. Redis auth cache and external search/logger; no database table/RPC call in the bundle. | No narrowed operation identified. A cache hit does not prove a fresh authenticated session. |
| `sci_search_fast` | 14 / false | Publishable bootstrap and conditional user sign-in; global client/session, email cache and light/cache paths make identity path-dependent. Reads `journals`; no narrowed RPC or table write. | SELECT and RLS are preserved by S9. Hosted metadata-read behavior still needs qualification. Earlier `sci_fast` spelling was incorrect. |
| `synology-file-manager` | 95 / true | Gateway JWT check; backend uses `SYNOLOGY_URL`, `SYNOLOGY_USERNAME`, `SYNOLOGY_PASSWORD` to log into NAS. No Supabase client/table/RPC. | No database ACL dependency; NAS credential values and file operations were not inspected/executed. |
| `auth-bench-68-cache` | 8 / true | Handler unconditionally returns HTTP 410; no imports, environment reads, Auth/database client or network call. | Deployed tombstone, not an executing auth benchmark. |
| `auth-bench-68-nocache` | 3 / true | Same HTTP 410-only behavior. | Deployed tombstone, not an executing auth benchmark. |

Both search bundles choose `REMOTE_SUPABASE_URL` / publishable-key variables
before their `SUPABASE_*` fallbacks. This proves the selection logic, **not** the
configured target, key class/value or account used for any particular request.
There is no service-key selection in their inspected client construction.
`verify_jwt` is a gateway setting and cannot alone identify a database role.
An `ACTIVE` deployment record likewise does not prove benchmark activity.

Deployment-reported bundle anchors, retained with version metadata in private
sanitized snapshots under `s9-edge-preview-20261015`:

- internet_search: `a77503110d2c164860d0f4828768bdd14437309738ce16436c5305721f7e9d2d`
- sci_search_fast: `c9a3caaf41853d4702563fb121325ae51cce0193fbb3972427f0c4be2539fd0c`
- synology-file-manager: `f6d958da7e6ef64326d07fc839d942919e10dd6ecda6eff84f2ea71064df3f47`
- auth-bench-68-cache: `27c1b2129db536c1e59f73103aa25f54513fc432d736cd66088baefcf9e5bcdb`
- auth-bench-68-nocache: `31415cbc065ebd7e2e0b4652cf93b6f337060673e5fcddd7bf48fe454eac7010`

Missing-source inspection is closed for these five deployed versions. Git source
provenance, nonsecret configuration binding and exact hosted compatibility are
not thereby closed. Existing auth-cache/session behavior is outside S9; this
finding does not certify those handlers' authentication design.

Subsequent SHA-256 comparison (raw bytes hashed without exposing literals) found
that all five fetched `internet_search` files exactly match the tree at Edge
commit `c7afb6aefa09d365efdf7a5d5f46d7850ac309ee`. This establishes a matching Git
source tree, not which commit the deployment operator actually selected. The
other four entrypoint paths have no matching local-ref history; their inspected
deployed versions/digests remain the source anchors. SCI-fast shares three exact
helper files with history, but its entrypoint/logger are not proven by that match.

### Preview inventory and LCA comparison

The initial read-only branch inventory found only KB `main`, without a disposable
Preview. LCA had a healthy **persistent** `dev` branch in the same Supabase
organization, under a different parent project. That database contains LCA's
schema and cannot substitute for a KB S9 target. That inspection itself made no
branch changes; the subsequently authorized KB test is recorded below.

LCA's [branching contract](https://github.com/tiangong-lca/database/blob/6420b929915589a88c29b683137d928226398e45/docs/agents/supabase-branching.md)
and [workflow](https://github.com/tiangong-lca/database/blob/6420b929915589a88c29b683137d928226398e45/.github/workflows/supabase-dev.yml)
separate PR-scoped Preview, persistent dev and main production. Its custom
Preview job excludes fork PRs before credential authority. For eligible PRs it
requires the exact-head official Supabase Preview check, matches PR/branch/parent
and disposable branch identity, then validates hosted API boundaries. Credentials
are used by the background workflow with masking, not exposed as review evidence.
KB PR #18 is a fork PR and has no official Supabase Preview check at the observed
head `b9c5c28ea32eca3ff31a2bb6460b4ddc5b77666c`. LCA's policy does not establish
the cause of KB's missing check; KB integration/authority must be resolved rather
than copying LCA's project binding or claiming its check covers this PR.
Further GitHub inspection found that KB PR #10 was also from the same fork and
had a successful official Supabase Preview check. Fork origin therefore cannot
be treated as a blanket platform prohibition. This run's disposable branch was
subsequently associated with `feature/issue-17`; exact-head official check
creation still needs to be observed rather than inferred from that association.

Supabase subscriptions are organization-scoped; a separate organization plan
is not needed merely for another project in this organization. Preview runtime
usage is nevertheless separately metered; default Micro starts at $0.01344/hour
and Compute Credits do not cover Branching Compute. The actual invoice, discounts
and balance were not inspected. See [billing scope](https://supabase.com/docs/guides/platform/billing-on-supabase)
and [branch usage](https://supabase.com/docs/guides/platform/manage-your-usage/branching).

The selected target was a disposable KB Preview tied to the reviewed database
candidate and paired Next #89, with synthetic fixtures and explicit role/API
checks. An official PR Preview requires an authorized integration path; a manually
created isolated branch does not automatically satisfy that official-check gate.
The owner subsequently approved temporary KB Preview creation, background
Preview-only credential use without disclosure, and cleanup after testing.
The resulting branch is `s9-pr18-b9c5c28-20261015`, nondefault/nonpersistent,
with no production data copy. Management metadata confirmed ACTIVE_HEALTHY;
the migration dry run selected only S9 and its application succeeded. This is
an operator-created isolated branch, not an official PR-check result. The hosted
catalog, SQL/HTTP ACL, Next/Edge, journals and full worker matrices subsequently
passed; [results and receipt hashes](s9-development-validation.md#approved-hosted-preview-follow-up--2026-10-15)
record the exact scope and doubles. Temporary fixtures/roles and credentials
were cleaned, and the branch was deleted with a fresh inventory confirming only
main. The exact-head official Supabase check was still absent after branch
association and push; no integration setting or gate was bypassed. No production
credentials, LCA writes, 142/148 changes, merges or production deployments are
authorized by this comparison.
