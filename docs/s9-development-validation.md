---
docType: reference
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When deciding whether S9 development qualification is complete or planning deployment acceptance."
whenToUpdate: "When the worker harness, tested consumer revisions, receipts or deployment blockers change."
checkPaths:
  - tests/consumers/unstructure_worker_flow.py
  - tests/consumers/test_worker_flow_safety.py
  - tests/consumers/worker_route.ts
  - tests/consumers/next_consumer.mjs
lastReviewedAt: 2026-10-15
lastReviewedCommit: d0e137fcf568d98cbfa6b93648ff3430321bfcf0
---

# S9 development validation and deployment handoff

Development qualification of the reviewed candidate is complete locally;
**deployment acceptance remains pending**. This does not close S9, approve a
merge, promote a root gitlink, or authorize deployment. Database #18 is now
ready for review; paired Next #89 remains draft. No SQL migration, existing role, RLS policy,
application implementation or 142/148 service changed in this round.

The scope is permission compatibility through actual worker orchestration.
External parsing quality, provider delivery, NAS synchronization, hosted build
identity and process supervision require deployment acceptance. See the
[online evidence](s9-role-consumer-evidence.md) for earlier observations and
[ACL contract](legacy-permissions.md) for the unchanged migration boundary.

## Exact candidate and identity boundary

