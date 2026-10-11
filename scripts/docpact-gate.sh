#!/bin/sh
set -eu

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

docpact_cmd="$repo_root/scripts/docpact"
base_ref="${DOCPACT_BASE_REF:-origin/main}"
head_ref="${DOCPACT_HEAD_REF:-HEAD}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        echo "--base requires a Git ref." >&2
        exit 2
      fi
      base_ref="$2"
      shift 2
      ;;
    --head)
      if [ "$#" -lt 2 ]; then
        echo "--head requires a Git ref." >&2
        exit 2
      fi
      head_ref="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scripts/docpact-gate.sh [--base <ref>] [--head <ref>]" >&2
      exit 2
      ;;
  esac
done

if ! base_sha="$(git merge-base "$head_ref" "$base_ref" 2>/dev/null)"; then
  echo "Could not resolve merge-base for $head_ref and $base_ref." >&2
  echo "Fetch the base ref or rerun with DOCPACT_BASE_REF=<ref>." >&2
  exit 2
fi

head_sha="$(git rev-parse "$head_ref")"
report_path="$(mktemp "${TMPDIR:-/tmp}/tiangong-docpact-gate.XXXXXX")"
trap 'rm -f "$report_path"' EXIT HUP INT TERM

echo "Running docpact config validation."
"$docpact_cmd" validate-config --root "$repo_root" --strict

echo "Running docpact lint: base=$base_sha head=$head_sha."
waivers_path="$repo_root/.docpact/waivers.yaml"
if [ -f "$waivers_path" ]; then
  "$docpact_cmd" lint --root "$repo_root" --base "$base_sha" --head "$head_sha" --mode enforce --waivers "$waivers_path" --output "$report_path"
else
  "$docpact_cmd" lint --root "$repo_root" --base "$base_sha" --head "$head_sha" --mode enforce --output "$report_path"
fi
