#!/bin/sh
set -eu

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

existing_hooks_path="$(git config --local --get core.hooksPath || true)"
case "$existing_hooks_path" in
  "" | .githooks | ./.githooks)
    ;;
  *)
    echo "Refusing to replace existing core.hooksPath: $existing_hooks_path" >&2
    echo "Review the existing hooks and integrate .githooks/pre-push explicitly." >&2
    exit 2
    ;;
esac

git config --local core.hooksPath .githooks
chmod +x .githooks/pre-push scripts/docpact scripts/docpact-gate.sh scripts/install-git-hooks.sh

echo "Configured git hooks: core.hooksPath=.githooks"
