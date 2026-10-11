"""Exercise traceability guards against isolated local Git repositories."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('trace', Path(__file__).with_name('git-trace.py'))
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class TraceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo, self.remote = base / 'work', base / 'remote.git'
        subprocess.run(['git', 'init', '--bare', str(self.remote)], check=True, capture_output=True)
        subprocess.run(['git', 'init', '-b', 'personal/customization', str(self.repo)], check=True, capture_output=True)
        self.run_git('config', 'user.name', 'Synthetic Test')
        self.run_git('config', 'user.email', 'synthetic@example.invalid')
        self.run_git('remote', 'add', 'origin', str(self.remote))
        (self.repo / 'note.txt').write_text('Synthetic data only', encoding='utf-8')
        self.run_git('add', 'note.txt')
        self.run_git('commit', '-m', 'synthetic baseline')
        self.root_patch = patch.object(trace, 'ROOT', self.repo)
        self.origin_patch = patch.object(trace, 'EXPECTED_ORIGIN', str(self.remote))
        self.root_patch.start()
        self.origin_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.origin_patch.stop)

    def run_git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True)

    def test_upload_and_exact_remote_proof(self):
        trace.push()
        trace.verify()
        state = json.loads((self.repo / '.git/count-tools-push-state.json').read_text())
        self.assertTrue(state['verified'])
        self.assertEqual(state['commit'], self.run_git('rev-parse', 'HEAD').stdout.decode().strip())

    def test_failed_push_preserves_local_commit(self):
        missing = str(self.remote.parent / 'missing.git')
        self.run_git('remote', 'set-url', 'origin', missing)
        before = self.run_git('rev-parse', 'HEAD').stdout
        with patch.object(trace, 'EXPECTED_ORIGIN', missing):
            with self.assertRaisesRegex(RuntimeError, 'NOT uploaded'):
                trace.push()
        self.assertEqual(before, self.run_git('rev-parse', 'HEAD').stdout)
        self.assertFalse(json.loads((self.repo / '.git/count-tools-push-state.json').read_text())['verified'])

    def test_other_branch_not_pushed(self):
        self.run_git('switch', '-c', 'unrelated')
        with self.assertRaisesRegex(ValueError, 'personal/customization'):
            trace.push()
        self.assertFalse((self.repo / '.git/count-tools-push-state.json').exists())

    def test_other_origin_not_pushed(self):
        self.run_git('remote', 'set-url', 'origin', str(self.remote.parent / 'unapproved.git'))
        with self.assertRaisesRegex(ValueError, 'approved personal fork'):
            trace.push()

    def test_force_staged_database_rejected(self):
        (self.repo / 'real.db').write_bytes(b'synthetic prohibited artifact')
        self.run_git('add', 'real.db')
        with self.assertRaisesRegex(ValueError, 'Personal data/signing artifact is staged'):
            trace.staged_check()


if __name__ == '__main__':
    unittest.main(verbosity=2)
