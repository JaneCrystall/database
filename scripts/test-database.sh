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
    for _ in range(2):
        sock = sockets.enter_context(socket.socket())
        sock.bind(("127.0.0.1", 0))
        ports.append(sock.getsockname()[1])
db_section = re.search(r'^\[db\]\n(.*?)(?=^\[|\Z)', config, re.S | re.M)
assert db_section is not None
db_settings = db_section.group(1)
db_settings = re.sub(r'^port = \d+$', f'port = {ports[0]}', db_settings, flags=re.M)
db_settings = re.sub(r'^shadow_port = \d+$', f'shadow_port = {ports[1]}', db_settings, flags=re.M)
config = config[:db_section.start(1)] + db_settings + config[db_section.end(1):]
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
owns_stack=true
"$supabase_bin" start --workdir "$test_root" -x gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
"$supabase_bin" db reset --local --workdir "$test_root" --yes

run_sql() {
  docker exec -i "$db_container" psql -X --set ON_ERROR_STOP=1 --username postgres --dbname postgres "$@"
}

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
run_sql < "$repo_root/tests/schema/legacy_behaviors.sql"
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/legacy-catalog.json"
if [[ -n "${DATABASE_TEST_CATALOG_OUTPUT:-}" ]]; then
  # Catalog definitions only, never application/Auth rows or connection configuration.
  cp "$test_root/legacy-catalog.json" "$DATABASE_TEST_CATALOG_OUTPUT"
fi
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --actual "$test_root/legacy-catalog.json"

SUPABASE_CLI="$supabase_bin" "$python_bin" "$repo_root/tests/runtime/qualify_toolchain.py" "$repo_root" "$test_root"
# Upgrade from the exact prior chain with existing rows; never apply to a linked project.
resource_migration=20261013091136_kb_resource_contract.sql
mv "$test_root/supabase/migrations/$resource_migration" "$test_root/$resource_migration"
"$supabase_bin" db reset --local --workdir "$test_root" --yes
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/prior-catalog.json"
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --baseline-only --actual "$test_root/prior-catalog.json"
run_sql < "$repo_root/tests/upgrade/resource_before.sql"
mv "$test_root/$resource_migration" "$test_root/supabase/migrations/$resource_migration"
"$supabase_bin" migration up --local --workdir "$test_root"
run_sql < "$repo_root/tests/upgrade/resource_after.sql"
run_sql -At < "$repo_root/tests/schema/public_catalog.sql" > "$test_root/upgraded-catalog.json"
"$python_bin" "$repo_root/tests/schema/check_catalog.py" --actual "$test_root/upgraded-catalog.json"
"$python_bin" "$repo_root/tests/runtime/resource_contract.py" "$db_container"
echo "Local migration replay, ${#smoke_tests[@]} SQL smoke tests, resource concurrency and prior-schema upgrade passed."
