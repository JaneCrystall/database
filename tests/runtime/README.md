# Local database qualification

`scripts/test-database.sh` copies only the checked-in Supabase configuration,
migrations and seed into a temporary directory. It allocates a unique local
project ID and free database ports, starts an isolated PostgreSQL container,
resets the local database, and runs every SQL smoke test through that
container's `psql` with SQL errors fatal. Each SQL test uses a separate
connection; transaction rollback removes its fixtures. Failures are collected
and make the gate fail. The same stack then qualifies the actual local schema
export, offline schema-object workspace builder, and TypeScript generator;
each must include `public.kb_documents`. Generated files remain exclusively
in the temporary directory. The exit trap stops only its own project and removes
its temporary data volumes and directory, including when startup fails.

The runner requires Supabase CLI 2.120.0, Python 3.11+ and a local Docker socket.
It refuses connection arguments, remote Docker hosts and remote Docker
contexts, and never copies a hosted project link. `SUPABASE_CLI` selects the
CLI executable; `PYTHON_BIN` selects the Python executable.

`test_runtime_safety.py` exercises target refusal and cleanup without invoking
a real database. The normal unit-test discovery command includes these tests.

## Imported fixture correction

The original KB smoke-test bytes are preserved in import commit `4519873`.
The original `kb_admin_read_rpc_smoke.sql` created a failed parse job and a
running parse job for the same document/version, violating
`kb_jobs_active_stage_idx`. It also expected the readable document's detail
to contain exactly two jobs although it had inserted three for that document.
The independent two-stage running parse fixture now uses the existing private
document. This preserves the failed-job, job-detail and two-stage health
assertions, and preserves the migration history and unique index.
