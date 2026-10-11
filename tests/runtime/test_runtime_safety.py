"""Exercise failure cleanup and remote-target refusal without touching Docker."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RuntimeSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.log = self.directory / "calls.jsonl"
        for name, body in {
            "docker": """
if sys.argv[1:3] == ['context', 'inspect']:
    print(os.environ.get('RUNTIME_DOCKER_CONTEXT_HOST', 'unix:///tmp/local-docker-test.sock'))
""",
            "supabase": """
if sys.argv[1:] == ['--version']:
    print('2.120.0')
elif sys.argv[1] == 'start':
    raise SystemExit(19)
""",
        }.items():
            executable = self.directory / name
            executable.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "with open(os.environ['RUNTIME_TEST_LOG'], 'a') as log:\n"
                f"    log.write(json.dumps([{name!r}, *sys.argv[1:]]) + '\\n')\n"
                + body
            )
            executable.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SUPABASE_CLI": str(self.directory / "supabase"),
            "PYTHON_BIN": sys.executable,
            "DOCKER_HOST": "unix:///tmp/local-docker-test.sock",
            "DOCKER_CONTEXT": "",
            "RUNTIME_TEST_LOG": str(self.log),
        }

    def run_script(self, *arguments):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/test-database.sh"), *arguments],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_remote_docker_is_refused_before_any_database_command(self):
        self.env["DOCKER_HOST"] = "ssh://production.example.invalid"
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertIn("remote Docker endpoints are refused", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_connection_arguments_are_refused_before_any_command(self):
        result = self.run_script("--db-url", "postgresql://remote.invalid/postgres")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_remote_context_overrides_local_host_and_is_refused(self):
        self.env["DOCKER_CONTEXT"] = "remote-context"
        self.env["RUNTIME_DOCKER_CONTEXT_HOST"] = "ssh://production.example.invalid"
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertIn("remote Docker endpoints are refused", result.stderr)
        self.assertTrue(all(call[:3] == ["docker", "context", "inspect"] for call in self.calls()))

    def test_failed_start_cleans_only_the_owned_stack(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 19, result.stderr)
        calls = self.calls()
        start = next(call for call in calls if call[:2] == ["supabase", "start"])
        stop = next(call for call in calls if call[:2] == ["supabase", "stop"])
        self.assertNotIn("--all", stop)
        self.assertIn("--no-backup", stop)
        project = stop[stop.index("--project-id") + 1]
        self.assertTrue(project.startswith("tiangong-ai-database-test-"))
        workdir = start[start.index("--workdir") + 1]
        self.assertEqual(workdir, stop[stop.index("--workdir") + 1])
        self.assertFalse(Path(workdir).exists())
        self.assertFalse(any(call[:3] == ["supabase", "db", "reset"] for call in calls))


if __name__ == "__main__":
    unittest.main()
