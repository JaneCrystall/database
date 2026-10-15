---
docType: contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When reviewing the production-derived legacy baseline or running consumer qualification."
whenToUpdate: "When capture scope, privacy guarantees, parity or business-path validation changes."
checkPaths: [supabase/migrations/**, tests/schema/**, tests/consumers/**, docs/legacy-schema-inventory.json]
lastReviewedAt: 2026-10-15
lastReviewedCommit: 33c3b417182b72349e36d0b6cf44a26e4be31c2c
---

# Knowledge Base legacy schema baseline

This capture fills the application schema gaps in the existing Knowledge Base
project. Production access is **read-only**. The source PR must not be merged
while production auto-deployment would attempt to replay this baseline against
its already-existing objects. A production metadata-adoption decision is separate
from source capture and requires explicit authorization after qualification.

## Source and privacy

PostgreSQL 17 `pg_dump --schema-only --schema=public --no-owner --no-comments
--no-security-labels --no-publications --no-subscriptions --quote-all-identifiers`
ran with `default_transaction_read_only=on`. The original export remains in a
private directory outside Git. Only reviewed definitions selected by explicit
object names enter the migration. The inventory records the original export
SHA-256, selected statements and representation changes.

No business rows, Auth users, reference-data rows, role passwords/memberships,
sequence current values or production seed fixtures are exported. Function and
default literals were reviewed for credentials, URLs, identities and data.
`tests/schema/public_catalog.expected.json` contains catalog metadata only.
Synthetic test rows are clearly named and exist only on disposable targets.

## Complete application-object scope

The new capture contains 12 legacy content/authorization tables (`edu_meta`,
`edu_textbooks`, `esg_category`, `esg_country`, `esg_meta`, `green_deal_meta`,
`internal_use`, `journals`, `journals_issn`, `reports`, `standards`, `user_roles`),
plus the **empty** legacy `kb_schema_migrations` table definition. The old ledger's
applied-version rows are not imported. Together with the existing KB chain this
reconstructs all 24 public application tables observed during capture.

It also includes `lang`, six missing functions (`esg_full_text`,
`standards_full_text`, `has_service_role`, `set_created_by`,
`set_last_updated_by`, `set_last_updated_time`), 18 explicit indexes, constraints,
three triggers, 12 policies and object privileges. The existing 66 KB function
bodies already match production; they are not replaced by this capture. A
second migration records explicit ACLs for the existing 11 KB tables and 66
functions, because hosted previews do not inherit the older production defaults.
It revokes the named API/PUBLIC privileges and restores exactly the observed
object grants, without importing environment-wide default privileges.
The source chain now contains 40 migration files.

External dependencies are platform `auth.users`/`auth.uid()`, UUID generation and
PGroonga operators/indexes. Platform/extension-owned auth, storage, realtime,
pgmq, vault, pgsodium and other managed schemas are supplied by Supabase, not
copied as application SQL. Historical scripts referencing `edu_wenku`, `ali`
and quoted `Sheet1` refer to objects absent from the production catalog; their
DDL is not invented or included in current-path qualification.

`journals_reader` and `out_user` are created only when absent, as NOLOGIN
privilege roles without credentials or production membership identities.
Production's `journals_reader` login is deliberately not reproduced. New PG17
local defaults grant MAINTAIN more broadly than production; explicit revokes
on all 24 public tables make the replayed ACLs match. The SQL `has_service_role` body's CRLF bytes
are represented as escapes to preserve its fingerprint in LF source files.

## Permission compatibility

The baseline preserves the observed model, without granting extra access:
all captured tables have RLS enabled; ESG additionally forces RLS. Authenticated
users can read the existing broadly readable legacy resources; user roles are
self-readable; green-deal has no policy and remains invisible to ordinary
users. Existing table ACLs include broad DML/TRUNCATE grants and the helper
`has_service_role(uuid)` has PUBLIC EXECUTE. These are inherited facts, not a
new security model. RLS does not protect TRUNCATE via direct SQL. Any tightening
belongs to a separate reviewed access-policy change.

The original baseline's ordinary Next writes were denied or affected no rows;
DELETE could report success for zero deleted rows. S9 narrows the ACLs separately,
so current consumer qualification requires safe 403 for all six groups' writes
with the paired Next #88 fix, plus unchanged rows and anonymous-write 401.
This is an intentional delta from the historical baseline, not a replacement
of its captured facts. `has_service_role` is a database lookup helper, not
validation of a service JWT.

## Business qualification

Every run uses a fresh target identity and refuses the production project before
starting processes or writing fixtures. The same harness targets local and an
explicitly verified Supabase preview. Private target files contain only that
target's credentials and synthetic users; receipts exclude secrets.

- **Catalog parity:** column order/types/defaults/nullability, constraints,
  indexes, triggers, RLS/policies/grants, enum labels, function bodies/settings
  and ACLs compare against the read-only production capture.
- **Next:** actual resource Route Handlers and stores run in an isolated Next
  HTTP process with real Auth cookies and PostgREST. All six legacy resources
  exercise search/sort/page reads and write rejection/non-mutation; humanities
  exercises scoped admin read, outsider rejection and read-only responses.
- **Edge:** unchanged edu/ESG/standards/science handlers run behind local Deno
  HTTP using real Supabase SDK, Auth, PostgREST and full-text RPCs. Nonempty
  fixture hits prove RPC-ID filtering and journal title/author hydration.
  Only external LLM/embedding, Pinecone, OpenSearch and Redis transports are
  doubled; this does not claim hosted Edge deployment or provider E2E.
- **Journals:** the real KB collector invokes its actual metadata skill against
  PostgreSQL; only Crossref HTTP is doubled. Repeat ingestion proves DOI
  deduplication, authors JSONB roundtrip, real keyset candidate selection,
  abstract backfill and guarded non-overwrite. It cleans its exact DOI/ISSN rows.
- **Cleanup:** resource IDs and Auth users are recorded in a private manifest;
  teardown removes only those fixtures and verifies their absence. No truncate,
  production reset or application-row export occurs.

Commands and target lifecycle live in `tests/consumers/README.md`. Consumers use
reviewed sibling source checkouts and their existing locked dependencies; the
public database repository does not vendor their private source or credentials.
The database-only hosted CI replays schema/SQL tests and enforces catalog parity;
consumer qualification requires those checkouts and is recorded separately.
Current workspace directories follow the GitHub repository names, with legacy
sibling names accepted for existing checkouts. The keys and SHAs in
`tests/consumers/source-revisions.json` preserve the historical source identities
reviewed for the original qualification; directory discovery does not rewrite
that evidence or qualify a newer consumer revision.

The first real Preview failed catalog parity and the Next humanities route
because inherited KB privileges were absent. The explicit ACL migration is the
regression fix; catalog parity and the same failed route must pass on Preview
before qualification. Fixture cleanup tolerates only an already-deleted Auth
user (404); authorization errors still fail.

The synthetic legacy SQL behavior contract additionally executes insert/update
triggers, full-text RPC matching, own-row role visibility, anonymous denial,
journal-reader read-only access and out_user RLS denial. Test-only SET ROLE
membership and all synthetic Auth/table rows are transactionally rolled back.

## Additive migrations after capture

The original 40-file capture is preserved byte-for-byte in
`tests/schema/pre_resource_catalog.expected.json` (from commit `223e05cc`).
It contains 24 tables, 72 functions and 11 enums. `--baseline-only` selects
that fixture solely for the disposable prior-chain upgrade gate, which excludes
both the resource and later Jobs migrations. The normal head check combines
`public_catalog.expected.json` with the separate resource catalog, rejects
overlaps, and requires the deliberately optimized Jobs body fingerprint.
Mixing either generation fails; no function-body or ACL checks are skipped.

## Deliberate changes after capture

The Jobs timeout fix updates only `list_kb_admin_jobs`'s `body_md5` in the live
head catalog expectation. The original 40-file capture and provenance remain
immutable; the Jobs migration is a reviewed forward change. The local gate
continues enforcing all other captured attributes, including that function's
ACL/signature/settings. The original production fingerprint is preserved in Git
history; a current-head expectation is not evidence of production application.


S9 intentionally narrows 18 function and 23 table ACLs; only those catalog fields change. All legacy objects and policy behavior remain, except ordinary writes now fail explicitly. See [the exact matrix and release boundary](legacy-permissions.md).


S9 follow-up consumer qualification also distinguishes direct LOGIN RPC access from queue and snapshot dependencies. [Role evidence](s9-role-consumer-evidence.md) records actual adapter tests, existing local schema/RLS gaps, source versions and owner-confirmed indirect skill/Edge callers. It does not modify the captured schema or claim a deployed identity.


The [S9 development validation](s9-development-validation.md) now adds complete
local scheduler lifecycles, retaining real database/Auth/PostgREST interactions.
It records exact source hashes and separates observed-capability emulation from
hosted role identity; no extra production grants or schema relocation follow.
