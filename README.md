---
docType: repo-entry
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When starting work with the AI database repository."
whenToUpdate: "When setup, purpose or repository contents change."
checkPaths: [supabase/**, scripts/**, tests/**, docs/**]
lastReviewedAt: 2026-10-11
lastReviewedCommit: a38d22f
---

# Tiangong AI Database

The PostgreSQL/Supabase source repository for the **Tiangong AI knowledge
base**. It starts with 35 existing KB migrations and 16 SQL smoke tests,
preserving their original bytes and migration names. A subsequently recovered
KB hotfix and two explicit benchmark history receipts bring the replay chain
to 38 files. Two further migrations capture the remaining public application schema and
explicit existing object privileges, bringing the chain to 40 files without
production data. It does not contain the Tiangong LCA database.

[中文说明](README.zh-CN.md) · [Architecture](docs/architecture.md) ·
[Development](docs/development.md) · [Validation](docs/validation.md)

## Quick start

Install Python 3.11+, Docker and Supabase CLI **2.120.0**. No Python packages
are needed for offline schema tooling.

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
scripts/test-database.sh
```

The database gate starts a dedicated local Supabase stack, applies the committed
migration chain and runs the SQL smoke tests. It does not target a hosted
database. See the development guide for inspection and migration authoring.

```text
supabase/migrations/       authoritative KB migration history
tests/sql/                database-side KB smoke tests
supabase/workspace/        generated object view and durable changes overlay
scripts/                  schema export, splitting, migration and type tools
docs/source-inventory.json original KB source revision and file digests
```

The source now reconstructs all 24 captured public application tables and 72
functions. [Legacy baseline](docs/legacy-schema-baseline.md) defines the catalog
parity and actual Next/Edge/journal consumer tests. Production data, Auth user
identities and role passwords are never exported. The original legacy baseline
is for fresh local/preview rebuilds; production history adoption is a separate
reviewed operation, not implicit permission to replay existing DDL.

This repository uses `main` for development and PRs. CI validates local
databases; the existing Knowledge Base project connects through the official
[Supabase GitHub Integration](docs/supabase-integration.md). Its adoption task
records preview qualification and production activation evidence.