- S9 SQL remains `20261015081907_narrow_legacy_public_permissions.sql` unchanged.
- Next is `1c28a030bbcb138cb98592a467cff5c737a0d2bb` (PR #89).
- Unstructure imported worker files match reviewed `c4d0aa3a28836d0a5425ec1c538ff295d3aa6c67`;
  every worker package file is SHA-256-bound in the receipt. Unrelated dirty
  sibling documentation is not part of this qualification.
- Edge is `4ef643da900ab1faf5eaaaa9c27b27f0343a159a`; the receipt binds actual
  imported handlers/shared modules by SHA-256.

The Python worker uses a fresh LOGIN with NOSUPERUSER, its own BYPASSRLS and
explicit USAGE/EXECUTE/SELECT/UPDATE grants matching the required capability
subset observed for 148's configured postgres identity. It is **not an owner**;
explicit grants plus BYPASSRLS emulate needed access, not hosted ownership,
memberships or the future 142 login. This test profile is not a production
least-privilege recommendation. Each real short connection, including heartbeat
connections, asserts session_user=current_user and flags before worker SQL.
Fixture seeding and temporary role administration are separate connections.
The parser response is held behind a bounded event barrier until a second,
successful real heartbeat occurs in the background thread; each run records 15
successful heartbeat calls. The CLI argument-dispatch layer is not executed.

A restricted NOSUPERUSER/NOBYPASSRLS LOGIN executes the same ParseWorker scheduler
and fails with 42501 before claim; the seeded job is unchanged. Both queue tables
must have RLS enabled and no policies. This preserves a discriminating negative
control instead of obtaining green results through superuser access.

## Executed local matrix

| Path | Real operations and assertions |
| --- | --- |
| Synchronous parse | pgmq read → claim → heartbeat → snapshot → raw-path/hash validation → parser/embedding HTTP → local artifacts → finalization/S3 job creation → archive |
| S3 ready | claim/snapshot → actual local manifest and remote-object size/hash comparison → completion/document state → archive; corrupted object fails and later retry recovers |
| Two-stage parse | backlog prevents claim; submit/register/archive; finalizer claims and persists STARTED/POLL_ERROR; SUCCESS finalizes; FAILURE follows existing retry policy and recovers |
| Reconciler | real durable artifacts with synthetic interrupted finalization; dry-run leaves job unchanged; replay restores state and queues S3 work; repeat run does not enqueue again |
| Guards/recovery | terminal duplicate does not invoke parser; invalid raw hash goes dead; transient HTTP failure creates backoff/wakeup and recovers; stale-version/deleted documents stop before provider effects |
| Next index | real runIndexWorkerOnce reconciliation, queue read/claim, snapshot, heartbeat, ledger record, completion and archive; document becomes completed and a second run is empty |
| Next delete | authorized request_delete, real runDeleteWorkerOnce claim/snapshot/heartbeat, completion and archive; document becomes deleted and a second run is empty |
| Paired application | six resource groups POST/PATCH/DELETE return safe 403, anonymous writes 401, stored rows unchanged; API-key lifecycle, Jobs, humanities scope and outsider denial |
| Edge | actual edu/ESG/standard/SCI handlers plus course bearer valid/invalid/revoked against real local Auth/PostgREST; provider doubles and cache-miss limitation retained |

The Python matrix passed in fresh-head and **populated ACL-delta upgrade** modes,
103 verified worker connections each. Upgrade mode reconstructs precisely the
old S9-targeted grants, seeds a queued job, applies the unchanged S9 migration,
and verifies the job is unchanged before processing. It does not reconstruct
all old function bodies. The independent full database gate covers complete
prior-chain replay/populated upgrades, including SQL and real Auth/HTTP denial.

The complete prior-chain gate does not rerun the cross-repository worker-flow
matrix; its schema/SQL/HTTP upgrade evidence complements the two scheduler runs.
Only external transports are doubled: loopback parser/embedding HTTP, S3 object
reads backed by temporary local files, and Next artifact/index/cleanup targets.
No database function/store/queue/snapshot/claim/lease/completion is mocked.
The public hosted database-only CI does not have the private sibling source
dependencies; these consumer runs remain separately recorded local evidence.

Local validation: 78 repository offline tests (including 30 consumer safety
tests), full `scripts/test-database.sh` (17 SQL smokes, real Auth/PostgREST,
resource concurrency, capacity/catalog/toolchain and populated upgrade), the two
Python matrices, and the combined Next/Edge consumer run passed. No dependency
upgrade was needed; the repository's pinned Supabase CLI 2.120.0 was used.

## Remaining consumer mapping

Additional local Edge source was reviewed for patent/report/textbook/internal/
Green Deal search and question_generation/kg_generate/info_extract. These use
publishable-client Auth/session validation (search variants have the existing
email cache); their inspected active handlers have no direct calls to the 18
restricted worker/helper RPCs or 23 narrowed table writes. The shared function
logger writes to OpenSearch, not these public tables. This is source impact
analysis, not additional handler execution or proof of deployed credentials.

The five entrypoints absent from this checkout have now had their deployed
bundles reviewed read-only; see the dated supplement in
[consumer evidence](s9-role-consumer-evidence.md#deployed-edge-source-supplement-2026-10-15).
The actual slug is `sci_search_fast`, correcting the earlier `sci_fast` label.
None calls the narrowed worker/helper RPCs or table writes; SCI-fast reads
`journals`, whose SELECT/RLS contract is unchanged. Both auth-bench endpoints
are HTTP 410 tombstones. This closes the missing-source dependency inspection,
not the runtime credential binding, Git provenance or hosted compatibility gates.
The earlier owner statement of no independent deployments/direct callers does
not substitute for this mapping. Retired journals_reader/out_user cleanup is
separate; other unnamed legacy principals are not automatically declared retired.

## Deployment acceptance gates — pending; no production authorization

1. Identify exact Next/Edge/worker builds and runtime credential classes,
   including nonsecret deployment binding/provenance for the five now-inspected
   hosted entrypoints. Source credential selection is not an observed login.
2. Fix the release tuple: database S9 plus Next #89, reviewed consumer revisions
   and lockfiles. Rebuild from clean source; current 142/148 deployment files
   cannot stand in for this tuple. Do not deploy the database ACL change alone.
3. Run the same compatibility/negative cases on an explicitly verified Preview,
   using actual intended role attributes and hosted gateway configuration.
   External parser/storage/index and real task recovery need separate evidence.
   The 2026-10-15 branch inventory contains only KB main, so no hosted Preview
   acceptance has run. LCA's persistent dev belongs to another parent project
   and is not a KB test target. See the consumer-evidence supplement for the
   LCA workflow comparison and the unresolved fork-PR Preview path.
4. Before any 142 worker migration, decide its identity, single-instance process
   management and trial queue scope. Current 142 Next is systemd-managed; moving
   it to PM2 is not part of this permission change. Do not run old/new consumers
   concurrently by accident. Any config-precedence change requires new identity
   verification without exporting credentials.
5. Obtain separate merge/deployment authorization, follow reviewed forward
   recovery and verify service health. Keep 148 unchanged until the later agreed
   migration acceptance. Default ACL, retired-role and benchmark cleanup remain
   separate work.

AC2/6 have their local orchestration evidence; AC4 policy intent is recorded.
AC5 deployed mapping and AC6/8 hosted/release requirements remain open. Project
state stays In Review and Issue #17 stays open; “development validated” is a
bounded handoff status, not a claim that all original acceptance boxes are done.

## Evidence retention

Private, nonsecret receipts are in the operator's `s9-worker-20261015` artifact
directory. They contain source/harness hashes, results and explicit double/role
limits, not credentials or production rows. SHA-256:

- fresh flow: `8ac56cff76b82bc24a1eda070bc63d179461151434b4fb9a6f10bc9bbad2339e`;
- populated ACL upgrade flow: `84e3af246c0a06e3fd04dc0e5f5286dd3c409599b04e576ea45852a865e1c8e0`;
- Next/Edge flow: `ce568d005effeee6d67756a9fbdab61cd6380acf096e3d7e3b348688aa72359a`.

Cleanup completed: synthetic web/Auth fixtures were removed; both consumer
sessions were stopped with container/volume absence verified by the runtime,
and their private target files were removed. Python provider threads shut down,
temporary artifact directories and LOGIN roles were removed. Synthetic archive
and audit rows were disposed with their owned stacks. The earlier failed setup
stack was also stopped, and the full database gate removed its own stack.
Independent Claude Code review found no blocking implementation issue; its
heartbeat/cleanup/upgrade-scope clarifications are incorporated. This is not a
GitHub review approval.
