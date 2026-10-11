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
lastReviewedAt: 2026-10-11
lastReviewedCommit: 45198730c6217992902b6f0b203a417961c6bdee
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
`docs/validation.md` owns required proof.

## Sources and operating boundaries

- `supabase/migrations/*.sql` is the sole writable migration history. Preserve
  existing filenames and bytes; corrections use new migrations.
- `tests/sql/*.sql` contains the imported KB smoke tests. Provenance and import
  digests live in `docs/source-inventory.json`.
- `supabase/workspace/remote_schema.sql`, `global/` and `schemas/` are generated
  local inspection files; keep edits in `supabase/workspace/changes/`.
- Never commit credentials, environment bindings, database rows or remote
  dumps. Review SQL definitions for embedded secrets before publishing.
- Local development is the default. Remote reads require an explicit target;
  remote migration application is a separate operator action, never CI's job.
- The imported chain is the KB control plane, not a complete production
  snapshot. Missing legacy/domain schemas are listed in `docs/architecture.md`.
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
