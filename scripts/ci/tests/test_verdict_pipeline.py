"""Run the real workflow verifier tails against fake tools, never an SDK."""
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]


def workflow_tail(ipad):
    text = (ROOT / '.github/workflows/ci.yml').read_text()
    section = text.split('      - name: ' + ('Run iPad tests without retries' if ipad else 'Run tests') + '\n', 1)[1]
    section = section.split('\n      - name:', 1)[0]
    # Test the emitted shell itself, after the deliberately non-authoritative
    # xcodebuild pipeline, with matrix expressions resolved as GitHub would.
    tail = section[section.index('          result_status=0'):]
    tail = textwrap.dedent(tail.split('\n\n      #', 1)[0])
    tail = tail.replace("${{ matrix.unit && '--no-retries-in ClubhouseGoTests' || '' }}", '--no-retries-in ClubhouseGoTests')
    return tail.replace('${{ matrix.selection }}', '-only-testing:ClubhouseGoUITests/Example')


class VerdictPipelineTests(unittest.TestCase):
    def test_inventory_runs_after_failed_verdict_and_neither_failure_is_waived(self):
        for ipad in (False, True):
            for verdict, export, inventory, reporter in ((0, 0, 0, 0), (7, 0, 0, 0), (0, 0, 8, 0), (7, 0, 8, 0), (0, 9, 0, 0), (0, 0, 0, 6)):
                with self.subTest(ipad=ipad, verdict=verdict, export=export, inventory=inventory), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / 'TestResults').mkdir()
                    for name, body in {
                        'python3': 'echo "$1" >> "$CALLS"; case "$1" in *verify-xcresult.py) exit "$VERDICT";; *) exit "$INVENTORY";; esac',
                        'xcrun': 'echo export >> "$CALLS"; echo "{}"; exit "$EXPORT"',
                    }.items():
                        script = root / name
                        script.write_text('#!/bin/bash\n' + body + '\n')
                        script.chmod(0o755)
                    env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], CALLS=str(root / 'calls'),
                               VERDICT=str(verdict), EXPORT=str(export), INVENTORY=str(inventory),
                               TEST_LANE='test lane', TEST_SELECTION='-only-testing:ClubhouseGoUITests/Example')
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', f'pipeline_status=(65 0 {reporter})\n' + workflow_tail(ipad)],
                                            cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, not (verdict or export or inventory or reporter), result.stderr)
                    calls = (root / 'calls').read_text().splitlines()
                    self.assertIn('scripts/verify-xcresult.py', calls)
                    self.assertIn('export', calls)
                    self.assertEqual('scripts/ci/verify_selection.py' in calls, export == 0)


if __name__ == '__main__':
    unittest.main()
