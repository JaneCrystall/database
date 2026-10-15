"""Offline source-discovery checks for renamed and older workspace layouts."""
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


class WorkspaceSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name).resolve()
        self.consumers = self.workspace / "database/tests/consumers"
        self.consumers.mkdir(parents=True)

    def load(self, name):
        destination = self.consumers / f"{name}.py"
        shutil.copyfile(HERE / destination.name, destination)
        spec = importlib.util.spec_from_file_location(f"path_test_{name}", destination)
        module = importlib.util.module_from_spec(spec)
        with patch.object(sys, "path", [str(HERE), *sys.path]), patch.dict(sys.modules):
            # Standalone consumers import their runtime by filename. Keep it
            # isolated from the tests/runtime package during recursive discovery.
            sys.modules.pop("runtime", None)
            spec.loader.exec_module(module)
        return module

    def journal_paths(self, module, *extra):
        target = {"synthetic": True}
        with patch.object(sys, "argv", ["journals_consumer.py", "--target", "private-target.json", *extra]), patch.object(module, "load_private", return_value=target), patch.object(module, "run", return_value={"ok": True}) as run, redirect_stdout(io.StringIO()):
            self.assertEqual(module.main(), 0)
        self.assertIs(run.call_args.args[0], target)
        return run.call_args.args[1:]

    def test_both_layouts_prefer_canonical_sources(self):
        for name in ("web-app", "tiangong-ai-next", "edge-functions", "tiangong-ai-edge-function", "knowledge-base", "TianGong-AI-KB", "agent-skills", "skills"):
            (self.workspace / name).mkdir()
        web = self.load("run_web_edge")
        self.assertEqual(web.NEXT, self.workspace / "web-app")
        self.assertEqual(web.EDGE, self.workspace / "edge-functions")
        journals = self.load("journals_consumer")
        self.assertEqual(self.journal_paths(journals), (self.workspace / "knowledge-base", self.workspace / "agent-skills"))

    def test_legacy_only_layout_is_still_supported(self):
        for name in ("tiangong-ai-next", "tiangong-ai-edge-function", "TianGong-AI-KB", "skills"):
            (self.workspace / name).mkdir()
        web = self.load("run_web_edge")
        self.assertEqual(web.NEXT, self.workspace / "tiangong-ai-next")
        self.assertEqual(web.EDGE, self.workspace / "tiangong-ai-edge-function")
        journals = self.load("journals_consumer")
        self.assertEqual(self.journal_paths(journals), (self.workspace / "TianGong-AI-KB", self.workspace / "skills"))

    def test_absent_or_non_directory_sources_keep_canonical_failure_path(self):
        (self.workspace / "tiangong-ai-next").write_text("not a checkout")
        web = self.load("run_web_edge")
        self.assertEqual(web.NEXT, self.workspace / "web-app")
        self.assertEqual(web.EDGE, self.workspace / "edge-functions")
        journals = self.load("journals_consumer")
        self.assertEqual(self.journal_paths(journals), (self.workspace / "knowledge-base", self.workspace / "agent-skills"))

    def test_explicit_journal_overrides_remain_authoritative(self):
        for name in ("knowledge-base", "agent-skills", "custom-kb", "custom-skills"):
            (self.workspace / name).mkdir()
        journals = self.load("journals_consumer")
        kb = self.workspace / "custom-kb"
        skills = self.workspace / "custom-skills"
        self.assertEqual(self.journal_paths(journals, "--kb-root", str(kb), "--skills-root", str(skills)), (kb, skills))


if __name__ == "__main__":
    unittest.main()
