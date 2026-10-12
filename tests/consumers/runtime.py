#!/usr/bin/env python3
"""Disposable local Supabase lifecycle and explicitly verified preview targets."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
from urllib.parse import parse_qsl, urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_REF = "qyyqlnwqwgvzxnccnbgm"
CLI_VERSION = "2.120.0"
PROJECT_PREFIX = "tiangong-ai-consumers-"
EXCLUDED_SERVICES = "realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor"


class RuntimeErrorSafe(Exception):
    pass


def safe_environment() -> dict[str, str]:
    # Never forward provider credentials, operator configuration or CLI auth tokens.
    allowed = {"PATH", "HOME", "TMPDIR", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY"}
    return {**{k: v for k, v in os.environ.items() if k in allowed}, "CI": "true"}


def command(args: list[str], *, timeout: int = 600) -> str:
    try:
        result = subprocess.run(args, capture_output=True, text=True, env=safe_environment(), timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeErrorSafe("Runtime command could not complete; no credentials or CLI diagnostics are printed.") from None
    if result.returncode:
        raise RuntimeErrorSafe(f"Runtime command failed (exit {result.returncode}); CLI diagnostics withheld.")
    return result.stdout


def local_docker() -> None:
    context = os.environ.get("DOCKER_CONTEXT")
    host = command(["docker", "context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"], timeout=15).strip() if context else os.environ.get("DOCKER_HOST") or command(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout=15).strip()
    if not host.startswith(("unix://", "npipe://")):
        raise RuntimeErrorSafe("Only a local Docker socket is allowed; remote Docker targets are refused.")
    command(["docker", "info"], timeout=30)


def cli_path() -> str:
    executable = os.environ.get("SUPABASE_CLI") or shutil.which("supabase")
    if not executable or command([executable, "--version"], timeout=15).strip() != CLI_VERSION:
        raise RuntimeErrorSafe(f"Supabase CLI {CLI_VERSION} is required.")
    return executable


def confined_directory(path: str | Path) -> Path:
    raw = Path(path).absolute()
    # macOS exposes system temp roots through these fixed OS symlinks.
    for alias, canonical in (("/tmp", "/private/tmp"), ("/var", "/private/var")):
        prefix = Path(alias)
        if prefix.is_symlink() and prefix.resolve() == Path(canonical) and raw.is_relative_to(prefix):
            raw = Path(canonical) / raw.relative_to(prefix)
            break
    if raw != raw.resolve() or raw.is_symlink():
        raise RuntimeErrorSafe("Session directory must not contain symlinks.")
    if raw == ROOT or ROOT in raw.parents:
        raise RuntimeErrorSafe("Session directory must be outside the database checkout.")
    return raw


def create_session(path: str) -> Path:
    session = confined_directory(path)
    if session.exists():
        raise RuntimeErrorSafe("Session directory already exists; refusing to reuse it.")
    session.mkdir(mode=0o700, parents=True)
    return session


def private_json(path: Path, value: dict) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    path.chmod(0o600)


def load_private(path: Path) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise RuntimeErrorSafe("Target, receipt and credentials files must be regular private files (0600).")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        raise RuntimeErrorSafe("Invalid private JSON file.") from None
    if not isinstance(value, dict):
        raise RuntimeErrorSafe("Private JSON must contain an object.")
    return value


def free_ports(count: int) -> list[int]:
    held = []
    try:
        for _ in range(count):
            connection = socket.socket()
            connection.bind(("127.0.0.1", 0))
            held.append(connection)
        return [connection.getsockname()[1] for connection in held]
    finally:
        for connection in held:
            connection.close()


def configure_local(session: Path, project_id: str) -> None:
    config = (ROOT / "supabase/config.toml").read_text(encoding="utf-8")
    import tomllib
    parsed = tomllib.loads(config)
    if parsed.get("project_id") != "tiangong-ai-database" or "remotes" in parsed or "env(" in config:
        raise RuntimeErrorSafe("Consumer runtime requires the unlinked credential-free database config.")
    config = re.sub(r'^project_id = .+$', f'project_id = "{project_id}"', config, count=1, flags=re.M)
    api, db, shadow, smtp, studio, analytics, pooler, inspector = free_ports(8)
    for section, values in {
        "api": {"port": api, "enabled": True},
        "db": {"port": db, "shadow_port": shadow},
        "local_smtp": {"port": smtp},
        "studio": {"port": studio},
        "analytics": {"port": analytics},
        "db.pooler": {"port": pooler},
        "auth": {"enabled": True},
        "edge_runtime": {"enabled": False},
    }.items():
        found = re.search(rf'^\[{re.escape(section)}\]\n(.*?)(?=^\[|\Z)', config, re.M | re.S)
        if not found:
            raise RuntimeErrorSafe(f"Missing expected local config section: {section}")
        text = found.group(1)
        for field, value in values.items():
            replacement = str(value).lower() if isinstance(value, bool) else str(value)
            text, count = re.subn(rf'^{field} = .+$', f'{field} = {replacement}', text, flags=re.M)
            if count != 1:
                raise RuntimeErrorSafe(f"Unexpected local config field: {section}.{field}")
        if section == "edge_runtime":
            text += f"inspector_port = {inspector}\n"
        config = config[:found.start(1)] + text + config[found.end(1):]
    supabase = session / "supabase"
    supabase.mkdir()
    (supabase / "config.toml").write_text(config, encoding="utf-8")
    shutil.copyfile(ROOT / "supabase/seed.sql", supabase / "seed.sql")
    (supabase / "migrations").mkdir()
    for source in sorted((ROOT / "supabase/migrations").glob("*.sql")):
        if source.is_symlink():
            raise RuntimeErrorSafe("Migration symlinks are not allowed.")
        shutil.copyfile(source, supabase / "migrations" / source.name)


def stop(session: Path) -> None:
    state = load_private(session / "session.json")
    if state.get("schema_version") != 1 or state.get("session_dir") != str(session):
        raise RuntimeErrorSafe("Invalid session ownership record.")
    if state.get("mode") == "local":
        project = state.get("project_id", "")
        if not re.fullmatch(PROJECT_PREFIX + r"[0-9a-f]{16,24}", project):
            raise RuntimeErrorSafe("Refusing to stop a project outside consumer runtime ownership.")
        if state.get("owns_stack") is True:
            local_docker()
            # CLI 2.120 truncates config project IDs to 40 characters, while
            # stop's explicit project-id filter does not normalize them.
            project = project[:40]
            existing = command(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=30).splitlines()
            if "supabase_db_" + project in existing:
                labels = json.loads(command(["docker", "inspect", "--format", "{{json .Config.Labels}}", "supabase_db_" + project], timeout=30))
                if labels.get("com.supabase.cli.workdir") != str(session) or labels.get("com.supabase.cli.project") != project:
                    raise RuntimeErrorSafe("Container labels do not match this session; refusing cleanup.")
            if state.get("stopped") is True and not any(name.endswith("_" + project) for name in existing):
                return
            command([cli_path(), "stop", "--workdir", str(session), "--project-id", project, "--no-backup"])
            remaining = command(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=30).splitlines()
            remaining += command(["docker", "volume", "ls", "--format", "{{.Name}}"], timeout=30).splitlines()
            if any(name.endswith("_" + project) for name in remaining):
                raise RuntimeErrorSafe("Owned containers or volumes remain after stop; cleanup is incomplete.")
    elif state.get("mode") != "preview":
        raise RuntimeErrorSafe("Invalid session mode.")
    # Keep only non-secret metadata; stop never connects to or resets a preview DB.
    (session / "target.json").unlink(missing_ok=True)
    if (session / "supabase").exists():
        shutil.rmtree(session / "supabase")
    state["stopped"] = True
    private_json(session / "session.json", state)


def start_local(path: str) -> Path:
    local_docker()
    cli = cli_path()
    session = create_session(path)
    run_id = uuid.uuid4().hex
    # Keep below CLI's 40-character project-ID limit without truncation.
    project = PROJECT_PREFIX + run_id[:16]
    state = {"schema_version": 1, "mode": "local", "run_id": run_id, "project_id": project, "session_dir": str(session), "owns_stack": False}
    private_json(session / "session.json", state)
    try:
        configure_local(session, project)
        containers = command(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=30).splitlines()
        volumes = command(["docker", "volume", "ls", "--format", "{{.Name}}"], timeout=30).splitlines()
        if any(name.endswith("_" + project) for name in containers + volumes):
            # Do not call stop on a collision; it belongs to someone else.
            state["mode"] = "collision"
            private_json(session / "session.json", state)
            raise RuntimeErrorSafe("Refusing to reuse an existing project container or volume.")
        state["owns_stack"] = True
        private_json(session / "session.json", state)
        command([cli, "start", "--workdir", str(session), "-x", EXCLUDED_SERVICES])
        status = json.loads(command([cli, "status", "--workdir", str(session), "-o", "json"]))
        target = {
            **state,
            "api_url": status.get("API_URL"),
            "publishable_key": status.get("ANON_KEY") or status.get("PUBLISHABLE_KEY"),
            "service_role_key": status.get("SERVICE_ROLE_KEY") or status.get("SECRET_KEY"),
            "db_url": status.get("DB_URL"),
            "project_ref": project,
            "parent_project_ref": None,
            "branch_name": None,
            "workdir": str(session),
        }
        validate_target(target)
        private_json(session / "target.json", target)
        return session / "target.json"
    except Exception:
        if state["mode"] != "collision":
            try:
                stop(session)
            except RuntimeErrorSafe:
                raise RuntimeErrorSafe("Local startup failed and cleanup failed; retry stop for this session.") from None
        raise


def validate_target(target: dict) -> None:
    if target.get("schema_version") != 1 or not isinstance(target.get("run_id"), str) or not re.fullmatch(r"[0-9a-f]{32}", target["run_id"]):
        raise RuntimeErrorSafe("Invalid consumer target identity.")
    for key in ("api_url", "publishable_key", "service_role_key", "db_url"):
        if not isinstance(target.get(key), str) or not target[key]:
            raise RuntimeErrorSafe(f"Consumer target is missing {key}.")
    api = urlsplit(target["api_url"])
    db = urlsplit(target["db_url"])
    if api.username or api.password or api.path not in ("", "/") or api.query or api.fragment:
        raise RuntimeErrorSafe("API URL must identify only the selected API origin.")
    if any(key not in ("sslmode", "connect_timeout", "application_name") for key, _ in parse_qsl(db.query)) or db.fragment:
        raise RuntimeErrorSafe("Database URL routing overrides are forbidden.")
    ref = target.get("project_ref")
    if ref == PRODUCTION_REF or PRODUCTION_REF in (api.hostname or "") or PRODUCTION_REF in (db.hostname or "") or PRODUCTION_REF in (db.username or ""):
        raise RuntimeErrorSafe("Production targets are forbidden.")
    if db.scheme not in ("postgres", "postgresql") or not db.hostname:
        raise RuntimeErrorSafe("Invalid database target URL.")
    if target.get("mode") == "local":
        if api.scheme != "http" or api.hostname not in ("127.0.0.1", "localhost") or db.hostname not in ("127.0.0.1", "localhost"):
            raise RuntimeErrorSafe("Local targets must use loopback API and database hosts.")
        if not str(ref).startswith(PROJECT_PREFIX):
            raise RuntimeErrorSafe("Invalid local project identity.")
    elif target.get("mode") == "preview":
        if not re.fullmatch(r"[a-z]{20}", str(ref)) or api.scheme != "https" or api.hostname != f"{ref}.supabase.co":
            raise RuntimeErrorSafe("Preview API host must match the explicitly selected project ref.")
        if db.hostname != f"db.{ref}.supabase.co" and not (db.hostname.endswith(".pooler.supabase.com") and db.username == f"postgres.{ref}"):
            raise RuntimeErrorSafe("Preview database host/user must match the selected project ref.")
        verify_receipt(target.get("verification_receipt", {}), ref, target.get("parent_project_ref"), target.get("branch_name"))
    else:
        raise RuntimeErrorSafe("Unsupported consumer target mode.")


def verify_receipt(receipt: dict, ref: str, parent: str, branch: str) -> None:
    if not isinstance(receipt, dict) or not ref or not parent or not branch or ref == parent or ref == PRODUCTION_REF:
        raise RuntimeErrorSafe("Explicit distinct preview ref, parent ref and branch are required.")
    expected = {"verification_source": "supabase-management-mcp", "project_ref": ref, "parent_project_ref": parent, "branch_name": branch, "is_preview": True, "status": "ACTIVE_HEALTHY"}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise RuntimeErrorSafe("Preview verification receipt does not match the expected branch metadata.")
    try:
        verified = datetime.fromisoformat(receipt["verified_at"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - verified).total_seconds()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise RuntimeErrorSafe("Invalid preview verification timestamp.") from None
    if not 0 <= age <= 86400:
        raise RuntimeErrorSafe("Preview verification must be refreshed within 24 hours.")


def preview(args: argparse.Namespace) -> Path:
    receipt = load_private(Path(args.receipt_file))
    credentials = load_private(Path(args.credentials_file))
    verify_receipt(receipt, args.expected_ref, args.expected_parent, args.expected_branch)
    target = {**{k: credentials.get(k) for k in ("api_url", "publishable_key", "service_role_key", "db_url")}, "schema_version": 1, "mode": "preview", "run_id": uuid.uuid4().hex, "project_ref": args.expected_ref, "parent_project_ref": args.expected_parent, "branch_name": args.expected_branch, "verification_receipt": receipt}
    validate_target(target)
    session = create_session(args.session_dir)
    target["session_dir"] = str(session)
    private_json(session / "session.json", {k: target[k] for k in ("schema_version", "mode", "run_id", "session_dir")})
    private_json(session / "target.json", target)
    return session / "target.json"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    start = sub.add_parser("start-local")
    start.add_argument("--session-dir", required=True)
    end = sub.add_parser("stop")
    end.add_argument("--session-dir", required=True)
    inspect = sub.add_parser("validate-target")
    inspect.add_argument("--target", required=True)
    branch = sub.add_parser("prepare-preview")
    for option in ("session-dir", "credentials-file", "receipt-file", "expected-ref", "expected-parent", "expected-branch"):
        branch.add_argument("--" + option, required=True)
    args = parser.parse_args()
    if args.operation == "start-local":
        path = start_local(args.session_dir)
    elif args.operation == "prepare-preview":
        path = preview(args)
    elif args.operation == "stop":
        stop(confined_directory(args.session_dir))
        print("Stopped the owned consumer session.")
        return
    else:
        path = Path(args.target)
    target = load_private(path)
    validate_target(target)
    print(json.dumps({"target_file": str(path), "mode": target["mode"], "run_id": target["run_id"], "project_ref": target["project_ref"], "api_url": target["api_url"]}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeErrorSafe, OSError, ValueError) as error:
        print(f"Error: {error}" if isinstance(error, RuntimeErrorSafe) else "Error: runtime operation failed; diagnostics withheld.", file=sys.stderr)
        raise SystemExit(1)
