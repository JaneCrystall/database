"""Role-creation harness must refuse non-owned targets before loading adapters."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
runtime_spec = importlib.util.spec_from_file_location('worker_boundary_runtime',HERE/'runtime.py')
runtime = importlib.util.module_from_spec(runtime_spec)
runtime_spec.loader.exec_module(runtime)
spec = importlib.util.spec_from_file_location('worker_role_boundary',HERE/'unstructure_role_boundary.py')
boundary = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules,{'runtime':runtime}):
    spec.loader.exec_module(boundary)


class WorkerRoleTargetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.target = dict(schema_version=1,run_id='a'*32,mode='local',project_ref=runtime.PROJECT_PREFIX+'a'*16,
                           project_id=runtime.PROJECT_PREFIX+'a'*16,session_dir=str(self.path),
                           api_url='http://127.0.0.1:12345',db_url='postgresql://postgres:synthetic@127.0.0.1:12346/postgres',
                           publishable_key='synthetic',service_role_key='synthetic')
        self.state = {**self.target,'owns_stack':True}
        self.info = [{'Config':{'Labels':{'com.supabase.cli.project':self.target['project_id'],'com.supabase.cli.workdir':str(self.path)}},'NetworkSettings':{'Ports':{'5432/tcp':[{'HostPort':'12346'}]}}}]
        self.addCleanup(patch.stopall)
        patch.object(boundary,'local_docker').start()
        self.command = patch.object(boundary,'command',side_effect=lambda _:json.dumps(self.info)).start()

    def check(self):
        runtime.private_json(self.path/'target.json',self.target)
        runtime.private_json(self.path/'session.json',self.state)
        return boundary.local_target(self.path/'target.json')

    def test_matching_owned_target(self):
        self.assertEqual(self.check()['run_id'],self.target['run_id'])

    def test_remote_host_rejected_before_docker(self):
        self.target['db_url']='postgresql://postgres:synthetic@foreign.invalid/postgres'
        with self.assertRaises(runtime.RuntimeErrorSafe):self.check()
        self.command.assert_not_called()

    def test_nonlocal_mode_rejected_even_after_generic_validation(self):
        self.target['mode']='preview'
        with patch.object(boundary,'validate_target'),self.assertRaisesRegex(runtime.RuntimeErrorSafe,'Only an owned'):
            self.check()
        self.command.assert_not_called()

    def test_other_loopback_database_rejected(self):
        self.target['db_url']='postgresql://postgres:synthetic@127.0.0.1:5432/postgres'
        with self.assertRaisesRegex(runtime.RuntimeErrorSafe,'port'):self.check()

    def test_container_labels_rejected(self):
        self.info[0]['Config']['Labels']['com.supabase.cli.workdir']='/other-session'
        with self.assertRaisesRegex(runtime.RuntimeErrorSafe,'Container ownership'):self.check()

    def test_mismatched_run_rejected(self):
        self.state['run_id']='b'*32
        with self.assertRaisesRegex(runtime.RuntimeErrorSafe,'Session ownership'):self.check()
        self.command.assert_not_called()

    def test_stopped_or_unowned_session_rejected(self):
        for update in ({'stopped':True},{'owns_stack':False}):
            with self.subTest(update=update):
                self.state.update(stopped=False,owns_stack=True)
                self.state.update(update)
                with self.assertRaisesRegex(runtime.RuntimeErrorSafe,'Inactive'):self.check()
        self.command.assert_not_called()
