---
docType: agent-contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "Before changing Tiangong AI database sources or tooling."
whenToUpdate: "When ownership, validation, branches or entrypoints change."
checkPaths:
  - AGENTS.md
  - .docpact/config.yaml
  - supabase/**
  - scripts/**
  - tests/**
  - docs/**
lastReviewedAt: 2026-10-15
lastReviewedCommit: 697163cba2e52fe0416e37341cd5b532f104b383
---

# Tiangong AI Database Contract

This repository owns the Tiangong AI knowledge-base PostgreSQL/Supabase
migration history and database-side SQL tests. KB ingestion and application
code remain in `tiangong-ai/knowledge-base`; web clients and workers remain in
`tiangong-ai/web-app`; Edge Functions remain in `tiangong-ai/edge-functions`.
The LCA database repository is a workflow reference only, never an AI schema
or deployment source.

Read this file, `.docpact/config.yaml`, then run `scripts/docpact route --root .
--paths <csv> --format json` and read the recommended docs before editing.
`docs/architecture.md` owns source/generated boundaries and adoption scope;
`docs/development.md` owns commands and database targeting;
`docs/validation.md` owns required proof; `docs/supabase-integration.md` owns
the hosted GitHub Integration and initial history adoption.

## Sources and operating boundaries

- `supabase/migrations/*.sql` is the sole writable migration history. Preserve
  existing filenames and bytes; corrections use new migrations.
- `tests/sql/*.sql` contains the imported KB smoke tests. Provenance and import
  digests live in `docs/source-inventory.json`.
- `supabase/workspace/remote_schema.sql`, `global/` and `schemas/` are generated
  local inspection files; keep edits in `supabase/workspace/changes/`.
- Never commit credentials, environment bindings, database rows or remote
  dumps. Review SQL definitions for embedded secrets before publishing.
- Local development is the default. Remote reads require an explicit target.
  Hosted deployment follows the preview/adoption gates in the integration
  runbook; ordinary GitHub Actions never receive production DB credentials.
- The source chain includes the captured public application schema. Validate
  catalog parity and actual consumers under `docs/legacy-schema-baseline.md`;
  platform-managed schemas, production rows and login identities are excluded.
- Production schema capture is read-only. Do not merge the baseline while
  automatic deployment would replay it on existing production objects without
  an explicitly authorized metadata-adoption plan.
- Do not mix the existing `public.kb_schema_migrations` ledger with Supabase's
  migration ledger without a reviewed reconciliation. Moving files alone does
  not mean an existing database should replay them.

## Delivery and validation

The daily trunk and routine PR base are `main` (M1). In the integration
workspace, use its delivery controller before implementation. After child
merge, the workspace must pin the exact reviewed commit before completion.
Standalone contributors open a PR against `main` with the proof required by
`docs/validation.md`.

Run offline tests and local SQL qualification for migration/tooling changes.
Run strict docpact validation and lint with an explicit diff source. New files
must be included using `--files` or `--staged`. The wrapper pins docpact 0.1.9;
optional hooks are installed with `scripts/install-git-hooks.sh`.

New resource storage/implementation is unexposed `private`; externally callable
resource adapters are `api`. Preserve existing public objects and historical
migration bytes. The resource contract owns per-table authority, grants and
actual HTTP qualification; local API config never proves hosted exposure.

S9 legacy ACL changes follow `docs/legacy-permissions.md`: isolate qualification,
retain explicit consumer-role evidence and keep release authorization separate.

S9 role/consumer evidence and proposed read-only target scopes are maintained in
`docs/s9-role-consumer-evidence.md`; synthetic roles never establish deployed identities.
