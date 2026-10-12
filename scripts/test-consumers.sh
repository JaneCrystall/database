#!/usr/bin/env bash
# Explicit lifecycle commands; a session can stay running while tests are developed.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "${PYTHON_BIN:-python3}" "$repo_root/tests/consumers/runtime.py" "$@"
