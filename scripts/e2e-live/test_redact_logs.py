"""Privacy regression for the logs uploaded by the live E2E job."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


class RedactLogsTests(unittest.TestCase):
    def test_new_annex_evidence_and_phone_logs_scrub_current_and_previous_credentials(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        (root / 'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root / 'build') as folder:
            fixture, output = pathlib.Path(folder) / 'fixture', pathlib.Path(folder) / 'output'
            fixture.mkdir(mode=0o700)
            output.mkdir()
            for name, data in [('invitation.json', {'pin': 'PIN-SENTINEL'}),
                               ('mcp-agent.json', {'CLUBHOUSE_HOOK_NONCE': 'NONCE-CURRENT'}),
                               ('mcp-agent-history.json', {'CLUBHOUSE_HOOK_NONCE': 'NONCE-PREVIOUS'})]:
                (fixture / name).write_text(json.dumps(data))
                (fixture / name).chmod(0o600)
            secret_text = 'PIN-SENTINEL NONCE-CURRENT NONCE-PREVIOUS'
            evidence = [{'at': '2026-11-01T20:00:00.000Z', 'event': secret_text, 'durationMs': 123.4}]
            for name in ['desktop-annex.json', 'dispatcher-wire.json']:
                (fixture / name).write_text(json.dumps(evidence))
            (output / 'xcodebuild-test.log').write_text('[live-connect] ' + secret_text)
            subprocess.run([sys.executable, str(root / 'scripts/e2e-live/redact-logs.py'), str(fixture), str(output)], check=True)
            for name in ['desktop-annex.json', 'dispatcher-wire.json', 'xcodebuild-test.log']:
                text = (output / name).read_text()
                for secret in ['PIN-SENTINEL', 'NONCE-CURRENT', 'NONCE-PREVIOUS']:
                    self.assertNotIn(secret, text)
                self.assertIn('<redacted>', text)
            self.assertEqual(json.loads((output / 'desktop-annex.json').read_text())[0]['durationMs'], 123.4)


if __name__ == '__main__':
    unittest.main()
