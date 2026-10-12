import importlib.util
from pathlib import Path
import sys
import unittest
from urllib.error import HTTPError
from unittest.mock import patch

try:
    from . import fixtures
except ImportError:
    import fixtures

class FixtureCleanupTests(unittest.TestCase):
    def target(self):
        return {'schema_version':1,'mode':'local','run_id':'a'*32,
                'api_url':'http://127.0.0.1:54321','publishable_key':'synthetic',
                'service_role_key':'synthetic','db_url':'postgresql://postgres:synthetic@127.0.0.1:54322/postgres',
                'project_ref':'tiangong-ai-consumers-synthetic'}

    def test_auth_cleanup_accepts_already_deleted_user(self):
        with patch.object(fixtures,'urlopen',side_effect=HTTPError('http://localhost',404,'missing',{},None)):
            self.assertEqual(fixtures.auth_request(self.target(),'DELETE','admin/users/synthetic',allow_missing=True),{'already_absent':True})

    def test_missing_tolerance_does_not_hide_authorization_failure(self):
        with patch.object(fixtures,'urlopen',side_effect=HTTPError('http://localhost',401,'denied',{},None)):
            with self.assertRaisesRegex(RuntimeError,'401'):
                fixtures.auth_request(self.target(),'DELETE','admin/users/synthetic',allow_missing=True)

    def test_missing_tolerance_does_not_hide_create_failure(self):
        with patch.object(fixtures,'urlopen',side_effect=HTTPError('http://localhost',404,'missing',{},None)):
            with self.assertRaisesRegex(RuntimeError,'404'):
                fixtures.auth_request(self.target(),'POST','admin/users',{},allow_missing=True)

if __name__=='__main__':unittest.main()
