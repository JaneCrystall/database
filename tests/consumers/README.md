# Disposable consumer runtime

The consumer runtime is separate from `scripts/test-database.sh`. It starts
an independent PostgreSQL 17, Auth, Kong and PostgREST stack from this repo's
SQL sources. It copies no host environment files, project links or credentials.
Each local session has a unique project ID and randomly allocated local ports.
No existing local stack is reused or reset.
Project IDs stay below CLI 2.120.0's 40-character limit. Cleanup checks the
owning container's workdir/project labels and verifies containers and volumes
are absent after stop; a successful CLI exit alone is not cleanup proof.

Use Python 3.11+, Supabase CLI 2.120.0 and a local Docker socket:

```sh
SUPABASE_CLI=/absolute/path/to/supabase scripts/test-consumers.sh start-local --session-dir /private/tmp/consumer-session-unique
scripts/test-consumers.sh validate-target --target /private/tmp/consumer-session-unique/target.json
scripts/test-consumers.sh stop --session-dir /private/tmp/consumer-session-unique
```

Start returns a JSON receipt containing the target-file path, run ID, project
ref and API URL. It never prints keys or database credentials. The stack stays
running until stop, so separate consumer scenarios can reuse it without
replaying the chain. Failed startup cleans up only the stack it attempted to
create. Stop removes that stack's volumes and private target file; it retains
non-secret session metadata. Consumers must finish their fixture cleanup before
stop. No remote functions are deployed by this runtime.

## Target interface

`target.json` and `session.json` use permissions 0600; the session directory
uses 0700. Consumers read the private JSON and call `runtime.validate_target`
before connecting. The target contains:

- `schema_version`: 1, `mode`: `local` or `preview`, `run_id`: 32 hex characters.
- `api_url`, `publishable_key` (local anon key), `service_role_key`, `db_url`.
- `project_ref`, `parent_project_ref`, `branch_name`, `session_dir`.
- Local only: `project_id`, `workdir` (the session root).
- Preview only: `verification_receipt` (the verified branch metadata).

The fixture owner can append `user` and `fixtures` records using the same
private-file permissions. The runtime does not create users or synthetic rows.
The run ID must identify every fixture and cleanup manifest. Authentication
and PostgREST stay real; consumer-specific external provider fixtures belong
to their own harnesses. Keys, passwords, DB URLs and unredacted CLI diagnostics
must not enter public reports. HTTP mutations commit independently; cleanup
must enumerate only this run's fixtures rather than assuming SQL rollback.

After preparing fixtures, run the existing consumer entrypoints against the
same target without restarting the stack:

```sh
/absolute/path/to/knowledge-base/.venv/bin/python tests/consumers/fixtures.py setup --target /private/tmp/consumer-session-unique/target.json
python3 tests/consumers/run_web_edge.py --target /private/tmp/consumer-session-unique/target.json --report /private/tmp/consumer-session-unique/web-edge-receipt.json
/absolute/path/to/knowledge-base/.venv/bin/python tests/consumers/journals_consumer.py --target /private/tmp/consumer-session-unique/target.json
/absolute/path/to/knowledge-base/.venv/bin/python tests/consumers/verify_catalog.py --target /private/tmp/consumer-session-unique/target.json
/absolute/path/to/knowledge-base/.venv/bin/python tests/consumers/fixtures.py cleanup --target /private/tmp/consumer-session-unique/target.json
```

Use a new report path for each run. Always invoke fixture cleanup on failures
before stopping the session. The journal runner uses the KB/skills code and
its frozen Python dependencies. Sibling discovery prefers `web-app`,
`edge-functions`, `knowledge-base` and `agent-skills`, then accepts the older
`tiangong-ai-next`, `tiangong-ai-edge-function`, `TianGong-AI-KB` and `skills`
directories when the corresponding current directory is absent. Explicit
`--kb-root` and `--skills-root` journal arguments take precedence. The recorded
keys and SHAs in `source-revisions.json` remain historical source identities;
they are not rewritten when workspace directories move. The web/Edge runner requires the owning Next
checkout's installed dependencies, Node and Deno. Its receipt identifies exact
Route Handler/source hashes, real local HTTP/Auth/PostgREST qualification, and
external provider doubles. Its Edge tests execute the unchanged handler source
under Deno HTTP; they do not claim a hosted Edge deployment or Supabase gateway
qualification. Test reports must preserve this runtime distinction.

## Explicit preview binding

The caller supplies two private JSON files and exact expected metadata:

```sh
scripts/test-consumers.sh prepare-preview --session-dir /private/tmp/preview-session-unique --credentials-file /private/path/credentials.json --receipt-file /private/path/receipt.json --expected-ref PREVIEW_REF --expected-parent PARENT_REF --expected-branch PR_BRANCH
```

Credentials contain only `api_url`, `publishable_key`, `service_role_key` and
`db_url`, all belonging to the selected preview. The management receipt must
have `verification_source: "supabase-management-mcp"`, the matching
`project_ref`, `parent_project_ref` and `branch_name`, `is_preview: true`,
`status: "ACTIVE_HEALTHY"`, and an ISO UTC `verified_at` within 24 hours.
The task's operator creates this receipt after actually checking management
metadata. It is an input evidence contract, not a cryptographic attestation;
writing those fields without performing the check is not verification.

The runtime rejects the production Knowledge Base ref
`qyyqlnwqwgvzxnccnbgm`, mismatched API/DB hosts, absent/stale branch evidence,
or a preview ref equal to its parent. It supports the preview's direct DB host
or a Supabase pooler connection whose username names that preview. Stop in
preview mode only removes the local target file; it does not reset, modify,
delete or deploy to the hosted project. Fixture cleanup is a separate explicit
consumer operation using this validated target.

