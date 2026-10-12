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
lastReviewedAt: 2026-10-12
lastReviewedCommit: a17367cbb824f94b04f63779e8d68b299fdec3e4
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
