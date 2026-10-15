"""Offline fail-closed checks for the full orchestration harness."""
import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
with patch.object(sys, 'path', [str(HERE), *sys.path]), patch.dict(sys.modules):
    # Direct-entry harness imports must not shadow tests/runtime as a package
    # during the repository-wide unittest discovery.
    import unstructure_worker_flow as flow
    import preview_api_boundary as preview_api


class WorkerFlowSafetyTests(unittest.TestCase):
    def preview(self):
        ref = 'abcdefghijklmnopqrst'
        receipt = {'verification_source':'supabase-management-mcp',
            'project_ref':ref, 'parent_project_ref':'qyyqlnwqwgvzxnccnbgm',
            'branch_name':'s9-synthetic', 'is_preview':True,
            'status':'ACTIVE_HEALTHY', 'is_default':False, 'persistent':False,
            'branch_id':'synthetic-branch', 'verified_at':datetime.now(timezone.utc).isoformat()}
        return {'schema_version':1, 'run_id':'a'*32, 'mode':'preview',
            'api_url':f'https://{ref}.supabase.co', 'db_url':f'postgresql://postgres:synthetic@db.{ref}.supabase.co/postgres',
            'publishable_key':'synthetic', 'service_role_key':'synthetic',
            'project_ref':ref, 'parent_project_ref':receipt['parent_project_ref'],
            'branch_name':receipt['branch_name'], 'verification_receipt':receipt}

    def test_preview_requires_exact_disposable_branch_before_source_import(self):
        target = self.preview()
        with patch.object(flow, 'load_private', return_value=target):
            self.assertEqual(flow.preview_target(Path('/synthetic'), target['project_ref']), target)
            for field in ('is_default', 'persistent'):
                with self.subTest(field=field):
                    target['verification_receipt'][field] = True
                    with self.assertRaises(RuntimeError):
                        flow.preview_target(Path('/synthetic'), target['project_ref'])
                    target['verification_receipt'][field] = False
            with self.assertRaises(RuntimeError):
                flow.preview_target(Path('/synthetic'), 'differenttargetxxxxx')
            target['parent_project_ref'] = 'otherparentxxxxxxxxx'
            target['verification_receipt']['parent_project_ref'] = target['parent_project_ref']
            with self.assertRaises(RuntimeError):
                flow.preview_target(Path('/synthetic'), target['project_ref'])

    def test_preview_acl_reopening_is_forbidden_before_source_import(self):
        with patch.object(flow, 'load_sources') as load:
            with self.assertRaises(RuntimeError):
                flow.run(Path('/invalid'), acl_upgrade=True, preview_ref='abcdefghijklmnopqrst')
            load.assert_not_called()

    def test_preview_http_rejects_target_before_network(self):
        with patch.object(preview_api, 'preview_target', side_effect=RuntimeError('refused')), patch.object(preview_api, 'urlopen') as network:
            with self.assertRaises(RuntimeError):
                preview_api.run(Path('/invalid'), 'abcdefghijklmnopqrst')
            network.assert_not_called()

    def test_target_rejected_before_source_import(self):
        with patch.object(flow, 'local_target', side_effect=RuntimeError('refused')), patch.object(flow, 'load_sources') as load:
            with self.assertRaises(RuntimeError):
                flow.run(Path('/invalid/target.json'))
            load.assert_not_called()

    def test_external_network_is_rejected(self):
        for address in [('192.168.1.142', 7300), ('example.com', 443), ('127.0.0.1', 9999)]:
            with self.subTest(address=address), self.assertRaises(RuntimeError):
                flow.check_address(address, {12345})
        flow.check_address(('127.0.0.1', 12345), {12345})

    def test_object_double_confines_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            obj = flow.LocalObjects(Path(temp))
            for key in ['../escape', 'processed/../../escape', '/etc/passwd']:
                with self.subTest(key=key), self.assertRaises(RuntimeError):
                    obj.path(key)

    def test_no_operator_configuration_loaded(self):
        source = (HERE / 'unstructure_worker_flow.py').read_text()
        self.assertNotIn('WorkerConfig.from_env(', source)
        self.assertNotIn('load_worker_env(', source)
