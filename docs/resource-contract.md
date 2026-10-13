---
docType: contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When integrating M1 resource registration, review or PDF publication."
whenToUpdate: "When resource RPCs, identity, permissions, snapshots or recovery change."
checkPaths: [supabase/migrations/*_kb_resource_contract.sql, tests/runtime/resource_contract.py, tests/upgrade/resource_*.sql]
lastReviewedAt: 2026-10-13
lastReviewedCommit: 223e05ccdd86505595f34166da0da2711c6d2294
---

# M1 resource identity and document association

Implements [database#7](https://github.com/tiangong-ai/database/issues/7),
transferred from [KB#43](https://github.com/tiangong-ai/knowledge-base/issues/43).
The [M1-01 decision](https://github.com/tiangong-ai/workspace-suite/issues/324#issuecomment-6141715358)
remains the cross-repository contract. SQL now belongs here, not in KB or Next.
This migration is additive and opt-in: no collection, profile, legacy row,
worker or hosted target is activated. Merging `main` can trigger hosted
Supabase deployment; local qualification does not authorize that merge.

## Identity and authority

`kb_resource_entries` holds stable UUID identity, unique within
`collection_id + primary_source_binding_id + external_key`. It can exist
without any PDF or processing document. A deployment-owned versioned profile
lives at `kb_collections.metadata_schema_json.resource_profile`; the entry
retains its profile snapshot. This uses the existing collection configuration
and adds only two business tables plus an operational request ledger.

`kb_resource_document_links` records a reserved/published/superseded primary
association, content revision, candidate observation, approved metadata
snapshot and processing job. Partial unique indexes allow one active primary
per entry, one reserved association per entry, and only one owner of a
reserved/published document. Old files are never renamed/deleted by these RPCs.

Metadata has one fact source:

- `managed`: source observations in `source_metadata`; refresh is a complete
  snapshot, not a field patch. The primary binding alone refreshes facts.
- `legacy_ref`: `{ "table": "journals|esg_meta|reports", "id": "UUID" }`;
  `source_metadata` is a read-only observation, never a second CRUD surface.
  Source rows are read by fixed SQL projections; caller-supplied SQL or
  arbitrary table/column names are impossible. Source deletion/change is
  checked again during review/reservation/publication. A stale source requires
  another `upsert` before processing can proceed.

Effective fields are `source_metadata || manual_overrides`. Only `manage`
can set or release overrides, with actor/time/reason and request audit.
A source refresh behind an override records a proposal without revoking
approval. A change to effective metadata or candidate observations revokes
approval and fences outstanding processing work immediately. The legacy
source is never written by these operations.

Known existing writers remain responsible for their original tables:
Next resource CRUD; journals collector, abstract/history backfills and upload
time scripts; ESG import, language/ticker/upload-time scripts and batch jobs;
reports CRUD. See M1-01 section 7 for the exact inventory and exclusions.
Current deployment schedules/active writers remain unverified. Enabling a
legacy profile in a real environment requires that inventory and mapping to
be reviewed there. No bulk backfill or stopping old writers is part of M1-03.

The fixed projections are:

| Table (UUID `id`) | Resource fields |
| --- | --- |
| journals | title, doi, authors (JSON preserved), date → published_date |
| esg_meta | report_title → title, company_name → organization, year(report_end_date) → report_year, language |
| reports | title, issuing_organization → organization (JSON preserved), release_date::date → published_date, url → source_ref |

A profile must declare matching types; journals dates may be strings, and
reports organizations must not be blindly converted to a string. Enable legacy
reads only with `metadata_mode=legacy_ref`, `legacy_enabled=true` and the exact
`legacy_table`. Trial defaults remain managed and no profile is seeded.

## Profile dialect

A profile has `id`, positive integer `version`, `metadata_mode`, `fields`,
`required_fields`, `source_bindings` and `matching`. Supported field types are
`string`, `integer`, `date` (ISO calendar date), `array<string>`, `array`,
`object`. Missing required fields are allowed during registration, but not
approval. Unknown or mistyped supplied fields are rejected.

Bindings have `id` and `kind`; file bindings use `kind=file-snapshot` and the
publisher separately binds their `source_root_ref` to an allowed, isolated
root. Matching uses explicit entry UUID first, then the primary source key,
then normalized DOI only when `matching` contains `unique_normalized_doi`.
DOI normalization trims/lowercases/removes DOI URL or `doi:` prefixes. More
than one matching entry is a conflict. Titles, filenames and hashes never
identify a resource automatically. Secondary bindings use the returned stable
entry UUID for later observations; no automatic alias merge is implemented.

A changed collection profile makes existing entry mutations fail closed with
`RESOURCE_PROFILE_CHANGED`. Deploy the same profile ID with a higher version,
then explicitly `rebind` each entry using `manage`, its expected revision and
reason. Rebinding validates existing metadata/bindings, preserves identity and
history, and requires fresh approval. It cannot change managed/legacy mode or
silently switch a legacy table. Replacing the whole workflow/profile identity
is outside this small version-upgrade operation.

## Gateway RPC protocol

Only `service_role` can execute the two public entrypoints. There is no direct
SELECT/DML grant on the three new tables, including for `service_role`; RLS is
enabled. Helper functions are not executable by API roles. Security-definer
functions use fixed search paths and schema-qualified object references.

The trusted gateway MUST authenticate the session/scoped API key, derive the
actor from it (never forward a client actor), enforce the API key's scopes and
collection restriction, then call:

```text
kb_resource_command(p_actor_id UUID, p_collection_id UUID,
                    p_operation TEXT, p_request_id UUID, p_payload JSONB)
kb_resource_get(p_actor_id UUID, p_collection_id UUID, p_entry_id UUID)
```

The database independently checks current collection grants including
revocation/expiry/inherited groups. This verifies a trusted gateway's declared
actor authorization; it does not authenticate a JWT or defend against a stolen
service key. Existing privileged legacy RPCs are unchanged and do not acquire
this new protocol automatically.

Every command payload includes `expected_revision` and nonblank `reason`.
Creation requires revision 0 and returns revision 1. Effective changes and
reviews increment the entry revision. Non-effective observations can preserve
approval's earlier revision; **do not require approved_revision=revision**.
A publication phase does not itself increment the resource revision.

| Operation | Grant | Additional payload |
| --- | --- | --- |
| upsert | upload | optional entry_id; binding_id, external_key on creation; managed metadata or legacy_ref on legacy creation; optional source_revision |
| attach | upload | entry_id; candidate described below |
| override | manage | entry_id; fields object and/or release_fields array; only this operation changes overrides |
| review | manage | entry_id; decision approve/reject; explicit candidate_id for approval |
| rebind | manage | entry_id; higher version already installed in collection configuration |
| reserve | upload | entry_id; approved_revision |
| publish | upload | entry_id; approved_revision, document_id, sha256, size, copy_verified, raw_relative_path, raw_uri |

Candidate example:

```json
{"candidate_id":"UUID","binding_id":"drop","relative_locator":"folder/example.pdf",
 "sha256":"64 lowercase hex characters","size":811,"stable":true,"pdf_valid":true}
```

Candidate UUID is the publisher's stable observation identity. New bytes at
that identity update the observation and invalidate approval. A second
candidate puts the entry into `conflict`; an authorized reviewer must explicitly
select a candidate. Invalid, incomplete or unsafe observations are rejected.
The booleans are trusted publisher attestations, not database file inspection.
M1-05 must prove stable size/mtime, readable PDF, source-root confinement,
symlink handling and hash before/after copying. The database cannot inspect NAS.
Requests are capped at 65,536 bytes of PostgreSQL JSONB text, and accumulated
metadata/overrides/provenance/candidates at the same bound. The API must also
bound raw request bytes before parsing. Idempotency compares canonical JSONB
SHA-256, keyed by actor + collection + operation + request UUID. Different
payload under the same key fails; concurrent identical requests return the
same stored result. Keep receipts for the trial lifetime. Authorization is
rechecked before any historical receipt is returned.

SQLSTATE `42501` means forbidden, `P0002` not found, `40001` conflict/reload
(including stale revision/request/profile/source/approval), `22023` malformed
input; ordinary type/constraint failures also reject the transaction. Successful
mutations and approval input/snapshots are audited with actor/reason. Exceptions
roll back all writes; rejected calls need gateway failure logging. A RAISE
preceded by INSERT is **not** durable denial auditing.

## Reserve, publish and recovery

1. Register/observe; no `kb_documents` row exists until an actual stable,
   readable PDF candidate is approved. Approval persists candidate UUID,
   SHA-256, size, revision, reviewer and timestamp.
2. `reserve` derives dedupe scope from the authorized collection UUID, reuses
   the existing reservation when possible, and returns a real document UUID.
   It does not enqueue work. A hash owned by another entry is a conflict;
   the same hash in another collection has independent document identity/ACL.
   An unmanaged already-processed document is not adopted by hash alone.
3. M1-05 exclusively creates a temporary copy, verifies it against the approval,
   atomically publishes `<raw_root>/<collection_path>/<document_id>.pdf`, and
   calls `publish`. Source files stay read-only; no transaction spans file IO.
4. `publish` checks current approval and the exact relative canonical path.
   The portable URI is exactly `nas://raw/<raw_relative_path>` (supported by
   the existing worker). It checks the publisher's copy/hash/size attestation,
   installs the approved processing snapshot, associates the primary and calls
   the existing parse enqueue RPC in the same transaction.
5. Repeating with the same request UUID returns a **historical receipt**, not
   live state. Use `kb_resource_get` to inspect current links/approval before
   recovery; after an interrupted copy, use the original reservation and a
   fresh publish request once the file checks pass. Repeated publication under
   fresh request UUIDs still reuses the job/message for that approval.

New bytes use a document different from the current primary and allocate a
new content revision; known historical bytes may reuse their deduplicated
document under a fresh processing version/link revision. Same-byte reapproval
retains the current content revision/document and advances document_version,
clears prior processing artifacts, and queues only after verified publication.
These version counters are separate from the entry revision.

Invalidation/supersession cancels parse/index/S3-ready work and fences document
versions. Stale completion and artifact replay cannot publish old work. Delete
and archive cleanup jobs retain their ownership; deleted/delete-in-progress
documents are not reset to processing states. Metadata snapshots live on links
and are audited before replacement; worker-written `kb_documents.metadata_json`
remains processing data, not the editable metadata fact source.

`kb_resource_get` rechecks read grants and returns effective metadata, source/
profile staleness, historical links and `approval_current`. M1-09 must require
an active published association, current approval, undeleted current document
version **and** M1-07's verified ready generation/recipe/index evidence. The
`approval_current` flag alone is not search-ready. This migration does not
implement index publication or claim the full S01–S12 product trial has passed.

## Validation and operational limits

`tests/runtime/resource_contract.py` executes actual service-role RPCs through
local psql, including six-session registration, two-session CAS/hash ownership
races and four-session publication. It covers the three profile shapes,
file/metadata arrival order, candidate conflict and bad attestations, legacy
writer refresh, override release, receipts/revocation, versioned rebind,
same-byte reapproval, stale worker completion and delete coexistence.

`scripts/test-database.sh` first replays the complete chain on an empty local
DB with all existing smoke tests. It then resets only its uniquely owned
unlinked local DB to the prior chain, inserts synthetic legacy/document rows,
applies this migration, proves those rows unchanged, compares catalogs, and
runs the new contract again. No production dump, NAS or external index is used.
The original 24-table/72-function/11-enum capture is unchanged; a separate
additive catalog snapshot checks the new three tables/five functions.

Collection-scoped advisory locks intentionally serialize short M1 mutations
including DOI matching; this is a six-document pilot design, not a high-volume
scheduler. Existing workers and legacy writers do not acquire that lock, so
row locks, document-version checks and unique indexes remain essential. DB
runtime tests prove SQL/queue behavior, not filesystem isolation, authenticated
Next routes, real parsing, embeddings or externally indexed search.
