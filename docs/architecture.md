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
lastReviewedAt: 2026-10-11
lastReviewedCommit: a022a6c67d6ed57565a7a433f347c815f4d88e2c
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

The source checkout did **not** supply a full DDL baseline for legacy content
tables such as `edu_meta`, `esg_meta`, `standards`, `reports`, `internal_use`,
`green_deal_meta`, `journals`, and `journals_issn`, or the
`esg_full_text` / `standards_full_text` RPCs. Do not invent these definitions or
claim that successful control-plane tests establish the full production DB.
A future import must use an explicitly identified, read-only schema export,
review public-source suitability, and reconcile dependencies and migration
history before adopting it. Database rows are outside this repository.

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
