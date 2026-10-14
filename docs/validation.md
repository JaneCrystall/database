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
lastReviewedCommit: 2371302de0b5630ce3acfe739514340100e721c5
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
'test_*.py'` for lifecycle safety checks. Empty local and verified preview
targets must independently pass catalog and consumer qualification; no production
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
`request_delete`, verifies a retryable lifecycle-busy conflict instead of
`40P01`, confirms no partial resource/receipt changes, and checks that deletion
and a retry with the identical request UUID/payload preserve cleanup ownership. Fixtures run
only in the uniquely owned disposable stack, never production.
