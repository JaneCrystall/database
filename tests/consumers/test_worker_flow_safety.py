"""Offline fail-closed checks for the full orchestration harness."""
import importlib.util
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


class WorkerFlowSafetyTests(unittest.TestCase):
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
