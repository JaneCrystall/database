"""Keep populated pre-resource upgrade qualification tied to its prior chain.

The complete fixture is the catalog from database main 223e05ccdd86505595f34166da0da2711c6d2294,
before migrations 20261013091136 and 20261013091317.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / 'tests/schema'


class PriorCatalogTests(unittest.TestCase):
    def qualify(self, catalog, baseline_only=False):
        with tempfile.TemporaryDirectory() as directory:
            actual = Path(directory) / 'actual.json'
            actual.write_text(json.dumps(catalog))
            command = [sys.executable, str(SCHEMA / 'check_catalog.py'), '--actual', str(actual)]
            if baseline_only:
                command.append('--baseline-only')
            result = subprocess.run(command, text=True, capture_output=True)
            return result.returncode, json.loads(result.stdout)

    def test_prior_chain_uses_its_own_jobs_definition(self):
        prior = json.loads((SCHEMA / 'pre_resource_catalog.expected.json').read_text())
        current = json.loads((SCHEMA / 'public_catalog.expected.json').read_text())
        code, report = self.qualify(prior, baseline_only=True)
        self.assertEqual(code, 0, report)
        code, report = self.qualify(current, baseline_only=True)
        self.assertNotEqual(code, 0)
        policy = json.loads((SCHEMA / 'legacy_acl_policy.json').read_text())
        expected_acl = {s.removeprefix('public.').split('(')[0] for s in policy['restricted_functions']} | set(policy['restricted_tables'])
        self.assertEqual(len(report['differences']), len(expected_acl) + 1)
        for difference in report['differences']:
            name = difference['name'].split('(')[0]
            if name == 'list_kb_admin_jobs':
                self.assertEqual(difference['fields'], ['body_md5'])
            else:
                self.assertIn(name, expected_acl)
                self.assertEqual(difference['fields'], ['acl'])
                expected_acl.remove(name)
        self.assertFalse(expected_acl)

    def test_s9_acl_delta_preserves_every_unselected_grant(self):
        prior = json.loads((SCHEMA / 'pre_resource_catalog.expected.json').read_text())
        current = json.loads((SCHEMA / 'public_catalog.expected.json').read_text())
        policy = json.loads((SCHEMA / 'legacy_acl_policy.json').read_text())
        functions = {s.removeprefix('public.').split('(')[0] for s in policy['restricted_functions']}
        self.assertEqual(len(functions), 18)
        self.assertEqual(len(policy['restricted_tables']), 23)
        for kind in ('relations', 'functions'):
            for before, after in zip(prior[kind], current[kind], strict=True):
                self.assertEqual(before['name'], after['name'])
                expected = before['acl']
                if kind == 'functions' and before['name'] in functions:
                    expected = [a for a in expected if a['grantee'] not in ('PUBLIC', 'anon', 'authenticated')]
                if kind == 'relations' and before['name'] in policy['restricted_tables']:
                    expected = [a for a in expected if not (a['grantee'] in ('PUBLIC', 'anon', 'authenticated') and a['privilege'] in policy['table_revocations'])]
                self.assertEqual(after['acl'], expected, before['name'])

    def test_current_chain_still_requires_optimized_jobs_and_resource_objects(self):
        current = json.loads((SCHEMA / 'public_catalog.expected.json').read_text())
        resource = json.loads((SCHEMA / 'resource_catalog.expected.json').read_text())
        for kind in ('functions', 'relations'):
            current[kind] += resource[kind]
        code, report = self.qualify(current)
        self.assertEqual(code, 0, report)
        prior = json.loads((SCHEMA / 'pre_resource_catalog.expected.json').read_text())
        prior_jobs = next(f for f in prior['functions'] if f['name'] == 'list_kb_admin_jobs')
        current_jobs = next(f for f in current['functions'] if f['name'] == 'list_kb_admin_jobs')
        current_jobs['body_md5'] = prior_jobs['body_md5']
        code, report = self.qualify(current)
        self.assertNotEqual(code, 0)
        self.assertEqual(report['differences'][0]['fields'], ['body_md5'])

    def test_prior_chain_keeps_privilege_checks(self):
        prior = json.loads((SCHEMA / 'pre_resource_catalog.expected.json').read_text())
        jobs = next(f for f in prior['functions'] if f['name'] == 'list_kb_admin_jobs')
        jobs['acl'] = []
        code, report = self.qualify(prior, baseline_only=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(report['differences'][0]['fields'], ['acl'])


if __name__ == '__main__':
    unittest.main()