Run offline runtime safety checks with:

```sh
python3 -m unittest discover -s tests/consumers -p 'test_runtime_safety.py'
```


## S9 permission consumers

`run_web_edge.py` also exercises actual Next API-key create/list/rotate/revoke,
Jobs and course-search bearer authorization. Course Redis is a cache-miss double;
valid/invalid/revoked tokens are verified against the real local database.
Use `knowledge-base/.venv/bin/python tests/consumers/unstructure_permissions.py
<owned-local-target.json>` from the workspace (adjust script path from root)
for seven unchanged Unstructure psycopg adapters under service_role. Its source
SHA-256 is reported. Only the local target mode is allowed. S9 adapter/HTTP
fixtures are removed by stopping the owned stack, not generic fixture cleanup.


For the stronger S9 identity boundary probe, run from this repository:

```sh
../knowledge-base/.venv/bin/python tests/consumers/unstructure_role_boundary.py --target /private/tmp/consumer-session-unique/target.json
```

It requires an owned local session, verifies container labels and its database port, then creates a fresh restricted LOGIN and runs actual adapters with test-only grants. The JSON distinguishes passing RPCs from queue/snapshot schema and RLS gaps, and always sets whole_worker_qualified/production_role_verified to false. It does not accept production or preview. The test login/grants are removed even on failure; stop the owned stack to remove synthetic rows. Do not use generic fixture cleanup as a substitute for stop. Source hashes, the phase grant contract and safe diagnostics exclude credentials. `python3 -m unittest discover -s tests/consumers -p 'test_*.py'` includes its offline targeting checks. See [the source inventory and pending online read packet](../../docs/s9-role-consumer-evidence.md).


## S9 complete local worker scheduling

From database, using a newly started owned local session:

```sh
../unstructure/.venv/bin/python tests/consumers/unstructure_worker_flow.py --target /private/tmp/consumer-session-unique/target.json
../unstructure/.venv/bin/python tests/consumers/unstructure_worker_flow.py --target /private/tmp/consumer-session-unique/target.json --acl-upgrade
```

The runtime requires Unstructure's existing requests/psycopg2/boto3 dependencies.
It never loads operator environment files. Five unchanged schedulers execute
actual SQL/queue operations as a fresh NOSUPERUSER/BYPASSRLS login with explicit
13 RPC, schema, snapshot and queue grants; this nonowner test profile emulates
needed observed postgres capabilities, not its identity or complete ownership.
A second restricted login runs the same scheduler and must fail with 42501
before claim. Temporary role lifecycle uses only the owned container's platform
admin. No production role/grant recipe is implied.

Parser/embedding HTTP is loopback-only, NAS is a temporary directory, and only
S3 object transport is replaced; artifact writes, S3 manifest/size/hash checks,
lease/claim/finalization/retry/reconciliation remain real. Receipts distinguish
fresh head from a populated **ACL-delta** upgrade; full prior-chain replay
remains in `scripts/test-database.sh`. Stop the stack afterwards to remove all
synthetic archives/audit records, even if a run fails.

The Next web runner now includes real `runIndexWorkerOnce`/`runDeleteWorkerOnce`,
record ledger and queue completion with external artifact/index/cleanup doubles.
Use a separate fresh consumer session with `fixtures.py setup`, so its index
reconciliation cannot pick up Python-flow documents. Both runners are bounded
local development qualification for these commands, not external-provider or hosted deployment E2E.

## S9 explicitly authorized disposable Preview

Prepare the private target with the existing `prepare-preview` command above,
after a fresh Management API/MCP branch read. For the following commands the
receipt must additionally contain `branch_id`, `is_default: false` and
`persistent: false`. Its parent must be the KB production project, while its
own ref must be different. Persistent Dev, LCA, production, stale/mismatched
receipts and remote URL overrides are rejected before application imports or
connections. Creation, paid usage, fixture writes and branch cleanup require
the operator's explicit authorization; a receipt is not authorization.

```sh
../unstructure/.venv/bin/python tests/consumers/unstructure_worker_flow.py --target /private/tmp/preview-session-unique/target.json --preview-ref PREVIEW_REF
python3 tests/consumers/preview_api_boundary.py --target /private/tmp/preview-session-unique/target.json --preview-ref PREVIEW_REF
```

The worker mode requires an empty job table and parse/S3 queues, verifies the
actual Preview postgres login is NOSUPERUSER/BYPASSRLS, and adds **no worker
grants**. It runs the same complete scheduler scenarios using existing Preview
ownership/privileges. The negative scheduler uses a fresh NOINHERIT/NOBYPASSRLS
login with no object grants, removed by exact `DROP ROLE`; hosted PG17 need not
grant SET ROLE authority for `DROP OWNED`. Production identity/membership is
not inferred. `--acl-upgrade` is forbidden in Preview, so this mode cannot
reopen ordinary ACLs. External providers remain loopback/file doubles.

The HTTP boundary runner uses `fixtures.py setup`'s synthetic actor and records
26 denied calls across the 13 non-trigger restricted RPCs, ordinary table-write
denials, journal authenticated/anonymous reads and rejection of an actual
`private` table profile. OpenAPI-root access is not a schema-exposure probe.
The existing Next/Edge and journal runners also accept verified Preview targets;
run worker scenarios sequentially, with cleanup, to avoid cross-consumption.
`verify_catalog.py` uses the canonical current-chain comparator, including
resource objects, rather than comparing only the original public fixture.

Fixture cleanup and local `stop` do not delete hosted branches or all synthetic
archive/audit rows. Finish by deleting **only the exact disposable branch created
for this run**, verify its absence through Management metadata, and remove local
Preview credentials. Hosted success does not create an official GitHub App check,
authorize merge/production deployment or qualify real provider delivery.
