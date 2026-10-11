"""Verify provenance coverage and exact bytes of the initial SQL transfer."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourceInventoryTests(unittest.TestCase):
    def test_inventory_covers_all_transferred_sql_without_duplicates(self):
        inventory = json.loads((ROOT / "docs/source-inventory.json").read_text())
        assets = inventory["assets"]
        paths = [asset["path"] for asset in assets]
        actual = {path.relative_to(ROOT).as_posix() for directory in ("supabase/migrations", "tests/sql") for path in (ROOT / directory).glob("*.sql")}
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(set(paths), actual)
        self.assertEqual(sum(asset["kind"] == "migration" for asset in assets), 35)
        self.assertEqual(sum(asset["kind"] == "smoke" for asset in assets), 16)
        for asset in assets:
            with self.subTest(path=asset["path"]):
                self.assertEqual(asset["source_repository"], inventory["source_repository"])
                self.assertEqual(asset["source_commit"], inventory["source_commit"])
                self.assertRegex(asset["source_commit"], r"^[0-9a-f]{40}$")
                self.assertEqual(asset["source_path"], asset["path"])
                self.assertEqual(hashlib.sha256((ROOT / asset["path"]).read_bytes()).hexdigest(), asset["sha256"])


if __name__ == "__main__":
    unittest.main()
