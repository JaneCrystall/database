"""Offline regressions for schema tooling and safe authoring boundaries."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import _db_workflow as db


FIXTURE = r'''\restrict random_transport_marker
-- pg_dump header
SET statement_timeout = 0;
CREATE SCHEMA public;
CREATE TABLE public.notes (id uuid, body text);
ALTER TABLE ONLY public.notes ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION public.echo(value text) RETURNS text
LANGUAGE plpgsql AS $body$
BEGIN
  /* nested /* inner; */ comment */
  RETURN E'escaped\'quote;still string';
END;
$body$;
COMMENT ON FUNCTION public.echo(text) IS 'semi;colon';
CREATE POLICY "read notes" ON public.notes FOR SELECT USING (true);
CREATE TRIGGER changed BEFORE UPDATE ON public.notes FOR EACH ROW EXECUTE FUNCTION public.echo();
CREATE INDEX notes_body ON public.notes USING btree (body);
CREATE VIEW public.note_names AS SELECT id FROM public.notes;
CREATE TYPE public.note_kind AS ENUM ('a', 'b');
SELECT unknown_extension_function('opaque;value');
\unrestrict random_transport_marker
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(db, "REPO_ROOT", self.root).start()
        patch.dict(os.environ, {"SUPABASE_CLI": "/fake/supabase"}).start()
        os.environ.pop("SUPABASE_DB_URL", None)

    def file(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def dump_runner(self, arguments, workdir=None):
        self.assertEqual(arguments[:2], ["db", "dump"])
        self.assertIn("--local", arguments)
        Path(arguments[arguments.index("--file") + 1]).write_text(FIXTURE, encoding="utf-8")
        return ""

    def migration_runner(self, arguments, workdir=None):
        self.assertEqual(arguments[:2], ["migration", "new"])
        self.assertNotEqual(workdir, self.root)
        path = workdir / "supabase/migrations" / ("20261011000000_" + arguments[2] + ".sql")
        path.parent.mkdir(parents=True)
        path.write_text("", encoding="utf-8")
        return ""

    def test_parser_preserves_function_strings_comments_and_unknown_sql(self):
        statements = db.split_sql_statements(FIXTURE)
        self.assertEqual(len(statements), 12)
        function = next(s for s in statements if "CREATE FUNCTION" in s)
        self.assertIn("/* nested /* inner; */ comment */", function)
        self.assertIn("RETURN E'escaped", function)
        self.assertTrue(function.endswith("$body$;"))
        self.assertNotIn("\\restrict random_transport_marker", "\n".join(statements))
        self.assertIn("'opaque;value'", statements[-1])

    def test_restriction_marker_inside_literal_is_preserved(self):
        sql = "CREATE FUNCTION public.f() RETURNS text AS $$\n\\restrict literal\n$$ LANGUAGE sql;"
        self.assertEqual(db.split_sql_statements(sql), [sql])

    def test_parser_handles_doubled_quotes_and_nested_comments(self):
        sql = '''/* outside /* nested; */ comment */ SELECT 'a'';b', "a"";b"; SELECT 2;'''
        self.assertEqual(len(db.split_sql_statements(sql)), 2)
        self.assertEqual(len(db.split_sql_statements(r"SELECT E'escaped\'quote;string'; SELECT 2;")), 2)

    def test_malformed_sql_and_psql_commands_fail(self):
        for sql in ("SELECT 'unfinished", "SELECT $$unfinished;", "/* unfinished", "\\connect another\nSELECT 1;"):
            with self.subTest(sql=sql), self.assertRaises(db.WorkflowError):
                db.split_sql_statements(sql)

    def test_routes_known_objects_and_preserves_unknowns(self):
        mapping = {
            "CREATE TABLE public.notes (id int);": "schemas/public/tables/notes/table.sql",
            "CREATE POLICY read ON public.notes USING (true);": "schemas/public/tables/notes/policies/read.sql",
            "DROP TRIGGER changed ON public.notes;": "schemas/public/tables/notes/triggers/changed.sql",
            "CREATE INDEX notes_id ON public.notes (id);": "schemas/public/tables/notes/indexes/notes_id.sql",
            "CREATE MATERIALIZED VIEW public.mv AS SELECT 1;": "schemas/public/materialized_views/mv/definition.sql",
            "GRANT EXECUTE ON FUNCTION public.f(text) TO service_role;": "schemas/public/functions/f/definition.sql",
        }
        for sql, expected in mapping.items():
            with self.subTest(sql=sql):
                self.assertEqual(db.statement_destination(sql).as_posix(), expected)
        unknown = db.statement_destination("SELECT custom_extension('x');")
        self.assertEqual(unknown.parts[:2], ("global", "other"))

    def test_identifier_encoding_prevents_traversal_and_collisions(self):
        statements = ['CREATE TABLE public."../../outside" (id int);',
                      'CREATE TABLE public."a/b" (id int);', 'CREATE TABLE public."a%2Fb" (id int);']
        paths = [db.statement_destination(s) for s in statements]
        self.assertEqual(len(set(paths)), 3)
        self.assertTrue(all(".." not in p.parts for p in paths))
        self.assertIn("%2F", paths[0].as_posix())
        self.assertNotEqual(db.path_component("a/b"), db.path_component("a_b"))
        self.assertNotEqual(db.path_component("Name").lower(), db.path_component("name").lower())

    def test_multiline_literal_whitespace_survives_authoring_and_inspection(self):
        source_sql = "CREATE FUNCTION public.f() RETURNS text AS $$line with spaces  \nnext$$ LANGUAGE sql;\n"
        source = self.file("authored.sql", source_sql)
        self.assertEqual(db.sql_input(source), source_sql)
        workspace = db.build_schema_workspace(schema_file=source)
        self.assertEqual((workspace / "schemas/public/functions/f/definition.sql").read_text(), source_sql)

    def test_migration_preserves_exact_utf8_bytes_and_crlf(self):
        raw = 'CREATE FUNCTION public.f() RETURNS text AS $$你好  \r\nline with spaces  \r\n$$ LANGUAGE sql;'.encode('utf-8')
        source = self.root / "authored.sql"
        source.write_bytes(raw)
        self.assertEqual(db.sql_input(source).encode('utf-8'), raw)
        with patch.object(db, "run_cli", side_effect=self.migration_runner):
            migration = db.new_migration("preserve bytes", source)
        self.assertEqual(migration.read_bytes(), raw)

    def test_offline_build_preserves_changes_and_removes_stale_generated_files(self):
        source = self.file("input.sql", FIXTURE)
        changes = self.file("supabase/workspace/changes/public/authored.sql", "SELECT 42;\n")
        stale = self.file("supabase/workspace/schemas/public/stale.sql", "SELECT 0;\n")
        with patch.object(db, "run_cli", side_effect=AssertionError("Offline builder must not connect")):
            workspace = db.build_schema_workspace(schema_file=source)
        self.assertEqual(changes.read_text(), "SELECT 42;\n")
        self.assertFalse(stale.exists())
        table = workspace / "schemas/public/tables/notes/table.sql"
        self.assertIn("ENABLE ROW LEVEL SECURITY", table.read_text())
        self.assertTrue((workspace / "schemas/public/functions/echo/definition.sql").is_file())
        self.assertTrue(list((workspace / "global/other").glob("*.sql")))
        first = {p.relative_to(workspace): p.read_bytes() for p in workspace.rglob("*") if p.is_file()}
        db.build_schema_workspace(schema_file=source)
        second = {p.relative_to(workspace): p.read_bytes() for p in workspace.rglob("*") if p.is_file()}
        self.assertEqual(first, second)

    def test_failed_offline_build_preserves_previous_generated_state(self):
        source = self.file("invalid.sql", "SELECT 'unfinished")
        previous = self.file("supabase/workspace/schemas/public/original.sql", "SELECT 1;\n")
        with self.assertRaises(db.WorkflowError):
            db.build_schema_workspace(schema_file=source)
        self.assertEqual(previous.read_text(), "SELECT 1;\n")

    def test_generated_symlink_is_rejected_before_refresh(self):
        self.file("input.sql", FIXTURE)
        external = self.root / "elsewhere"
        external.mkdir()
        workspace = self.root / "supabase/workspace"
        workspace.mkdir(parents=True)
        (workspace / "schemas").symlink_to(external, target_is_directory=True)
        with self.assertRaises(db.WorkflowError):
            db.build_schema_workspace(schema_file="input.sql")
        self.assertTrue(external.is_dir())

    def test_refresh_replacement_failure_rolls_back_all_generated_files(self):
        source = self.file("input.sql", FIXTURE)
        old = self.file("supabase/workspace/global/old.sql", "SELECT 99;\n")
        dump = self.file("supabase/workspace/remote_schema.sql", "SELECT 99;\n")
        real_replace = os.replace
        def fail_schemas_install(src, dst):
            if Path(src).name == "schemas" and Path(src).parent.name == "stage":
                raise OSError("simulated disk error")
            return real_replace(src, dst)
        with patch.object(db.os, "replace", side_effect=fail_schemas_install), self.assertRaises(db.WorkflowError):
            db.build_schema_workspace(schema_file=source)
        self.assertEqual(old.read_text(), "SELECT 99;\n")
        self.assertEqual(dump.read_text(), "SELECT 99;\n")

    def test_dump_is_local_by_default_and_replaces_atomically(self):
        with patch.object(db, "run_cli", side_effect=self.dump_runner):
            path = db.export_remote_schema()
        self.assertIn("CREATE TABLE", path.read_text())
        self.assertNotIn("\\restrict random_transport_marker", path.read_text())

    def test_dump_cannot_overwrite_migrations_changes_or_repository_sources(self):
        protected = (
            "supabase/migrations/20261011000000_original.sql",
            "supabase/workspace/changes/public/authored.sql",
            "supabase/workspace/schemas/public/table.sql",
            "supabase/workspace/global/other.sql",
            "supabase/workspace/README.md",
            "README.md",
            "scripts/authored.py",
            "supabase/config.toml",
        )
        for name in protected:
            original = self.file(name, "protected source\n")
            with self.subTest(name=name), patch.object(db, "run_cli") as cli:
                with self.assertRaises(db.WorkflowError):
                    db.export_remote_schema(output_file=name)
                cli.assert_not_called()
                self.assertEqual(original.read_text(), "protected source\n")

    def test_custom_dump_requires_new_generated_exports_sql_file(self):
        name = "supabase/workspace/exports/local-review.sql"
        with patch.object(db, "run_cli", side_effect=self.dump_runner):
            path = db.export_remote_schema(output_file=name)
        original = path.read_bytes()
        with patch.object(db, "run_cli") as cli, self.assertRaises(db.WorkflowError):
            db.export_remote_schema(output_file=name)
        cli.assert_not_called()
        self.assertEqual(path.read_bytes(), original)

    def test_concurrent_custom_dump_publication_never_overwrites_another_file(self):
        name = "supabase/workspace/exports/race.sql"
        real_link = os.link
        def competing_publication(src, dst):
            Path(dst).write_bytes(b"other author's complete dump\n")
            return real_link(src, dst)
        with patch.object(db, "run_cli", side_effect=self.dump_runner), patch.object(db.os, "link", side_effect=competing_publication):
            with self.assertRaises(db.WorkflowError):
                db.export_remote_schema(output_file=name)
        self.assertEqual((self.root / name).read_bytes(), b"other author's complete dump\n")

    def test_failed_or_invalid_dump_does_not_replace_existing_file(self):
        destination = self.file("supabase/workspace/remote_schema.sql", "SELECT 1;\n")
        for runner in (db.WorkflowError("CLI failed"), lambda args: Path(args[-1]).write_text("-- comments only\n")):
            with self.subTest(runner=runner), patch.object(db, "run_cli", side_effect=runner):
                with self.assertRaises(db.WorkflowError):
                    db.export_remote_schema()
                self.assertEqual(destination.read_text(), "SELECT 1;\n")

    def test_cli_failure_never_exposes_credentials_or_diagnostics(self):
        secret = "postgresql://operator:TOP_SECRET@db.invalid/postgres"
        failed = subprocess.CompletedProcess([], 7, stdout=secret, stderr="raw detail " + secret)
        with patch.object(db.subprocess, "run", return_value=failed), self.assertRaises(db.WorkflowError) as failure:
            db.run_cli(["db", "dump", "--db-url", secret])
        self.assertNotIn(secret, str(failure.exception))
        self.assertNotIn("TOP_SECRET", str(failure.exception))
        self.assertIn("exit 7", str(failure.exception))

    def test_unavailable_cli_and_missing_remote_environment_fail_closed(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(db.shutil, "which", return_value=None):
            with self.assertRaises(db.WorkflowError):
                db.run_cli(["--version"])
        with self.assertRaises(db.WorkflowError):
            db.target_args("dev")
        self.assertEqual(db.target_args("local"), ["--local"])

    def test_remote_url_read_from_environment_or_ignored_env_file(self):
        first = "postgresql://reader:secret@db.invalid/postgres"
        self.file(".env.supabase.dev.local", f"SUPABASE_DB_URL='{first}'\n")
        self.assertEqual(db.db_url("dev"), first)
        second = "postgres://reader:other@dev.invalid/postgres"
        with patch.dict(os.environ, {"SUPABASE_DB_URL": second}):
            self.assertEqual(db.target_args("main"), ["--db-url", second])
        with patch.dict(os.environ, {"SUPABASE_DB_URL": "https://secret.invalid"}), self.assertRaises(db.WorkflowError) as error:
            db.db_url("dev")
        self.assertNotIn("secret.invalid", str(error.exception))

    def test_path_traversal_output_outside_repo_and_symlinks_fail(self):
        for value in ("supabase/../outside.sql", self.root.parent / "outside.sql"):
            with self.subTest(value=value), self.assertRaises(db.WorkflowError):
                db.repo_path(value)
        linked = self.root / "linked"
        linked.symlink_to(self.root / "target")
        with self.assertRaises(db.WorkflowError):
            db.repo_path("linked/output.sql")

    def test_copy_preserves_relative_paths_and_never_overwrites_changes(self):
        source = self.file("supabase/workspace/schemas/public/tables/notes/table.sql", "CREATE TABLE public.notes (id int);\n")
        paths = db.copy_workspace_file_to_changes(source)
        self.assertEqual(paths[0].relative_to(self.root).as_posix(), "supabase/workspace/changes/public/tables/notes/table.sql")
        paths[0].write_text("hand edited\n")
        with self.assertRaises(db.WorkflowError):
            db.copy_workspace_file_to_changes(source)
        self.assertEqual(paths[0].read_text(), "hand edited\n")

    def test_directory_copy_preflights_conflicts_and_symlinks(self):
        source = self.file("supabase/workspace/schemas/public/a.sql", "SELECT 1;").parent
        self.file("supabase/workspace/schemas/public/z.sql", "SELECT 2;")
        self.file("supabase/workspace/changes/public/z.sql", "manual;")
        with self.assertRaises(db.WorkflowError):
            db.copy_workspace_file_to_changes(source)
        self.assertFalse((self.root / "supabase/workspace/changes/public/a.sql").exists())
        (source / "link.sql").symlink_to(source / "a.sql")
        with self.assertRaises(db.WorkflowError):
            db.copy_workspace_file_to_changes(source / "link.sql")

    def test_copy_outside_generated_tree_and_empty_directory_fail(self):
        outside = self.file("manual.sql", "SELECT 1;")
        with self.assertRaises(db.WorkflowError):
            db.copy_workspace_file_to_changes(outside)
        empty = self.root / "supabase/workspace/schemas/empty"
        empty.mkdir(parents=True)
        with self.assertRaises(db.WorkflowError):
            db.copy_workspace_file_to_changes(empty)

    def test_explicit_migration_preserves_sql_without_inferred_drop(self):
        sql = 'CREATE POLICY "quoted policy" ON public.notes USING (true);\n'
        source = self.file("supabase/workspace/changes/authored.sql", sql)
        with patch.object(db, "run_cli", side_effect=self.migration_runner):
            migration = db.new_migration("Add policy", source)
        self.assertEqual(migration.name, "20261011000000_add_policy.sql")
        self.assertEqual(migration.read_text(), sql)
        self.assertNotIn("DROP", migration.read_text())

    def test_migration_collision_keeps_existing_file(self):
        source = self.file("authored.sql", "SELECT 1;\n")
        old = self.file("supabase/migrations/20261011000000_change.sql", "original;\n")
        with patch.object(db, "run_cli", side_effect=self.migration_runner), self.assertRaises(db.WorkflowError):
            db.new_migration("change", source)
        self.assertEqual(old.read_text(), "original;\n")

    def test_migration_version_collision_rejects_a_different_name(self):
        source = self.file("authored.sql", "SELECT 1;\n")
        old = self.file("supabase/migrations/20261011000000_first.sql", "original;\n")
        with patch.object(db, "run_cli", side_effect=self.migration_runner), self.assertRaises(db.WorkflowError):
            db.new_migration("second", source)
        self.assertEqual(old.read_text(), "original;\n")
        self.assertFalse((old.parent / "20261011000000_second.sql").exists())

    def test_migration_lock_refuses_other_author_and_preserves_their_lock(self):
        source = self.file("authored.sql", "SELECT 1;\n")
        lock = self.file("supabase/migrations/.migration-authoring.lock", "other author\n")
        with patch.object(db, "run_cli", side_effect=self.migration_runner), self.assertRaises(db.WorkflowError):
            db.new_migration("change", source)
        self.assertEqual(lock.read_text(), "other author\n")
        self.assertEqual(list(lock.parent.glob("*.sql")), [])

    def test_concurrent_names_cannot_create_the_same_migration_version(self):
        source = self.file("authored.sql", "SELECT 1;\n")
        allocated = threading.Barrier(2)
        def runner(arguments, workdir=None):
            result = self.migration_runner(arguments, workdir)
            allocated.wait(timeout=5)
            return result
        results = []
        with patch.object(db, "run_cli", side_effect=runner), ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(db.new_migration, name, source) for name in ("first", "second")]
            for future in futures:
                try:
                    results.append(future.result())
                except db.WorkflowError:
                    results.append(None)
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(len(list((self.root / "supabase/migrations").glob("20261011000000_*.sql"))), 1)
        self.assertFalse((self.root / "supabase/migrations/.migration-authoring.lock").exists())

    def test_migration_rejects_non_sql_empty_source_and_invalid_name(self):
        for name, source in (("change", self.file("source.txt", "SELECT 1;")),
                             ("change", self.file("empty.sql", "-- only comment")),
                             ("!!!", self.file("valid.sql", "SELECT 1;"))):
            with self.subTest(name=name, source=source), patch.object(db, "run_cli") as cli:
                with self.assertRaises(db.WorkflowError):
                    db.new_migration(name, source)
                cli.assert_not_called()

    def test_unexpected_cli_migration_output_fails_without_creating_final_file(self):
        source = self.file("authored.sql", "SELECT 1;\n")
        with patch.object(db, "run_cli", return_value=""), self.assertRaises(db.WorkflowError):
            db.new_migration("change", source)
        self.assertEqual(list((self.root / "supabase/migrations").iterdir()), [])

    def test_types_generation_and_readonly_drift_check(self):
        contract = "export type Database = {};\n"
        with patch.object(db, "run_cli", return_value=contract) as cli:
            path = db.build_database_types()
            self.assertEqual(path.relative_to(self.root).as_posix(), "types/database.types.ts")
            self.assertIn("--local", cli.call_args.args[0])
            db.build_database_types(check=True)
        with patch.object(db, "run_cli", return_value="export type Different = {};\n"), self.assertRaises(db.WorkflowError):
            db.build_database_types(check=True)
        self.assertEqual(path.read_text(), contract)

    def test_failed_types_do_not_replace_saved_contract(self):
        saved = self.file("types/database.types.ts", "old contract\n")
        with patch.object(db, "run_cli", return_value=""), self.assertRaises(db.WorkflowError):
            db.build_database_types()
        self.assertEqual(saved.read_text(), "old contract\n")

    def test_schema_arguments_reject_invalid_names(self):
        self.assertEqual(db.schema_args(["public", "api", "public"]), ["--schema", "public,api"])
        for schemas in ([], ["public;DROP"], ["public,private"]):
            with self.subTest(schemas=schemas), self.assertRaises(db.WorkflowError):
                db.schema_args(schemas)

    def test_public_entrypoints_have_help_without_cli(self):
        for name in ("export_remote_schema", "build_schema_workspace", "copy_workspace_file_to_changes", "new_migration", "build_database_types"):
            with self.subTest(name=name):
                result = subprocess.run([sys.executable, str(SCRIPTS / f"{name}.py"), "--help"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("usage:", result.stdout)

    def test_public_cli_failure_has_no_traceback_or_credentials(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "export_remote_schema.py"), "--environment", "dev"],
                                capture_output=True, text=True, env={**os.environ, "SUPABASE_DB_URL": "https://USER_SECRET.invalid"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("USER_SECRET", result.stderr)


if __name__ == "__main__":
    unittest.main()
