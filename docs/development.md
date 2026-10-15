---
docType: runbook
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When exporting schema, authoring migrations or selecting a database target."
whenToUpdate: "When helper CLI contracts, dependencies or adoption steps change."
checkPaths: [scripts/**, supabase/config.toml, .env.*.example]
lastReviewedAt: 2026-10-15
lastReviewedCommit: 33c3b417182b72349e36d0b6cf44a26e4be31c2c
---

# Development

Use Python 3.11+ and Supabase CLI 2.120.0 (the verified stable version at
bootstrap). Docker is needed for local Supabase and schema dumping. Set
`SUPABASE_CLI=/absolute/path/to/supabase` when it is not on PATH. Tool scripts
use only Python's standard library. Discover each command's options with
`python3 scripts/<name>.py --help`.

## Local workflow

1. Run the offline unit tests, then `scripts/test-database.sh` for disposable
   local database qualification.
2. For an interactive local database, run `supabase start` from this repo and
   `supabase db reset --local`. Do not reset a database with data you need.
3. Export/inspect schema with `scripts/export_remote_schema.py` and
   `scripts/build_schema_workspace.py` (both default to local). The builder
   also accepts `--schema-file` for a schema-only SQL file without connecting.
4. Use `scripts/copy_workspace_file_to_changes.py` to copy a generated object
   into the changes overlay. Existing edits must not be overwritten silently.
5. Prepare explicit SQL, then use `scripts/new_migration.py`. This invokes
   `supabase migration new` to allocate the filename and writes only a local
   migration file. It does not apply SQL or infer destructive transformations.
6. Run the full local gate and review the migration. Use
   `scripts/build_database_types.py` when a consumer needs refreshed types.

Tool command-line usage and examples are available from `--help`; this keeps
argument definitions in one executable source. Scripts should be invoked with
`python3` unless their executable mode explicitly supports direct execution.

For example, after starting the local stack:

```sh
python3 scripts/build_schema_workspace.py --environment local --schemas public
python3 scripts/copy_workspace_file_to_changes.py --source-path supabase/workspace/schemas/public/tables/kb_documents/table.sql
python3 scripts/build_database_types.py --environment local --schemas public
python3 scripts/build_database_types.py --environment local --schemas public --check
```

The copied table definition is inspection context, not automatically valid
upgrade SQL. After writing an explicit change in a repository-local file:

```sh
python3 scripts/new_migration.py --name describe_the_change --source-path supabase/workspace/changes/reviewed_change.sql
```

Use a new version for each migration. Generation rejects an already allocated
timestamp even when the proposed descriptive name differs. The short-lived
`supabase/migrations/.migration-authoring.lock` serializes local authors;
after an interrupted process, verify its recorded PID is no longer running
before removing a stale lock.

Schema export replaces only the canonical generated `remote_schema.sql`.
`--output-file supabase/workspace/exports/name.sql` creates a new ignored export
and refuses to replace an existing file. Migration history, manual changes,
code and configuration cannot be selected as dump destinations.

## Remote reads

Select `--environment dev` or `--environment main` explicitly and supply
`SUPABASE_DB_URL`, or copy the matching `.env.supabase.<environment>.local.example`
to an ignored file without `.example`. Use a least-privilege schema-read
credential. No real target is included. Never paste URLs with credentials into
Git, PRs, logs or command arguments. Dumped SQL may contain sensitive function
literals even without rows; review it before sharing. The helper never applies
migrations remotely.

## Existing KB database adoption

The KB operator runner uses `public.kb_schema_migrations`, keyed by the complete
filename. Supabase CLI uses its own migration-history schema. These are
different ledgers. Before hosted adoption, existing deployments can use the KB
runner with `KB_DATABASE_DIR` pointing here; moving sources alone must not
trigger reapplication or automatic repair. After the Knowledge Base project's
explicit adoption, use Supabase history and its GitHub workflow instead.

Before changing that operational path: identify the target, take an operator
backup, read the existing ledger, compare all imported filenames and schema
state, and review an explicit reconciliation plan. Never run `supabase db push`
against an existing KB deployment merely because this repo has been added.
The old ledger has no content checksums; import hashes establish source-byte
continuity but cannot prove what was applied historically. Supabase local
replay proves the checked-in chain independently, not remote reconciliation.

Keep each migration's transaction boundary. Some enum additions must commit
before a later migration uses the new value. Hosted deployment and one-time
history reconciliation follow `docs/supabase-integration.md`. Operator execution
and its evidence require a tracked task with exact environment and revision.

## Governance

`scripts/docpact` locates and enforces version 0.1.9, matching the workspace.
Install the binary with `cargo install docpact --version 0.1.9 --locked` if
needed. `scripts/install-git-hooks.sh` installs the optional non-overwriting
pre-push gate, comparing to `origin/main`. Use an explicit base for stacked
changes. Run strict config validation and an explicit-diff lint before PRs.

## Complete application baseline qualification

Use `tests/consumers/README.md` for disposable target start, synthetic fixtures,
actual Next/Edge/journal execution and cleanup. Sibling discovery prefers the
workspace directories `web-app`, `edge-functions`, `knowledge-base` and
`agent-skills`; older directory names remain fallback candidates. Journal
`--kb-root` and `--skills-root` arguments explicitly select other checkouts.
The production-derived contract
is catalog-only and is checked by the ordinary local SQL gate. Never point
consumer fixtures at production, and do not merge an unreconciled baseline into
an automatically deployed main branch.

For M1 resource registration/review/publication integration, use the request and
recovery protocol in [resource-contract.md](resource-contract.md). Configure
profiles only on explicit isolated targets; RPCs do not read NAS files.

The full gate now includes local PostgREST/Kong for the resource boundary. Ports
and project IDs are unique; cleanup owns only that stack. Local gateway/user
JWTs are ephemeral and never printed by HTTP tests. No production credentials
are needed. Resource consumers explicitly use schema `api`; export inspection
with `--schemas public private api`, but generate consumer types with
`--schemas public api`. Hosted schema exposure is separately qualified as
specified in `docs/supabase-integration.md`.

The gate suppresses CLI success output that can contain ephemeral keys, filters
failure diagnostics, and preserves the original CLI exit status for cleanup
and failure detection.

The ordinary `scripts/test-database.sh` gate includes Jobs prior-schema upgrade,
role/filter/sort regressions and the synthetic 60,000-job capacity check. It owns
and removes its temporary local Supabase stack; never run the capacity fixture
against a hosted or developer database containing data to preserve. No hosted
migration is needed to reproduce or qualify the Jobs fix.


For resource clients, handle `RESOURCE_LIFECYCLE_BUSY` with the bounded retry
protocol in the resource contract. The combined migration gate keeps the
pre-resource catalog separate from the current Jobs/resource catalog and runs
the actual resource/delete concurrency regression on its disposable database.

The resource API returns known business conflicts as HTTP 409 with `PT409` and
a stable `RESOURCE_*` message. Apply bounded retry only to lifecycle-busy;
revision/profile/source conflicts require reloading state. Private SQL callers
still receive the original `40001` codes.


S9 local permission qualification and role-specific recovery are defined in [legacy-permissions.md](legacy-permissions.md). No merge/deploy is authorized by local test success.


For S9 role evidence, use the separate local LOGIN probe described in `tests/consumers/README.md`; it never accepts preview. Proposed production metadata reads are itemized in [the pending read packet](s9-role-consumer-evidence.md), and are not authorized or executed by local qualification.


The complete S9 local orchestration runner uses the existing Unstructure Python
environment (including requests, psycopg2 and boto3), without installing or
upgrading dependencies or loading its `.env`. Constructed fixture configuration
points only to the owned local database, temporary file tree and loopback
provider listener. Local platform admin is used solely for temporary role
lifecycle; worker connections assert NOSUPERUSER and their own BYPASSRLS flag.
All production permissions and schemas remain unchanged.
