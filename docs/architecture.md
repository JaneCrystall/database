---
docType: architecture
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When deciding source ownership, schema scope or generated-path boundaries."
whenToUpdate: "When schema ownership, imported scope or consumer contracts change."
checkPaths: [supabase/**, scripts/**, tests/sql/**, docs/source-inventory.json]
lastReviewedAt: 2026-10-15
lastReviewedCommit: 951192ce32389c43c4a54f1638aea59ef7550e1a
---

# Database architecture

## Source ownership

`supabase/migrations/` is the authoritative migration chain for the AI KB
control plane. Existing migrations are immutable after publication; append
corrections with a new migration. `tests/sql/` owns database-side smoke tests.
The import manifest records the source repository, revision, original path and
SHA-256; it describes the import, not the state of a live database. The initial
byte-identical import was committed as `45198730c6217992902b6f0b203a417961c6bdee`.
Migration hashes remain enforced. Smoke tests may be corrected as the schema
evolves; their manifest hashes describe the original import, not a prohibition
on maintaining tests. Preserve the import commit through a merge commit.

KB ingestion, worker orchestration and the existing operator migration runner
remain consumers in `tiangong-ai/knowledge-base`. That runner resolves this
repository through `KB_DATABASE_DIR` or a workspace sibling named `database`.
Web and Edge clients remain in their owning repositories. Their application
types, search-index mappings and historical BigQuery queries are not database
schema sources and were not moved.

## Adopted schema

The 35 imported migrations define the KB control-plane tables, enum types,
RPCs, RLS, API-key authorization, ingestion queues, retry/reindex behavior,
partition metadata and health queries. They require PostgreSQL with `pgcrypto`,
`pgmq`, and the Supabase roles (including `service_role`). General/course
partition configuration contained in those migrations is preserved.

Hosted-integration adoption restores the already-applied May 28 hotfix and adds
two no-op receipts for cleaned-up remote benchmark versions. These additions
make 38 replay files and are separate from the immutable initial import. See
`supabase-adoption-evidence.json` for source and live catalog evidence.

The subsequent read-only legacy baseline capture supplies the missing content
schema, authorization helpers and empty legacy ledger structure. The full public
application catalog contains 24 tables, 72 functions and 11 enums. Its exact
columns, defaults, constraints, indexes, triggers, RLS/policies, ACLs and function
fingerprints are enforced by `tests/schema/public_catalog.expected.json`.
See [legacy baseline](legacy-schema-baseline.md) for capture provenance,
portable-role differences, consumer qualification and the production-read-only
boundary. Platform-managed schemas and extension internals remain owned by
Supabase; production data, identities and role memberships are never imported.

## Schema workspace

Schema export is a local inspection artifact. `remote_schema.sql`, `global/`
and `schemas/` are regenerated and ignored by Git. Splitting groups statements
by object for review; it is not a dependency-ordered database restore. Unknown
statements remain inspectable rather than being discarded.

Copy the intended object into `supabase/workspace/changes/` before editing.
The overlay survives refresh. Write explicit migration SQL and review it;
object snapshots do not imply safe `ALTER`, `DROP`, or data-conversion plans.
Generated TypeScript in `types/` is local until a consumer explicitly adopts a
reviewed contract. No fabricated production types are committed at bootstrap.

## Environments

`local` is the default tool target. `dev` and `main` are explicit operator
environment names backed by ignored local env files; they do not assert that
hosted targets through local env names. The Knowledge Base GitHub Integration
is governed by `docs/supabase-integration.md`; Git uses one `main` trunk. LCA
project refs, auth URLs, schemas and branch bindings are not part of this repo.

## Opt-in M1 resource contract

The additive resource registry and trusted-gateway RPC boundary are defined in
[resource-contract.md](resource-contract.md). Existing metadata tables remain
the fact source for legacy adapters. No collection/profile is activated by the
migration; processing and review state remain separate.

New M1 resource state lives in unexposed `private`; `api` contains only the two
invoker adapters, with privilege elevation in private implementations. This
incremental boundary does not move existing public business/control tables.
The table-by-table authority and writer matrix lives in the resource contract.

## Jobs list authorization

`20261013091317_optimize_kb_admin_jobs_authorization.sql` resolves the actor's
user/group principals and active grants once per `list_kb_admin_jobs` call,
matching the existing Documents RPC and single-document helper semantics.
Read visibility still excludes deleted documents; reindex/delete/manage grants
still expose their jobs. Revoked/expired grants and null actors remain excluded.
The six arguments, service-role-only ACL, 21 returned columns, precise count,
filters, offset pagination and timestamp/UUID tiebreaks are unchanged. Empty
pages still contain no count row, as required by existing Next consumers.
No index, role timeout or single-document helper is changed.
See [Jobs timeout evidence](jobs-list-timeout.md) for measured scope and limits.


Resource lifecycle mutations take job locks before document locks and reject
contended locks without waiting. The forward lock-conflict migration preserves
legacy worker/delete implementations and converts resource contention to an
atomic, retryable lifecycle conflict. It does not activate resource intake.

The invoker API command adapter translates only known resource business
conflicts into `PT409` / HTTP 409. Private SQL semantics stay unchanged; unrelated
serialization failures retain their original code. This transport boundary
avoids treating a permanent business conflict as a retriable database transaction.


S9 narrows only legacy public ACLs under [legacy-permissions.md](legacy-permissions.md). It keeps object locations, bodies, RLS, M1-03 and legacy-role explicit grants; deployment is separately gated.
