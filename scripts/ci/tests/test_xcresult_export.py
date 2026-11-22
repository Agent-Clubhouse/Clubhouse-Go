"""One fresh SDK details response serves both retry and inventory gates."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('export_verifier', ROOT / 'scripts/verify-xcresult.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
DETAILS = {'testNodes': [{'nodeType': 'UI test bundle', 'name': 'ClubhouseGoUITests', 'children': [
    {'nodeType': 'Test Suite', 'name': 'ExampleTests', 'children': [
        {'nodeType': 'Test Case', 'name': 'testOne()', 'result': 'Passed'}]}]}]}
PASS = {'result': 'Passed', 'passedTests': 1, 'failedTests': 0}


class FreshExportTests(unittest.TestCase):
    def call(self, output, summary=PASS, details=DETAILS, strict=()):
        def fetch(kind, path):
            value = summary if kind == 'summary' else details
            if isinstance(value, Exception):
                raise value
            return value
        with mock.patch.object(verify, 'xcresult', side_effect=fetch) as sdk, \
                mock.patch.dict('os.environ', {}, clear=True), redirect_stdout(io.StringIO()):
            verify.main('original.xcresult', 'lane', strict, output)
        self.assertEqual([c.args for c in sdk.call_args_list],
                         [('summary', 'original.xcresult'), ('tests', 'original.xcresult')])

    def test_exact_same_details_published_once_only_after_complete_serialization(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'tests.json'
            output.write_text('stale previous invocation')
            replace = verify.os.replace
            def publish(temporary, target):
                self.assertFalse(output.exists(), 'Stale output must disappear before SDK consumption')
                self.assertEqual(json.loads(Path(temporary).read_text()), DETAILS)
                return replace(temporary, target)
            with mock.patch.object(verify.os, 'replace', side_effect=publish) as atomic:
                self.call(output)
            self.assertEqual(atomic.call_count, 1)
            self.assertEqual(json.loads(output.read_text()), DETAILS)
            self.assertEqual(list(Path(directory).glob('*.tmp')), [])

    def test_red_test_verdict_still_exports_valid_details_for_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'tests.json'
            with self.assertRaises(SystemExit):
                self.call(output, summary={'result': 'Failed', 'passedTests': 1, 'failedTests': 1})
            self.assertEqual(json.loads(output.read_text()), DETAILS)

    def test_unreadable_summary_does_not_prevent_inventory_export_or_turn_green(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'tests.json'
            with self.assertRaises(SystemExit):
                self.call(output, summary=subprocess.CalledProcessError(9, ['fake SDK summary']))
            self.assertEqual(json.loads(output.read_text()), DETAILS)

    def test_empty_malformed_or_failed_details_leave_no_usable_or_stale_output(self):
        for details in ({}, [], {'testNodes': []}, {'testNodes': ['bad node']},
                        {'testNodes': [{'nodeType': 'Test Case'}]},
                        ValueError('malformed SDK JSON'), subprocess.CalledProcessError(9, ['fake SDK tests'])):
            with self.subTest(details=details), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'tests.json'
                output.write_text(json.dumps(DETAILS))
                with self.assertRaises(SystemExit):
                    self.call(output, details=details)
                self.assertFalse(output.exists())
                self.assertEqual(list(Path(directory).glob('*.tmp')), [])

    def test_strict_retry_gate_still_fails_with_export_available(self):
        details = json.loads(json.dumps(DETAILS))
        case = details['testNodes'][0]['children'][0]['children'][0]
        case['children'] = [{'nodeType': 'Repetition', 'result': r} for r in ['Failed', 'Passed']]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'tests.json'
            with self.assertRaises(SystemExit):
                self.call(output, details=details, strict=['ClubhouseGoUITests'])
            self.assertEqual(json.loads(output.read_text()), details)

    def test_standalone_callers_keep_optional_advisory_details_and_strict_behavior(self):
        self.call(None, details=ValueError('no advisory details'))
        with self.assertRaises(SystemExit):
            self.call(None, details=ValueError('no strict details'), strict=['ClubhouseGoTests'])


if __name__ == '__main__':
    unittest.main()
