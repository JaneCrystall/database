#!/usr/bin/env python3
"""Qualify real Supabase output using only the gate's disposable workdir."""
import importlib.util
from pathlib import Path
import re
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: qualify_toolchain.py SOURCE_REPO DISPOSABLE_WORKDIR")
    source_root = Path(sys.argv[1]).resolve()
    temporary_root = Path(sys.argv[2]).resolve()
    if temporary_root == source_root or source_root in temporary_root.parents:
        raise SystemExit("Tool qualification must use a separate disposable workdir")
    if not temporary_root.name.startswith("tiangong-ai-database-test."):
        raise SystemExit("Tool qualification requires the local gate's temporary workdir")
    module_spec = importlib.util.spec_from_file_location(
        "database_qualification_workflow", source_root / "scripts/_db_workflow.py"
    )
    assert module_spec is not None and module_spec.loader is not None
    workflow = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(workflow)
    # No generated export, schema workspace or type file can touch the checkout.
    workflow.REPO_ROOT = temporary_root

    dump = workflow.export_remote_schema(environment="local", schemas=("public","private","api"))
    document_table = re.compile(r'CREATE TABLE\s+(?:IF NOT EXISTS\s+)?"?public"?\."?kb_documents"?\s*\(', re.I)
    actual_dump = dump.read_text(encoding="utf-8")
    declarations = re.findall(r'^CREATE[^\n]*TABLE[^\n]*', actual_dump, re.I | re.M)
    assert document_table.search(actual_dump), \
        f"The actual local schema export must include public.kb_documents; table declarations: {declarations}"
    print("Verified actual exported table:", document_table.search(actual_dump).group(0))
    workspace = workflow.build_schema_workspace(schema_file=dump)
    table = workspace / "schemas/public/tables/kb_documents/table.sql"
    assert table.is_file(), "The actual export must produce a kb_documents object workspace"
    assert document_table.search(table.read_text(encoding="utf-8"))
    types = workflow.build_database_types(environment="local", schemas=("public","api"))
    actual_types = types.read_text(encoding="utf-8")
    assert re.search(r'^export type Database\s*=\s*\{', actual_types, re.M), \
        "The generator must produce TypeScript, not a JSON output envelope"
    assert re.search(r'"?kb_documents"?\s*:\s*\{', actual_types), \
        "The actual local TypeScript output must include the kb_documents contract"
    assert types.resolve().is_relative_to(temporary_root)
    assert (workspace / "schemas/private/tables/kb_resource_entries/table.sql").is_file()
    assert 'kb_resource_command' in actual_types and re.search(r'\bapi\s*:', actual_types)
    assert 'kb_resource_entries' not in actual_types, "API types must not expose private storage"
    print("Real local schema export, offline object workspace and TypeScript generation passed.")


if __name__ == "__main__":
    main()
