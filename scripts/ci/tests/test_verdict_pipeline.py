"""Run the real workflow verifier tails against fake tools, never an SDK."""
from pathlib import Path
import os
import json
import shutil
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
                        "python3": 'echo "$1" >> "$CALLS"; case "$1" in *verify-xcresult.py) shift; while [ "$1" != "--tests-json-output" ]; do shift; done; shift; rm -f "$1"; echo export >> "$CALLS"; if [ "$EXPORT" = 0 ]; then echo "{}" > "$1"; fi; exit "$VERDICT";; *) exit "$INVENTORY";; esac',
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


class RealVerifierTailTests(unittest.TestCase):
    def test_single_sdk_export_and_real_gates_on_both_workflow_tails(self):
        for ipad in (False, True):
            for scenario in ('passed', 'test-red', 'missing-method', 'empty', 'malformed', 'sdk-error', 'summary-error', 'hosted-retry'):
                with self.subTest(ipad=ipad, scenario=scenario), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    for relative in ('scripts/verify-xcresult.py', 'scripts/ci/verify_selection.py'):
                        target = root / relative
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(ROOT / relative, target)
                    source = root / 'Annex/AnnexUITests/Example.swift'
                    source.parent.mkdir(parents=True)
                    source.write_text('final class Example: ReliableUITestCase { func testOne() {} }')
                    ui = {'nodeType': 'Test Case', 'name': 'testOne()', 'result': 'Passed'}
                    hosted = {'nodeType': 'Test Case', 'name': 'testHost()', 'result': 'Passed'}
                    if scenario == 'hosted-retry':
                        hosted['children'] = [{'nodeType': 'Repetition', 'result': r} for r in ('Failed', 'Passed')]
                    details = {'testNodes': [
                        {'nodeType': 'UI test bundle', 'name': 'ClubhouseGoUITests', 'children': [
                            {'nodeType': 'Test Suite', 'name': 'Example', 'children': [] if scenario == 'missing-method' else [ui]}]},
                        {'nodeType': 'Unit test bundle', 'name': 'ClubhouseGoTests', 'children': [
                            {'nodeType': 'Test Suite', 'name': 'Host', 'children': [hosted]}]}]}
                    (root / 'sdk-summary.json').write_text(json.dumps({'result': 'Failed' if scenario == 'test-red' else 'Passed', 'passedTests': 2, 'failedTests': int(scenario == 'test-red')}))
                    (root / 'sdk-details.json').write_text('not JSON' if scenario == 'malformed' else json.dumps({} if scenario == 'empty' else details))
                    (root / 'TestResults').mkdir()
                    output = root / 'TestResults' / ('ipad-tests.json' if ipad else 'tests.json')
                    output.write_text('stale previous response')
                    sdk = root / 'xcrun'
                    sdk.write_text('#!/bin/bash\necho "$4" >> "$CALLS"\n'
                                   'if [ "$4" = summary ]; then [ "$SCENARIO" = summary-error ] && exit 9; cat "$SDK_SUMMARY"; '
                                   'else [ "$SCENARIO" = sdk-error ] && exit 9; cat "$SDK_DETAILS"; fi\n')
                    sdk.chmod(0o755)
                    env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], CALLS=str(root / 'calls'),
                               SDK_SUMMARY=str(root / 'sdk-summary.json'), SDK_DETAILS=str(root / 'sdk-details.json'),
                               SCENARIO=scenario, TEST_LANE='test lane', TEST_SELECTION='-only-testing:ClubhouseGoUITests/Example',
                               GITHUB_STEP_SUMMARY=str(root / 'summary.md'))
                    command = 'pipeline_status=(65 0 0)\n' + workflow_tail(ipad)
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command], cwd=root, env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, scenario == 'passed', result.stdout + result.stderr)
                    self.assertEqual((root / 'calls').read_text().splitlines(), ['summary', 'tests'])
                    usable = scenario not in ('empty', 'malformed', 'sdk-error')
                    self.assertEqual(output.exists(), usable)
                    if usable:
                        self.assertEqual(json.loads(output.read_text()), details)
                    if scenario == 'missing-method':
                        self.assertIn('testOne was selected but produced no result', result.stdout)
                    if scenario == 'hosted-retry':
                        self.assertIn('must pass without a retry', result.stderr)


if __name__ == '__main__':
    unittest.main()
