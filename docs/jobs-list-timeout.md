---
docType: reference
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When reviewing or qualifying the Jobs timeout fix."
whenToUpdate: "When Jobs query behavior, fixtures or measured evidence changes."
checkPaths: [supabase/migrations/20261013091317_optimize_kb_admin_jobs_authorization.sql, tests/performance/kb_admin_jobs.sql, tests/sql/kb_admin_jobs_permissions_smoke.sql, tests/runtime/qualify_jobs_upgrade.py]
lastReviewedAt: 2026-10-13
lastReviewedCommit: 328512cf20747fbbd00f2973e7a609b6388360cb
---

# Jobs list timeout investigation

Scope: [KB #42](https://github.com/tiangong-ai/knowledge-base/issues/42),
implemented in [database #8](https://github.com/tiangong-ai/database/issues/8).
KB PR #41 moved SQL ownership here. The shared Jobs timeout was observed on
142 and 148 in web-app#74; this investigation makes no production connection.

## Baseline and discriminating evidence

Source baseline: `223e05ccdd86505595f34166da0da2711c6d2294`. Local qualification
uses Supabase CLI 2.120.0, its PostgreSQL 17.11.0.004 image (digest
`sha256:06ddc7962e11ab0f4f0334fd05671e97c30ea202f6e6a7113800bd3d6e416108`),
Docker/OrbStack on macOS ARM64. No dependencies or deployed timeouts were changed.

The synthetic fixture has 20,000 private documents, 60,000 jobs, 100 collections
and 101 allow grants. Three stages per document follow the parse/s3_ready/index
pipeline. Five statuses are balanced; timestamps deliberately tie, running locks
are expired and payloads contain synthetic 1 KiB strings. An administrator has
manage on all 100 collections, a restricted actor has read on one collection,
and the unauthorized actor has no grants or ownership. This is a stress bracket,
**not a calibrated production distribution**: no production size, grant-count,
payload or status-distribution statistics were acquired. Real-host latency and
production bottleneck confirmation remain unverified.

The original administrator RPC hits the fixture's **5-second statement timeout**
(5000.227 ms cancellation). On a smaller 2,000-document/6,000-job copy, isolated
`EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)` of its exact query body gave:

| Diagnostic query | Execution time | Shared buffer hits |
| --- | ---: | ---: |
| Original administrator predicate + window count + sort | 544.289 ms | 53,397 (+4 reads) |
| Same query, permission predicate removed for diagnosis only | 3.506 ms | 1,058 |
| Original unauthorized predicate | 1,860.842 ms | 156,060 |

The original plan applies `kb_actor_can_access_admin_document(actor,id)` to a
`Seq Scan on kb_documents`: 2,000 calls before the job hash join, WindowAgg and
top-N sort. The document scan accounts for 52,394 buffer hits for administrator
and 156,055 for unauthorized. Removing only this predicate leaves the same
window count and top-N sort, isolating repeated authorization lookup as the
bottleneck on this fixture. The predicate-free query is diagnostic SQL only;
it is never an RPC implementation or a production operation.

## Change and compatibility

Materialize principals and nonrevoked, unexpired allow grants once; apply the
same document/collection/subtree predicates as the existing Documents hotfix.
The read branch requires nondeleted documents and permits creator, owner,
public visibility or read/manage grant. The action branch permits reindex,
delete or manage even for deleted documents, preserving operator visibility.
Group membership, subtree path matching and null-actor denial are unchanged.
The matching 6,000-job post-fix plan runs in 21.037 ms and shows both
`actor_principals` and `active_grants` materialized once. Row predicates still
scan the small grant CTE (6,000 loops here); this is intentionally not a claim
of constant-time authorization at arbitrary grant cardinality.

Retain the window count, original ordering (including fallback for an unknown
sort), offset pagination and every filter. An empty page stays empty; existing
Next derives total=0 from it. Next's authenticated actor and service-role RPC
call need no change. `CREATE OR REPLACE` preserves function identity and ACL;
no new helper, index, type, policy or grant is introduced.

## Measured acceptance

One fresh post-fix local run on the 60,000-job fixture (single measurements,
not a production SLO or statistically sampled benchmark):

| Call | Rows / exact total | Time |
| --- | --- | ---: |
| Administrator first page | 25 / 60,000 | 242.805 ms |
| Restricted first page | 25 / 600 | 32.472 ms |
| Unauthorized | 0 / no count row | 23.096 ms |
| Failed/dead | 25 / 24,000 | 96.312 ms |
| Stale running | 25 / 12,000 | 51.607 ms |
| Offset 50,000 | 25 / 60,000 | 243.989 ms |
| Offset 60,000 | 0 / no count row | 233.089 ms |

All calls satisfy the preselected local 5-second bound. This is a bounded
regression guarantee; exact counts still scale with the qualifying data set
and grant-heavy distributions need separate measurement if observed.

Reproduce on a disposable local stack:

```sh
SUPABASE_CLI=/path/to/supabase-2.120.0 PYTHON_BIN=python3.12 scripts/test-database.sh
python3.12 -m unittest discover -s tests -p 'test_*.py'
```

The red fixture commit `328512c` runs the old function and exceeds the bound.
The forward version runs the same capacity fixture, 17 SQL smoke tests, legacy
behavior/catalog checks and actual schema export/object workspace/TypeScript
generation. The upgrade probe independently restores the prior Jobs body,
verifies old behavior, reapplies the migration and checks identity/ACL/signature.
Offline tooling: 59 tests passed. Catalog delta is exactly one function body
fingerprint; all other schema attributes remain equal.

## Review and deployment boundary

Claude UI consultation was attempted but its active session was concurrently
changed by another task; no independent Jobs assessment was received. Do not
claim that consultation passed. SQL/helper comparison and runtime qualification
are the available review evidence; PR review remains visible in the delivery.

No production DDL, EXPLAIN ANALYZE, export, service restart or worker activation
was performed. Database `main` is connected to automatic Supabase deployment;
this work is delivered as a reviewable PR. Hosted preview evidence and explicit
production rollout disposition are needed before merge/activation. A source PR
does not prove that either existing web host's Jobs screen has recovered.
Rollback, if needed after an authorized deployment, is a separately reviewed new
migration restoring the prior Jobs definition from `202605110001`; never rewrite
applied migration history or run the legacy filename-ledger runner on production.
