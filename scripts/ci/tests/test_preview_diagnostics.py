"""Optional diagnostics retain partial bytes and never decide the test verdict."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('preview_diagnostics', ROOT/'scripts/ci/collect_preview_diagnostics.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class PreviewDiagnosticsControls(unittest.TestCase):
    def collect(self, run):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'TestResults/chat-follow.log'
            ticks = iter([10.0, 30.25])
            status = collector.collect('owned-device', path, run=run, clock=lambda: next(ticks))
            return status, path.read_bytes(), json.loads(path.with_suffix('.status.json').read_text())

    def test_completed_output_and_original_command_are_preserved(self):
        def run(command, **kwargs):
            self.assertEqual(command, ['xcrun', 'simctl', 'spawn', 'owned-device', 'log', 'show',
                                      '--last', '1h', '--style', 'compact', '--predicate', collector.PREDICATE])
            self.assertEqual(kwargs['timeout'], 20)
            self.assertFalse(kwargs['check'])
            self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
            kwargs['stdout'].write(b'complete diagnostic bytes\n')
            return subprocess.CompletedProcess(command, 0)
        status, raw, receipt = self.collect(run)
        self.assertEqual(status, 0)
        self.assertEqual(raw, b'complete diagnostic bytes\n')
        self.assertTrue(receipt['complete_log'])
        self.assertFalse(receipt['native_verdict_changed'])

    def test_timeout_keeps_partial_output_and_marks_it_incomplete(self):
        def run(command, **kwargs):
            kwargs['stdout'].write(b'partial before timeout\n')
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
        status, raw, receipt = self.collect(run)
        self.assertEqual(status, 124)
        self.assertEqual(raw, b'partial before timeout\n')
        self.assertFalse(receipt['complete_log'])
        self.assertEqual(receipt['output_bytes'], len(raw))
        self.assertIn('timeout', receipt['reason'])

    def test_failed_or_unavailable_clients_cannot_claim_complete_log(self):
        for code in [7, -9]:
            status, _, receipt = self.collect(lambda command, **kwargs: subprocess.CompletedProcess(command, code))
            self.assertNotEqual(status, 0)
            self.assertEqual(receipt['client_exit'], code)
            self.assertFalse(receipt['complete_log'])
        def missing(command, **kwargs):
            raise FileNotFoundError('missing client')
        status, raw, receipt = self.collect(missing)
        self.assertEqual(status, 127)
        self.assertEqual(raw, b'')
        self.assertFalse(receipt['complete_log'])

    def test_real_owned_client_timeout_retains_already_written_bytes(self):
        def real_client(command, **kwargs):
            return subprocess.run([sys.executable, '-u', '-c',
                                   'import time; print("owned client partial", flush=True); time.sleep(30)'], **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'partial.log'
            self.assertEqual(collector.collect('owned-device', path, seconds=0.4, run=real_client), 124)
            self.assertEqual(path.read_bytes(), b'owned client partial\n')
            self.assertFalse(json.loads(path.with_suffix('.status.json').read_text())['complete_log'])

    def test_required_verdict_and_always_upload_stay_independent(self):
        workflow = (ROOT/'.github/workflows/ci.yml').read_text()
        ui = workflow.split('\n  ui-tests:', 1)[1].split('\n  ipad-tests:', 1)[0]
        diagnostics = ui.split('      - name: Collect preview follow diagnostics', 1)[1].split('      - name: Upload test results', 1)[0]
        self.assertIn("if: ${{ failure() && env.SIMULATOR_UDID != '' }}", diagnostics)
        self.assertIn('continue-on-error: true', diagnostics)
        self.assertIn('timeout-minutes: 1', diagnostics)
        self.assertIn('collect_preview_diagnostics.py', diagnostics)
        self.assertIn('exit "$result_status"', ui.split('Collect preview follow diagnostics')[0])
        upload = ui.split('      - name: Upload test results', 1)[1]
        self.assertIn('if: always()', upload)
        self.assertIn('            TestResults', upload)
        self.assertIn('            xcodebuild-*.log', upload)


if __name__ == '__main__':
    unittest.main()
