"""Publication and coverage invariants for the catalog-only legacy capture."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from _db_workflow import split_sql_statements,leading_sql

class LegacyCaptureTests(unittest.TestCase):
    def test_schema_capture_is_definition_only_and_inventory_is_exact(self):
        inventory=json.loads((ROOT/'docs/legacy-schema-inventory.json').read_text())
        content=(ROOT/inventory['migration']).read_text()
        statements=[leading_sql(s) for s in split_sql_statements(content)]
        statements=[s for s in statements if s]
        for statement in statements:
            self.assertRegex(statement,r'^(SET|CREATE|ALTER|GRANT|REVOKE|DO)\b')
            self.assertNotRegex(statement,r'(?i)\b(?:COPY\s+[^;]+\s+FROM\s+stdin|pg_catalog\.setval)\b')
        self.assertEqual(len(inventory['tables']),13)
        self.assertEqual(len(inventory['functions']),6)
        actual={hashlib.sha256(s.encode()).hexdigest() for s in statements}
        for recorded in inventory['statements']:
            self.assertIn(recorded['sha256'],actual)
        self.assertEqual(len(inventory['statements']),inventory['selected_statement_count'])
        self.assertNotRegex(content,r'https?://|eyJ[A-Za-z0-9_-]{20}|BEGIN .*PRIVATE KEY')
        self.assertNotRegex(content,r"'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'")
        self.assertNotIn('CREATE ROLE journals_reader LOGIN',content)
        self.assertIn('CREATE ROLE journals_reader NOLOGIN',content)

    def test_catalog_contract_covers_authorization_and_dependencies(self):
        snapshot=json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())
        self.assertEqual(len(snapshot['relations']),24)
        self.assertEqual(len(snapshot['functions']),72)
        by_name={r['name']:r for r in snapshot['relations']}
        self.assertTrue(all(r['rls'] for r in by_name.values()))
        self.assertTrue(by_name['esg_meta']['force_rls'])
        self.assertEqual(by_name['green_deal_meta']['policies'],[])
        self.assertTrue(any('auth.users' in c['definition'] for c in by_name['user_roles']['constraints']))
        self.assertTrue(any(i['name']=='doi_idx' for i in by_name['journals']['indexes']))
        for r in by_name.values():
            self.assertFalse(any(x['privilege']=='MAINTAIN' and x['grantee']!='postgres' for x in r['acl']))
        self.assertEqual(snapshot['lang'],['eng','chi_sim','chi_tra','fra','spa','jpn','kor','deu'])

if __name__=='__main__':unittest.main()
