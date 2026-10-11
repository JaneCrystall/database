"""Local schema inspection and migration authoring; never applies database changes.

This module uses only Python's standard library. CLI diagnostics are deliberately
not forwarded: Supabase may include connection strings in a failed command.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCHEMAS = ("public",)
ENVIRONMENTS = ("local", "dev", "main")
IDENT = r'(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9$]*)'
QUALIFIED = rf'{IDENT}(?:\s*\.\s*{IDENT})?'
DOLLAR = re.compile(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$')


class WorkflowError(RuntimeError):
    """An operator-readable error that contains no database credentials."""


def repo_path(value: str | Path) -> Path:
    """Confine writes and authoring inputs to this checkout, without symlinks."""
    raw = Path(value)
    if ".." in raw.parts:
        raise WorkflowError("Parent directory traversal is not allowed.")
    path = raw if raw.is_absolute() else REPO_ROOT / raw
    root = REPO_ROOT.resolve()
    try:
        relative = path.relative_to(root)
        path.resolve().relative_to(root)
    except ValueError:
        raise WorkflowError("The path must be inside this repository.") from None
    cursor = root
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            raise WorkflowError("Symlink paths are not supported for authoring or output.")
    return path


def atomic_write(path: Path, content: str, replace: bool = True) -> None:
    path = repo_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
        else:
            # Same-directory hard-link publication is atomic and fails if a
            # concurrent author already created the requested destination.
            os.link(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def normalized(text: str) -> str:
    # Whitespace inside multiline SQL literals is meaningful. Normalize only
    # the file boundary, never individual lines inside function definitions.
    return text.rstrip() + "\n"


def cli_command() -> list[str]:
    executable = os.environ.get("SUPABASE_CLI") or shutil.which("supabase")
    if not executable:
        raise WorkflowError("Supabase CLI is unavailable; set SUPABASE_CLI to its executable.")
    return [executable]


def run_cli(arguments: list[str], workdir: Path | None = None) -> str:
    workdir = repo_path(workdir or REPO_ROOT)
    try:
        result = subprocess.run(
            [*cli_command(), *arguments, "--workdir", str(workdir)],
            cwd=workdir, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, check=False,
        )
    except (OSError, UnicodeError):
        raise WorkflowError("Supabase CLI could not be executed.") from None
    if result.returncode:
        raise WorkflowError(f"Supabase CLI failed (exit {result.returncode}); diagnostics withheld.")
    return result.stdout


def db_url(environment: str) -> str:
    """Read one explicit remote binding without sourcing shell files."""
    if environment not in ("dev", "main"):
        raise WorkflowError("Remote database environment must be dev or main.")
    value = os.environ.get("SUPABASE_DB_URL")
    if not value:
        env_file = repo_path(f".env.supabase.{environment}.local")
        if not env_file.is_file():
            raise WorkflowError(f"Configure SUPABASE_DB_URL or .env.supabase.{environment}.local first.")
        for line in env_file.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"\s*(?:export\s+)?SUPABASE_DB_URL\s*=\s*(.*?)\s*", line)
            if match:
                value = match.group(1)
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                break
    try:
        parsed = urlsplit(value or "")
        valid = parsed.scheme in ("postgres", "postgresql") and bool(parsed.hostname)
    except ValueError:
        valid = False
    if not valid:
        raise WorkflowError("SUPABASE_DB_URL must be a PostgreSQL connection URL.")
    return value  # type: ignore[return-value]


def target_args(environment: str) -> list[str]:
    if environment not in ENVIRONMENTS:
        raise WorkflowError("Unsupported database environment.")
    return ["--local"] if environment == "local" else ["--db-url", db_url(environment)]


def schema_args(schemas: list[str] | tuple[str, ...]) -> list[str]:
    if not schemas or any(not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", schema) for schema in schemas):
        raise WorkflowError("Schemas must be nonempty plain SQL identifiers.")
    return ["--schema", ",".join(dict.fromkeys(schemas))]


def split_sql_statements(sql: str) -> list[str]:
    """Split pg_dump SQL, preserving comments, strings and nested comment blocks.

    pg_dump's random psql restriction marker is transport metadata, not SQL.
    Other psql commands are rejected rather than silently discarded.
    """
    statements: list[str] = []
    start = 0
    state = "normal"
    depth = 0
    dollar = ""
    escaped_string = False
    i = 0
    while i < len(sql):
        ch = sql[i]
        pair = sql[i:i + 2]
        if state == "line":
            if ch == "\n":
                state = "normal"
        elif state == "block":
            if pair == "/*":
                depth += 1
                i += 1
            elif pair == "*/":
                depth -= 1
                i += 1
                if depth == 0:
                    state = "normal"
        elif state in ("single", "double"):
            quote = "'" if state == "single" else '"'
            if state == "single" and escaped_string and ch == "\\":
                i += 1
            elif ch == quote:
                if i + 1 < len(sql) and sql[i + 1] == quote:
                    i += 1
                else:
                    state = "normal"
        elif state == "dollar":
            if sql.startswith(dollar, i):
                i += len(dollar) - 1
                state = "normal"
        else:
            if pair == "--":
                state = "line"
                i += 1
            elif pair == "/*":
                state = "block"
                depth = 1
                i += 1
            elif ch == "'":
                state = "single"
                escaped_string = i > 0 and sql[i - 1] in "Ee" and (i < 2 or not re.match(r"[\w$]", sql[i - 2]))
            elif ch == '"':
                state = "double"
            elif ch == "$" and (i == 0 or not re.match(r"[\w$]", sql[i - 1])) and (match := DOLLAR.match(sql, i)):
                dollar = match.group(0)
                state = "dollar"
                i += len(dollar) - 1
            elif ch == "\\" and not sql[sql.rfind("\n", 0, i) + 1:i].strip():
                line_end = sql.find("\n", i)
                if line_end < 0:
                    line_end = len(sql)
                if not re.match(r"^\\(?:un)?restrict(?:\s|$)", sql[i:line_end]):
                    raise WorkflowError("Unsupported psql command in schema input.")
                # Remove only top-level transport commands, never function literals.
                sql = sql[:i] + sql[line_end:]
                continue
            elif ch == ";":
                statements.append(sql[start:i + 1].strip())
                start = i + 1
        i += 1
    if state not in ("normal", "line"):
        raise WorkflowError("Unterminated quoted string or comment in SQL input.")
    if sql[start:].strip():
        statements.append(sql[start:].strip())
    return statements


def leading_sql(statement: str) -> str:
    """Remove leading comments for classification, leaving stored SQL untouched."""
    text = statement.lstrip()
    while text.startswith(("--", "/*")):
        if text.startswith("--"):
            newline = text.find("\n")
            text = "" if newline < 0 else text[newline + 1:].lstrip()
        else:
            depth, i = 1, 2
            while i < len(text) and depth:
                if text[i:i + 2] == "/*":
                    depth += 1
                    i += 2
                elif text[i:i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            text = text[i:].lstrip()
    return text


def name_parts(token: str) -> list[str]:
    return [part[1:-1].replace('""', '"') if part.startswith('"') else part.lower()
            for part in re.findall(IDENT, token)]


def path_component(value: str) -> str:
    """Injective filename encoding: quoted SQL names cannot traverse directories."""
    # Encode uppercase bytes too: quoted "Name" and unquoted name must stay
    # distinct on case-insensitive macOS and Windows filesystems.
    encoded = "".join(chr(byte) if chr(byte) in "abcdefghijklmnopqrstuvwxyz0123456789_-"
                      else f"%{byte:02X}" for byte in value.encode("utf-8"))
    if encoded.upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
        encoded = f"%{ord(encoded[0]):02X}" + encoded[1:]
    return encoded or "%00"


def statement_destination(statement: str) -> Path:
    text = leading_sql(statement)
    flags = re.IGNORECASE | re.DOTALL

    def match(pattern: str):
        return re.match(pattern, text, flags)

    def object_path(token: str, kind: str, filename: str = "definition.sql") -> Path:
        names = name_parts(token)
        if len(names) != 2:
            return fallback()
        return Path("schemas", path_component(names[0]), kind, path_component(names[1]), filename)

    def fallback() -> Path:
        return Path("global", "other", hashlib.sha256(statement.encode()).hexdigest() + ".sql")

    if not text or match(r"^(?:SET\s|SELECT\s+pg_catalog\.set_config\s*\()"):
        return Path("global/preamble.sql")
    if match(r"^ALTER\s+DEFAULT\s+PRIVILEGES\s"):
        return Path("global/default_privileges.sql")
    if found := match(rf"^(?:CREATE\s+SCHEMA(?:\s+IF\s+NOT\s+EXISTS)?|ALTER\s+SCHEMA|COMMENT\s+ON\s+SCHEMA)\s+({IDENT})"):
        return Path("schemas", path_component(name_parts(found[1])[0]), "schema.sql")
    if found := match(rf"^CREATE\s+EXTENSION(?:\s+IF\s+NOT\s+EXISTS)?\s+({IDENT})"):
        return Path("global", "extensions", path_component(name_parts(found[1])[0]) + ".sql")
    for kind, keyword in (("functions", "FUNCTION"), ("procedures", "PROCEDURE"),
                          ("materialized_views", "MATERIALIZED\\s+VIEW"), ("views", "VIEW"),
                          ("types", "TYPE"), ("sequences", "SEQUENCE"), ("tables", "TABLE")):
        if found := match(rf"^(?:CREATE\s+(?:OR\s+REPLACE\s+)?{keyword}(?:\s+IF\s+NOT\s+EXISTS)?|ALTER\s+{keyword}(?:\s+ONLY)?|COMMENT\s+ON\s+{keyword})\s+({QUALIFIED})"):
            return object_path(found[1], kind, "table.sql" if kind == "tables" else "definition.sql")
        if found := match(rf"^(?:GRANT|REVOKE)\s+.+?\s+ON\s+{keyword}\s+({QUALIFIED})"):
            return object_path(found[1], kind, "table.sql" if kind == "tables" else "definition.sql")
    if found := match(rf"^(?:CREATE|ALTER|DROP)\s+(?:OR\s+REPLACE\s+)?POLICY\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+ON\s+({QUALIFIED})"):
        root = object_path(found[2], "tables", "table.sql")
        if root.parts[0] == "schemas":
            return root.parent / "policies" / (path_component(name_parts(found[1])[0]) + ".sql")
    if found := match(rf"^(?:CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?|ALTER\s+|DROP\s+)TRIGGER\s+(?:IF\s+EXISTS\s+)?({IDENT})\s+(?:.+?\s+)?ON\s+({QUALIFIED})"):
        root = object_path(found[2], "tables", "table.sql")
        if root.parts[0] == "schemas":
            return root.parent / "triggers" / (path_component(name_parts(found[1])[0]) + ".sql")
    if found := match(rf"^CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?({IDENT})\s+ON\s+(?:ONLY\s+)?({QUALIFIED})"):
        root = object_path(found[2], "tables", "table.sql")
        if root.parts[0] == "schemas":
            return root.parent / "indexes" / (path_component(name_parts(found[1])[0]) + ".sql")
    return fallback()


def sql_input(path: Path) -> str:
    try:
        # Authoring sources retain their exact UTF-8 bytes, including CRLF and
        # meaningful whitespace in multiline literals. Do not apply text-mode
        # universal-newline conversion or formatting here.
        text = path.read_bytes().decode("utf-8")
    except (OSError, UnicodeError):
        raise WorkflowError("SQL input cannot be read as UTF-8.") from None
    if not any(leading_sql(statement) for statement in split_sql_statements(text)):
        raise WorkflowError("SQL input contains no executable statements.")
    return text


def _dump_sql(environment: str, schemas, temporary_parent: Path) -> str:
    target = target_args(environment)
    schema_options = schema_args(schemas)
    with tempfile.TemporaryDirectory(prefix=".schema-dump-", dir=temporary_parent) as temporary:
        dumped = Path(temporary) / "schema.sql"
        run_cli(["db", "dump", *target, *schema_options, "--file", str(dumped)])
        return "\n\n".join(split_sql_statements(sql_input(dumped))) + "\n"


def export_remote_schema(environment: str = "local", schemas=DEFAULT_SCHEMAS,
                         output_file: str | Path = "supabase/workspace/remote_schema.sql") -> Path:
    destination = repo_path(output_file)
    workspace = repo_path("supabase/workspace")
    try:
        relative = destination.relative_to(workspace)
    except ValueError:
        raise WorkflowError("Dump output must be in the generated schema workspace.") from None
    canonical = relative == Path("remote_schema.sql")
    if not canonical and not (len(relative.parts) >= 2 and relative.parts[0] == "exports" and destination.suffix == ".sql"):
        raise WorkflowError("Dump output must be remote_schema.sql or a new .sql file under workspace/exports.")
    if not canonical and destination.exists():
        raise WorkflowError("Custom dump output already exists; choose a new exports filename.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    content = _dump_sql(environment, schemas, destination.parent)
    try:
        atomic_write(destination, content, replace=canonical)
    except FileExistsError:
        raise WorkflowError("Custom dump output already exists; choose a new exports filename.") from None
    return destination


def build_schema_workspace(environment: str = "local", schemas=DEFAULT_SCHEMAS,
                           schema_file: str | Path | None = None) -> Path:
    workspace = repo_path("supabase/workspace")
    workspace.mkdir(parents=True, exist_ok=True)
    for name in ("global", "schemas", "remote_schema.sql"):
        repo_path(workspace / name)
    with tempfile.TemporaryDirectory(prefix=".workspace-build-", dir=workspace) as temporary:
        stage = Path(temporary) / "stage"
        backup = Path(temporary) / "backup"
        stage.mkdir()
        backup.mkdir()
        if schema_file is None:
            text = _dump_sql(environment, schemas, stage)
        else:
            source = Path(schema_file)
            if not source.is_absolute():
                source = REPO_ROOT / source
            text = "\n\n".join(split_sql_statements(sql_input(source))) + "\n"
        (stage / "remote_schema.sql").write_bytes(text.encode("utf-8"))
        files: dict[Path, list[str]] = {}
        for statement in split_sql_statements(text):
            files.setdefault(statement_destination(statement), []).append(statement)
        for directory in ("global", "schemas"):
            (stage / directory).mkdir(exist_ok=True)
        for relative, chunks in sorted(files.items()):
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(("\n\n".join(chunks) + "\n").encode("utf-8"))
        installed: list[str] = []
        moved: list[str] = []
        try:
            for name in ("global", "schemas", "remote_schema.sql"):
                old = workspace / name
                if old.exists():
                    os.replace(old, backup / name)
                    moved.append(name)
                os.replace(stage / name, old)
                installed.append(name)
        except OSError:
            for name in reversed(installed):
                path = workspace / name
                shutil.rmtree(path) if path.is_dir() else path.unlink()
            for name in reversed(moved):
                os.replace(backup / name, workspace / name)
            raise WorkflowError("Workspace replacement failed; previous generated files restored.") from None
    return workspace


def copy_workspace_file_to_changes(source_path: str | Path) -> list[Path]:
    source = repo_path(source_path)
    generated = repo_path("supabase/workspace/schemas")
    try:
        source.relative_to(generated)
    except ValueError:
        raise WorkflowError("Copy source must be under supabase/workspace/schemas.") from None
    if not source.exists():
        raise WorkflowError("Copy source does not exist.")
    inputs = sorted(source.rglob("*")) if source.is_dir() else [source]
    copies = []
    for path in inputs:
        repo_path(path)
        if path.is_file():
            destination = repo_path(Path("supabase/workspace/changes") / path.relative_to(generated))
            if destination.exists():
                raise WorkflowError("A changes file already exists; refusing to overwrite manual edits.")
            copies.append((path, destination))
    if not copies:
        raise WorkflowError("Copy source contains no files.")
    created: list[Path] = []
    try:
        for path, destination in copies:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as stream:
                created.append(destination)
                stream.write(path.read_bytes())
    except OSError:
        for destination in created:
            destination.unlink(missing_ok=True)
        raise WorkflowError("Copy failed; no existing changes files were overwritten.") from None
    return [destination for _, destination in copies]


@contextmanager
def migration_authoring_lock(migrations: Path):
    lock = repo_path(migrations / ".migration-authoring.lock")
    try:
        stream = lock.open("x", encoding="utf-8")
    except FileExistsError:
        raise WorkflowError("Migration authoring is already in progress; verify the lock owner before removing a stale lock.") from None
    try:
        with stream:
            stream.write(f"pid={os.getpid()}\n")
            stream.flush()
            os.fsync(stream.fileno())
        yield
    finally:
        lock.unlink(missing_ok=True)


def new_migration(name: str, source_path: str | Path) -> Path:
    source = repo_path(source_path)
    if source.suffix.lower() != ".sql":
        raise WorkflowError("Migration source must be an explicitly selected SQL file.")
    content = sql_input(source)
    slug = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    if not slug:
        raise WorkflowError("Migration name must contain letters or digits.")
    migrations = repo_path("supabase/migrations")
    migrations.mkdir(parents=True, exist_ok=True)
    # Allocate in an isolated workdir: CLI timestamp collisions must never
    # truncate an existing migration in the real checkout.
    with tempfile.TemporaryDirectory(prefix=".migration-create-", dir=migrations) as temporary:
        staging = Path(temporary)
        run_cli(["migration", "new", slug], workdir=staging)
        allocated = staging / "supabase/migrations"
        created = sorted(allocated.iterdir()) if allocated.is_dir() else []
        if len(created) != 1 or not re.fullmatch(rf"\d{{14}}_{re.escape(slug)}\.sql", created[0].name):
            raise WorkflowError("CLI did not create exactly one expected migration.")
        if created[0].is_symlink() or not created[0].is_file() or created[0].read_bytes():
            raise WorkflowError("CLI migration is not an empty regular file.")
        destination = repo_path(migrations / created[0].name)
        try:
            with migration_authoring_lock(migrations):
                version = created[0].name[:14]
                if any(migrations.glob(f"{version}_*.sql")):
                    raise WorkflowError("A migration with this timestamp version already exists; retry after the clock advances.")
                with destination.open("x", encoding="utf-8", newline="\n") as stream:
                    try:
                        stream.write(content)
                        stream.flush()
                        os.fsync(stream.fileno())
                    except OSError:
                        destination.unlink(missing_ok=True)
                        raise
        except FileExistsError:
            raise WorkflowError("A migration with this timestamp version already exists; retry after the clock advances.") from None
        except OSError:
            raise WorkflowError("Migration content could not be saved.") from None
    return destination


def build_database_types(environment: str = "local", schemas=DEFAULT_SCHEMAS,
                         check: bool = False) -> Path:
    destination = repo_path("types/database.types.ts")
    output = run_cli(["gen", "types", "typescript", *target_args(environment), *schema_args(schemas)])
    if not output.strip():
        raise WorkflowError("Supabase CLI returned no database types.")
    content = normalized(output)
    if check:
        if not destination.is_file() or destination.read_text(encoding="utf-8") != content:
            raise WorkflowError("Generated types/database.types.ts differs from the saved contract.")
    else:
        atomic_write(destination, content)
    return destination


def add_database_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--environment", choices=ENVIRONMENTS, default="local",
                        help="Database target; remote dev/main require explicit selection (default: local).")
    parser.add_argument("--schemas", nargs="+", default=list(DEFAULT_SCHEMAS),
                        help="Schemas to inspect (default: public).")


def entrypoint(callback) -> None:
    try:
        callback()
    except WorkflowError as error:
        raise SystemExit(f"Error: {error}") from None
    except (OSError, UnicodeError):
        raise SystemExit("Error: local file operation failed; check paths and permissions.") from None
