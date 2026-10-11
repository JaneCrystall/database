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
preserving their original bytes and migration names. It does not contain the
Tiangong LCA database.

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

The imported source covers the KB control plane. Legacy knowledge-content
tables and RPCs whose definitions were absent from the source checkout are
documented gaps, not fabricated baseline migrations. Existing deployments use
a different migration ledger from Supabase CLI; read the adoption section in
[Development](docs/development.md) before any remote application.

This repository uses `main` for development and PRs. CI validates local
databases only; no hosted project or automatic deployment is configured.
