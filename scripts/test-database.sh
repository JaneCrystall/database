#!/usr/bin/env bash
# Replay the entire KB history in an isolated local Supabase database.
set -euo pipefail

if (( $# != 0 )); then
  echo "Usage: scripts/test-database.sh (local Docker only; no connection arguments)" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
supabase_bin=${SUPABASE_CLI:-${SUPABASE_BIN:-supabase}}
python_bin=${PYTHON_BIN:-python3}
required_cli_version=2.120.0
command -v "$supabase_bin" >/dev/null
command -v "$python_bin" >/dev/null
command -v docker >/dev/null
if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
  docker_host=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
  docker_host=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$docker_host" in
  unix://*|npipe://*) ;;
  *) echo "Tests require a local Docker socket; remote Docker endpoints are refused" >&2; exit 2 ;;
esac
actual_cli_version=$("$supabase_bin" --version)
if [[ "$actual_cli_version" != "$required_cli_version" ]]; then
  echo "Supabase CLI $required_cli_version required; found $actual_cli_version" >&2
  exit 2
fi
docker info >/dev/null

# This directory never receives .temp/project-ref or other hosted-project state.
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tiangong-ai-database-test.XXXXXX")
test_project_id="tiangong-ai-database-test-$$-${RANDOM}"
db_container="supabase_db_${test_project_id}"
owns_stack=false
cleanup() {
  result=$?
  trap - EXIT
  if [[ "$owns_stack" == true ]]; then
    if ! "$supabase_bin" stop --workdir "$test_root" --project-id "$test_project_id" --no-backup; then
      echo "Could not clean test stack $test_project_id" >&2
      result=1
    fi
  fi
  rm -rf -- "$test_root"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$test_root/supabase"
cp "$repo_root/supabase/config.toml" "$repo_root/supabase/seed.sql" "$test_root/supabase/"
cp -R "$repo_root/supabase/migrations" "$test_root/supabase/migrations"
"$python_bin" - "$test_root/supabase/config.toml" "$test_project_id" <<'PY'
import contextlib
import pathlib
import re
import socket
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
config = path.read_text()
parsed = tomllib.loads(config)
if parsed["project_id"] != "tiangong-ai-database" or "remotes" in parsed:
    raise SystemExit("Tests require the unlinked tiangong-ai-database local configuration")
config = re.sub(r'^project_id = .+$', f'project_id = "{sys.argv[2]}"', config, count=1, flags=re.M)
# Choose free ports so a developer's ordinary local stack remains untouched.
ports = []
with contextlib.ExitStack() as sockets:
    for _ in range(3):
        sock = sockets.enter_context(socket.socket())
        sock.bind(("127.0.0.1", 0))
        ports.append(sock.getsockname()[1])
db_section = re.search(r'^\[db\]\n(.*?)(?=^\[|\Z)', config, re.S | re.M)
assert db_section is not None
db_settings = db_section.group(1)
db_settings = re.sub(r'^port = \d+$', f'port = {ports[0]}', db_settings, flags=re.M)
db_settings = re.sub(r'^shadow_port = \d+$', f'shadow_port = {ports[1]}', db_settings, flags=re.M)
config = config[:db_section.start(1)] + db_settings + config[db_section.end(1):]
api_section = re.search(r'^\[api\]\n(.*?)(?=^\[|\Z)', config, re.S | re.M)
assert api_section is not None
api_settings = re.sub(r'^port = \d+$', f'port = {ports[2]}', api_section.group(1), flags=re.M)
config = config[:api_section.start(1)] + api_settings + config[api_section.end(1):]
path.write_text(config)
PY

# Never reuse or remove a pre-existing stack, even in the unlikely event of an ID collision.
if docker ps -a --format '{{.Names}}' | "$python_bin" -c 'import sys; raise SystemExit(0 if sys.argv[1] in sys.stdin.read().splitlines() else 1)' "$db_container"; then
  echo "Refusing to reuse existing container $db_container" >&2
  exit 2
fi
if docker volume ls --format '{{.Name}}' | "$python_bin" -c 'import sys; suffix="_"+sys.argv[1]; raise SystemExit(0 if any(v.endswith(suffix) for v in sys.stdin.read().splitlines()) else 1)' "$test_project_id"; then
  echo "Refusing to reuse existing volumes for $test_project_id" >&2
  exit 2
fi
# CLI success output can include ephemeral keys; keep it private and report
# only the command outcome. Failure diagnostics omit credential-bearing lines.
local_cli() {
  if "$supabase_bin" "$@" > "$test_root/cli.log" 2>&1; then
    echo "Local Supabase $1 succeeded."
  else
    local cli_result=$?
    "$python_bin" - "$test_root/cli.log" <<'PYLOG'
import pathlib, re, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines()[-40:]:
    if not re.search(r'(?i)(secret|key|jwt|password|postgres(?:ql)?://|eyJ)', line):
        print(line, file=sys.stderr)
PYLOG
    return "$cli_result"
  fi
}
owns_stack=true
local_cli start --workdir "$test_root" -x realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
local_cli db reset --local --workdir "$test_root" --yes

run_sql() {
  docker exec -i "$db_container" psql -X --set ON_ERROR_STOP=1 --username postgres --dbname postgres "$@"
}

"$python_bin" "$repo_root/tests/runtime/qualify_jobs_upgrade.py" "$repo_root" "$db_container"

smoke_tests=("$repo_root"/tests/sql/*_smoke.sql)
if [[ ! -f "${smoke_tests[0]}" ]]; then
  echo "No SQL smoke tests found" >&2
  exit 1
fi
failed_tests=()
for sql_file in "${smoke_tests[@]}"; do
  echo "Running ${sql_file##*/}"
  if ! run_sql < "$sql_file"; then
    failed_tests+=("${sql_file##*/}")
  fi
done
for sql_file in "$repo_root"/tests/runtime/*.sql; do
  [[ -f "$sql_file" ]] || continue
  echo "Running ${sql_file##*/}"
  if ! run_sql < "$sql_file"; then
    failed_tests+=("${sql_file##*/}")
  fi
done
if (( ${#failed_tests[@]} != 0 )); then
  printf 'Failed SQL tests: %s\n' "${failed_tests[*]}" >&2
  exit 1
fi
"$python_bin" "$repo_root/tests/runtime/resource_contract.py" "$db_container"
"$python_bin" "$repo_root/tests/runtime/resource_delete_concurrency.py" "$db_container"
run_sql < "$repo_root/tests/schema/resource_boundary.sql"
run_sql < "$repo_root/tests/schema/resource_http_errors.sql"
SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/resource_api.py" "$db_container" "$test_root"
run_sql < "$repo_root/tests/runtime/legacy_permissions.sql"
SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/legacy_permissions_api.py" "$db_container" "$test_root"
for sql_file in "$repo_root"/tests/performance/*.sql; do
  [[ -f "$sql_file" ]] || continue
  echo "Running ${sql_file##*/}"
  run_sql < "$sql_file"
done
run_sql < "$repo_root/tests/schema/legacy_behaviors.sql"
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/legacy-catalog.json"
if [[ -n "${DATABASE_TEST_CATALOG_OUTPUT:-}" ]]; then
  # Catalog definitions only, never application/Auth rows or connection configuration.
  cp "$test_root/legacy-catalog.json" "$DATABASE_TEST_CATALOG_OUTPUT"
fi
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --actual "$test_root/legacy-catalog.json"

SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/qualify_toolchain.py" "$repo_root" "$test_root"
# Upgrade from the exact prior chain with existing rows; never apply to a linked project.
# Its expected catalog is separate from the current Jobs function fingerprint.
resource_migration=20261013091136_kb_resource_contract.sql
mkdir "$test_root/after-resource-baseline"
for migration_path in "$test_root"/supabase/migrations/*.sql; do
  if [[ ! "${migration_path##*/}" < "$resource_migration" ]]; then
    mv "$migration_path" "$test_root/after-resource-baseline/"
  fi
done
local_cli db reset --local --workdir "$test_root" --yes
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/prior-catalog.json"
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --baseline-only --actual "$test_root/prior-catalog.json"
run_sql < "$repo_root/tests/upgrade/resource_before.sql"
mv "$test_root"/after-resource-baseline/*.sql "$test_root/supabase/migrations/"
# Apply the original resource migration first, seed real old-layout state, then
# move existing rows through the appended boundary migration (all later files too).
mkdir "$test_root/schema-boundary-tail"
for migration_path in "$test_root"/supabase/migrations/*.sql; do
  if [[ "${migration_path##*/}" > "$resource_migration" ]]; then
    mv "$migration_path" "$test_root/schema-boundary-tail/"
  fi
done
local_cli migration up --local --workdir "$test_root"
run_sql < "$repo_root/tests/upgrade/resource_boundary_before.sql"
mv "$test_root"/schema-boundary-tail/*.sql "$test_root/supabase/migrations/"
local_cli migration up --local --workdir "$test_root"
run_sql < "$repo_root/tests/upgrade/resource_boundary_after.sql"
run_sql < "$repo_root/tests/upgrade/resource_after.sql"
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/upgraded-catalog.json"
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --actual "$test_root/upgraded-catalog.json"
"$python_bin" "$repo_root/tests/runtime/resource_contract.py" "$db_container"
"$python_bin" "$repo_root/tests/runtime/resource_delete_concurrency.py" "$db_container"
run_sql < "$repo_root/tests/schema/resource_boundary.sql"
run_sql < "$repo_root/tests/schema/resource_http_errors.sql"
SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/resource_api.py" "$db_container" "$test_root"
run_sql < "$repo_root/tests/runtime/legacy_permissions.sql"
SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/legacy_permissions_api.py" "$db_container" "$test_root"
echo "Local migration replay, ${#smoke_tests[@]} SQL smoke tests, resource concurrency, PostgREST boundary and populated prior-schema upgrade passed."
