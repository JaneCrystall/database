"""Safety boundaries exercised offline; no database credentials or Docker calls."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("consumer_runtime", Path(__file__).with_name("runtime.py"))
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


def local_target():
    return {"schema_version": 1, "run_id": "a" * 32, "mode": "local", "project_ref": runtime.PROJECT_PREFIX + "a" * 24, "api_url": "http://127.0.0.1:12345", "publishable_key": "synthetic-public", "service_role_key": "synthetic-private", "db_url": "postgresql://postgres:synthetic@127.0.0.1:12346/postgres"}


def preview_target():
    ref = "abcdefghijklmnopqrst"
    receipt = {"verification_source": "supabase-management-mcp", "project_ref": ref, "parent_project_ref": runtime.PRODUCTION_REF, "branch_name": "feature/issue-5", "is_preview": True, "status": "ACTIVE_HEALTHY", "verified_at": datetime.now(timezone.utc).isoformat()}
    return {**local_target(), "mode": "preview", "project_ref": ref, "parent_project_ref": runtime.PRODUCTION_REF, "branch_name": "feature/issue-5", "api_url": f"https://{ref}.supabase.co", "db_url": f"postgresql://postgres:synthetic@db.{ref}.supabase.co:5432/postgres", "verification_receipt": receipt}


class ConsumerRuntimeSafetyTests(unittest.TestCase):
    def test_targets_accept_local_and_verified_preview(self):
        runtime.validate_target(local_target())
        runtime.validate_target(preview_target())

    def test_production_ref_api_database_and_pooler_user_are_refused(self):
        for key, value in (("project_ref", runtime.PRODUCTION_REF), ("api_url", f"https://{runtime.PRODUCTION_REF}.supabase.co"), ("db_url", f"postgresql://postgres:x@db.{runtime.PRODUCTION_REF}.supabase.co/postgres"), ("db_url", f"postgresql://postgres.{runtime.PRODUCTION_REF}:x@aws-1.pooler.supabase.com/postgres")):
            with self.subTest(key=key, value=value):
                target = preview_target()
                target[key] = value
                with self.assertRaisesRegex(runtime.RuntimeErrorSafe, "Production"):
                    runtime.validate_target(target)

    def test_local_remote_urls_are_refused(self):
        for key, value in (("api_url", "https://foreign.invalid"), ("db_url", "postgresql://postgres:x@foreign.invalid/postgres")):
            target = local_target()
            target[key] = value
            with self.assertRaises(runtime.RuntimeErrorSafe):
                runtime.validate_target(target)

    def test_connection_query_cannot_override_verified_host(self):
        for query in ("host=production.invalid", "hostaddr=203.0.113.1", "service=production", "user=production"):
            target = preview_target()
            target["db_url"] += "?" + query
            with self.assertRaisesRegex(runtime.RuntimeErrorSafe, "routing overrides"):
                runtime.validate_target(target)

    def test_preview_requires_matching_fresh_metadata(self):
        for field, value in (("parent_project_ref", "wrong-parent"), ("branch_name", "main"), ("verification_source", "unverified"), ("is_preview", False), ("status", "INACTIVE"), ("verified_at", (datetime.now(timezone.utc) - timedelta(days=2)).isoformat())):
            with self.subTest(field=field):
                target = preview_target()
                target["verification_receipt"][field] = value
                with self.assertRaises(runtime.RuntimeErrorSafe):
                    runtime.validate_target(target)

    def test_remote_docker_context_overrides_local_host_and_is_refused(self):
        with patch.dict(os.environ, {"DOCKER_HOST": "unix:///tmp/test.sock", "DOCKER_CONTEXT": "remote"}), patch.object(runtime, "command", return_value="ssh://remote.invalid") as command:
            with self.assertRaisesRegex(runtime.RuntimeErrorSafe, "remote Docker"):
                runtime.local_docker()
            self.assertEqual(command.call_count, 1)

    def test_environment_omits_credentials_and_provider_overrides(self):
        with patch.dict(os.environ, {"SUPABASE_ACCESS_TOKEN": "secret", "SUPABASE_AUTH_SERVICE_ROLE_KEY": "secret", "REMOTE_SUPABASE_URL": "https://production.invalid", "AWS_SECRET_ACCESS_KEY": "secret", "KB_ENV_FILE": "/sensitive"}):
            forwarded = runtime.safe_environment()
            for key in ("SUPABASE_ACCESS_TOKEN", "SUPABASE_AUTH_SERVICE_ROLE_KEY", "REMOTE_SUPABASE_URL", "AWS_SECRET_ACCESS_KEY", "KB_ENV_FILE"):
                self.assertNotIn(key, forwarded)

    def test_private_json_and_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "target.json"
            runtime.private_json(path, local_target())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            runtime.validate_target(runtime.load_private(path))
            path.chmod(0o644)
            with self.assertRaises(runtime.RuntimeErrorSafe):
                runtime.load_private(path)

    def test_failed_start_stops_only_owned_stack(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary).resolve() / "session"
            calls = []
            def fake_command(arguments, **kwargs):
                calls.append(arguments)
                if "start" in arguments:
                    raise runtime.RuntimeErrorSafe("Synthetic start failure")
                return ""
            with patch.object(runtime, "local_docker"), patch.object(runtime, "cli_path", return_value="supabase"), patch.object(runtime, "command", side_effect=fake_command):
                with self.assertRaisesRegex(runtime.RuntimeErrorSafe, "Synthetic start failure"):
                    runtime.start_local(str(session))
            stops = [call for call in calls if "stop" in call]
            self.assertEqual(len(stops), 1)
            self.assertIn("--no-backup", stops[0])
            self.assertNotIn("--all", stops[0])
            self.assertTrue(stops[0][stops[0].index("--project-id") + 1].startswith(runtime.PROJECT_PREFIX))
            self.assertFalse((session / "target.json").exists())

    def test_preview_stop_performs_no_remote_or_docker_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary).resolve()
            runtime.private_json(session / "session.json", {"schema_version": 1, "mode": "preview", "session_dir": str(session)})
            runtime.private_json(session / "target.json", preview_target())
            with patch.object(runtime, "command") as command:
                runtime.stop(session)
                runtime.stop(session)
            command.assert_not_called()
            self.assertFalse((session / "target.json").exists())

    def test_stop_normalizes_legacy_long_id_and_checks_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary).resolve()
            original = runtime.PROJECT_PREFIX + "a" * 24
            actual = original[:40]
            runtime.private_json(session / "session.json", {"schema_version": 1, "mode": "local", "session_dir": str(session), "project_id": original, "owns_stack": True})
            calls = []
            def fake_command(arguments, **kwargs):
                calls.append(arguments)
                if "inspect" in arguments:
                    return json.dumps({"com.supabase.cli.workdir": str(session), "com.supabase.cli.project": actual})
                if arguments[:3] == ["docker", "ps", "-a"] and not any("stop" in call for call in calls):
                    return "supabase_db_" + actual
                return ""
            with patch.object(runtime, "local_docker"), patch.object(runtime, "cli_path", return_value="supabase"), patch.object(runtime, "command", side_effect=fake_command):
                runtime.stop(session)
            call = next(call for call in calls if "stop" in call)
            self.assertEqual(call[call.index("--project-id") + 1], actual)

    def test_stop_detects_success_exit_without_resource_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary).resolve()
            project = runtime.PROJECT_PREFIX + "a" * 16
            runtime.private_json(session / "session.json", {"schema_version": 1, "mode": "local", "session_dir": str(session), "project_id": project, "owns_stack": True})
            def fake_command(arguments, **kwargs):
                if "inspect" in arguments:
                    return json.dumps({"com.supabase.cli.workdir": str(session), "com.supabase.cli.project": project})
                return "supabase_db_" + project if arguments[:3] == ["docker", "ps", "-a"] else ""
            with patch.object(runtime, "local_docker"), patch.object(runtime, "cli_path", return_value="supabase"), patch.object(runtime, "command", side_effect=fake_command):
                with self.assertRaisesRegex(runtime.RuntimeErrorSafe, "cleanup is incomplete"):
                    runtime.stop(session)


if __name__ == "__main__":
    unittest.main()
