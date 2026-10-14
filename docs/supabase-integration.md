---
docType: runbook
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When operating the Knowledge Base GitHub Integration or initial history adoption."
whenToUpdate: "When project/repository mapping, activation gates or deployment ownership changes."
checkPaths: [supabase/**, docs/supabase-adoption-evidence.json, scripts/**]
lastReviewedAt: "2026-10-14"
lastReviewedCommit: "70d66ade42ce932a6670f1286dfd6b62538259b1"
---

# Supabase GitHub Integration

The existing **Knowledge Base** project (`qyyqlnwqwgvzxnccnbgm`) in
`linancn's Org` connects to `tiangong-ai/database`, working directory `.`.
It is not the TianGong LCA project. The operating contract is production
branch `main`, automatic PR branches limited to three, and **Supabase changes
only** enabled. The user authorized separate preview compute charges and
preview qualification before production activation on 2026-10-11.

The [adoption task](https://github.com/tiangong-ai/database/issues/3) records
live switch readbacks, exact PR/commit, preview proof and production completion.
This guide defines the procedure, not proof that an unexecuted step succeeded.
GitHub Actions still target local disposable databases. Hosted deployment
belongs to the official Supabase GitHub Integration; this repo declares no
Edge Functions or Storage buckets.

## Historical adoption

The read-only [evidence snapshot](supabase-adoption-evidence.json) records the
pre-adoption state and rerunnable catalog queries. It retains no credentials,
business rows, function bodies or benchmark fixture data.

- The original KB filename ledger contains 34 applied files: 33 in the initial
  import and a May 28 hotfix from KB commit
  `8473292ce24f61a75a397ac7128c524da15c5872`. That hotfix is restored byte for byte;
  its two RPC bodies, three indexes and service-role timeout were observed live.
- Supabase's ledger initially contains the June ingest-health migration and
  two October temporary benchmark versions. Preserve these three existing
  records and their stored statements unchanged.
- The benchmark files are explicitly labeled no-op **adoption receipts**, not
  copies of the temporary fixture SQL. Their original statement hashes and
  observed final object absence are recorded. Fresh replay does not re-run
  disposable benchmarks.
- Of the 66 final KB function bodies, 65 match production after restoring the
  hotfix. The July `20260715100748` health optimization is genuinely pending.
  Never mark it applied merely to make the ledgers agree.

## Activation sequence

1. Keep **Deploy to production** off. Changing a connected repository can reset
   this switch to on; immediately read back and preserve off until gates pass.
2. Run the local 38-file chain, SQL smoke and real toolchain gate. Require the
   adoption PR's local CI and official **Supabase Preview** check. Query that
   preview's catalog to verify the July function body and migration versions.
3. Rerun the evidence SELECTs immediately before reconciliation. Require the
   expected project, ledgers, existing Supabase statement digests, function
   fingerprints and hotfix/benchmark facts. Stop on new differences. Save a
   private pre-operation metadata snapshot and previous function definition;
   this operation does not modify business rows.
4. With CLI 2.120.0, run `supabase migration repair <versions...> --status applied
   --db-url "$SUPABASE_DB_URL"` for **only** the 34 verified legacy versions.
   This changes history metadata, not schema or rows. Preserve all original
   records and the old KB ledger. Read back 37 Supabase versions and unchanged
   digests for the three existing records.
5. Run `supabase db push --dry-run --include-all --skip-vault --db-url
   "$SUPABASE_DB_URL"`. Require exactly July as pending; `--include-all` is
   needed because it predates the October receipt versions.
6. After preview qualification and reviewed source merge, apply that exact
   pending migration with `supabase db push --include-all --skip-vault --db-url
   "$SUPABASE_DB_URL"`. Verify the deployed body, ACL, version count and a
   read-only health invocation. Metadata alone is not deployment proof.
7. Require an empty push dry run, then enable **Deploy to production** for
   `main`. Read back repository, working directory, production branch, preview
   limit and Supabase-only filter. Preserve screenshot and checks in the task.

Use secure operator environment configuration for the URL; never print it,
commit it, include it in PR text or retain unredacted CLI diagnostics. Do not
use history repair to conceal an unexecuted or failed migration.

## After adoption

New migrations are reviewed here, qualified locally and on a PR preview, then
deployed from `main` by Supabase. The legacy KB runner remains compatibility
code; **do not run it against this adopted production project**, because its
independent filename ledger does not own new migrations. The later legacy schema capture is documented in `legacy-schema-baseline.md`.
Its production-read-only capture does not itself authorize marking or replaying
the new baseline against existing production objects.

Preview compute is separate usage and not covered by the Spend Cap. Avoid
abandoned PR branches. See [GitHub Integration](https://supabase.com/docs/guides/deployment/branching/github-integration)
and [branching usage](https://supabase.com/docs/guides/platform/manage-your-usage/branching).

## M1 resource schema rollout (not activated by local development)

The additive boundary migration moves only the new resource objects into
`private` and installs `api` invoker entrypoints. Before merge/deployment,
qualify the exact chain on the official preview, including real PostgREST role
and exposure checks. Read the hosted exposed-schema list, preserve existing
schemas and `public` as the default, add `api`, and keep `private` unexposed.
Never use a blanket grant on all schema objects. Exact gateway function grants
are in the migration. The checked-in local API config alone is not evidence of
hosted configuration. Coordinate new clients to explicitly select `api` only
after these checks; existing public clients continue unchanged. No profile or
resource intake is activated by schema migration. This development revision
does not authorize main merge, hosted setting changes or 142/148 rollout.
