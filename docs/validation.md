---
docType: runbook
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "Before submitting or integrating database changes."
whenToUpdate: "When test commands, qualification scope or CI changes."
checkPaths: [scripts/**, tests/**, .github/workflows/**, .docpact/**]
lastReviewedAt: 2026-10-15
lastReviewedCommit: 33c3b417182b72349e36d0b6cf44a26e4be31c2c
---

# Validation

For schema tooling changes, run:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests must cover offline import provenance and immutable migration bytes, schema grouping, preservation of
the changes overlay, path confinement, failure handling and non-leaking
subprocess errors. They do not require remote credentials.
Migration authoring tests include same-second different-name collisions and
concurrent attempts; dump tests reject protected paths and existing exports.

For migration, SQL test or local runtime changes, also run:

```sh
scripts/test-database.sh
```

This gate qualifies the committed KB chain on a dedicated local Supabase
runtime and executes the SQL smoke tests with SQL errors fatal. In the same
temporary stack it also exercises real CLI schema export, offline object
generation and TypeScript generation, verifying the `kb_documents` contract.
All generated qualification files stay in the temporary workdir. Imported
tests that require explicit fixtures must receive isolated, documented
fixtures; do not edit published migration history to mask a test failure.
When an imported smoke fixture is stale, record its failing assertion and make
the smallest test correction in a commit after the byte-identical import.
No passing local result establishes remote state or full legacy-schema
coverage. For changes affecting an existing deployment, also qualify the
relevant prior-schema-to-head upgrade on a disposable database.

For every PR:

```sh
scripts/docpact validate-config --root . --strict
scripts/docpact lint --root . --staged --mode enforce --format json --output .docpact/runs/latest.json
git diff --check
```

Use `--base <sha> --head <sha>` after committing. Stage all new files before
using `--staged`; `--worktree` alone excludes untracked additions. A source-only
lint probe must require review of the owning architecture/development docs.
CI runs offline tests, local SQL qualification and the PR documentation gate.

The PR records the tested commit, commands/results, source provenance,
consumer compatibility and operational limits. Root integration additionally
requires the reviewed child SHA, paired KB consumer revision, exact gitlinks,
repo graph and root governance evidence. Production application is separate.

Hosted integration changes additionally require the official Supabase Preview
check and preview catalog qualification before applying the verified pending
production migration. Follow `docs/supabase-integration.md`; local green tests
do not authorize repairing unapplied history entries.

The legacy baseline requires exact parity for 24 public tables, 72 functions
and all 11 enum definitions, plus the real consumer matrix in
`docs/legacy-schema-baseline.md`. Run `unittest discover -s tests/consumers -p
'test_*.py'` for lifecycle safety and sibling-source discovery checks. The offline
source checks cover canonical precedence, legacy fallback, missing directories and
explicit journal path overrides without opening a database connection.
Empty local and verified preview targets must independently pass catalog and
consumer qualification; no production
business-data fixture or database mocking is permitted.

`tests/schema/legacy_behaviors.sql` supplements catalog equality with real
trigger/RPC/RLS/role behavior using rollback-scoped synthetic records. It runs
in the local gate and on the verified preview, never production.

M1 resource qualification additionally runs actual concurrent psql sessions and
a prior-chain upgrade with synthetic rows using the same disposable local gate.
The pre-resource 40-file catalog uses `pre_resource_catalog.expected.json`;
head uses the current public fixture including the Jobs optimization plus
`resource_catalog.expected.json`. Every selected fixture is checked exactly.
Offline regression tests reject cross-generation function bodies and ACL drift.
`DATABASE_TEST_CATALOG_OUTPUT` may select a local output file for catalog-only
review evidence; it contains definitions, not business rows or credentials.
See [resource-contract.md](resource-contract.md) for covered cases and limits.

The resource schema boundary gate additionally starts real local PostgREST/Kong,
runs HTTP role/exposure/lifecycle checks, and tests a populated old-resource
schema upgrade. `tests/schema/resource_boundary.sql` checks exact ACL/schema
contracts; SQL statements also execute denied table operations for each API
role. Only new private/api objects enter the additive catalog; the legacy public
snapshot must not be regenerated to accept unrelated changes. Client type
qualification explicitly includes public/api and excludes private tables.
The type assertion accepts quoted and unquoted schema keys emitted by the
official generator. CLI failure handling must preserve its exit status; the
offline runtime-safety tests verify failed startup cleans only the owned stack.

## Jobs timeout regression

The local gate also runs `tests/runtime/qualify_jobs_upgrade.py`: on its owned
stack it restores only the changed Jobs function from the immutable previous
migration, checks the permission/filter/sort fixture against that definition,
and applies the new forward migration. OID, owner, ACL, parameters, return type,
security-definer/search-path and volatility must remain identical. All other
prior-schema objects are unchanged; the full smoke suite then tests the new body.

`tests/sql/kb_admin_jobs_permissions_smoke.sql` compares against the unchanged
single-document permission helper for user/group, collection/subtree/document,
owner/creator/public, revoked/expired and deleted-document cases. It covers all
sort keys and both directions (including null timestamps/ties), filters, empty
pages, normalization and service-role/anonymous execution privileges.

`tests/performance/kb_admin_jobs.sql` inserts rollback-scoped synthetic data:
20,000 documents, 60,000 jobs, 100 collections, 101 grants. Its seven calls must
finish within a transaction-local 5-second statement timeout. The fixture does
not read environment credentials or production data. It is a bounded capacity
regression, not a statement of production scale, latency or hosted remediation.
See [the investigation record](jobs-list-timeout.md). Catalog expectations update
only the intentionally changed Jobs function fingerprint.


Resource/delete concurrency qualification uses two real sessions and blocking
PID barriers. It exercises the actual resource command against actual
`request_delete`, verifies a retryable lifecycle-busy conflict (HTTP adapter SQLSTATE `PT409`)
instead of `40P01`, confirms no partial resource/receipt changes, and checks that deletion
and a retry with the identical request UUID/payload preserve cleanup ownership. Fixtures run
only in the uniquely owned disposable stack, never production.


Hosted HTTP qualification uses an actual legacy table route to prove that the
ordinary-user JWT reaches PostgREST; hosted OpenAPI introspection is restricted
to secret keys. Resource semantic conflicts must return HTTP 409 promptly on
both the pinned local runtime and hosted runtime. A rollback-scoped SQL probe
checks private/API error separation and preserves unexpected serialization
failures. This prevents a local-only HTTP 500 assertion from hiding hosted
transaction retries.


S9 adds `tests/runtime/legacy_permissions.sql` and `legacy_permissions_api.py` to fresh and populated-upgrade gates. They qualify PUBLIC inheritance, actual ordinary-role SQL/HTTP denial, custom-worker minimal grants, and seven service worker RPC effects. The current catalog accepts only the reviewed 18-function/23-table ACL delta. See [legacy-permissions.md](legacy-permissions.md) for consumer coverage and release limits.

With the Next #88 candidate, `run_web_edge.py --only next` requires exact safe
403 for all six legacy groups' POST/PATCH/DELETE, anonymous-write 401, unchanged
stored rows and no insert residue. Source hashes in its receipt bind the tested
Route Handlers and store; durable PR evidence also records both repository SHAs.
This fixes the previous consumer 500 blocker locally but does not qualify
hosted defaults, actual worker login identities or authorize release.


The local-only `tests/consumers/unstructure_role_boundary.py` adds real LOGIN qualification and explicit queue/snapshot failure boundaries; run it through the owned consumer runtime. `test_worker_role_boundary.py` rejects mismatched ports, ownership and nonlocal targets without DB access. See [S9 role evidence](s9-role-consumer-evidence.md). This is a separate consumer test, not automatically part of database-only CI.


For S9 complete local worker orchestration, use `unstructure_worker_flow.py` in
`tests/consumers/README.md`. It runs the real five Unstructure `run_once` paths
with a fresh non-superuser LOGIN and real PostgreSQL/pgmq. Run both fresh-head
and `--acl-upgrade` modes; the latter reconstructs only the precise pre-S9 ACL
delta with a queued fixture, not all old function bodies. The full database
gate independently covers prior-chain replay/upgrade. Next consumer qualification
also runs actual index/delete schedulers with real PostgREST and index ledger.
Only external provider/artifact transports are doubled. These consumers remain
separate from database-only CI and require reviewed sibling sources/dependencies.
See [the development result and deployment gates](s9-development-validation.md).
