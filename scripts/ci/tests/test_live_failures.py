"""The early signal is advisory, escaped, immediate and preserves upstream failure."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/ci/report_test_failures.py'
spec = importlib.util.spec_from_file_location('live_failures', SCRIPT)
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class LiveFailureTests(unittest.TestCase):
    def reporter(self):
        self.now = 0
        self.output, self.events = io.StringIO(), io.StringIO()
        return live.Reporter(self.output, self.events, 'UI lane', clock=lambda: self.now)

    def test_failure_is_signalled_before_terminal_result_and_retry_does_not_erase_it(self):
        reporter = self.reporter()
        self.now = 720  # Delayed item start is NOT a claim of <10m workflow feedback.
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' started (Iteration 1 of 3).\n")
        self.now = 732
        original = '/repo/Annex/AnnexUITests/MenuTests.swift:74: error: -[ClubhouseGoUITests.MenuTests testOpen] : XCTAssertEqual failed: ("Permissions") is not equal to ("Auto-accept edits")\n'
        reporter.consume(original)
        self.assertIn(original, self.output.getvalue())
        self.assertEqual(self.output.getvalue().count('::warning '), 1)
        event = json.loads(self.events.getvalue())
        self.assertEqual(event['stream_elapsed_seconds'], 732)
        self.assertEqual(event['item_elapsed_seconds'], 12)
        self.assertEqual(event['attempt'], 1)
        self.assertEqual(event['file'], 'Annex/AnnexUITests/MenuTests.swift')
        self.assertFalse(event['final_verdict'])
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' failed (12 seconds).\n")
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' started (Iteration 2 of 3).\n")
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' passed (10 seconds).\n")
        self.assertEqual(len(self.events.getvalue().splitlines()), 1)

    def test_saved_hosted_first_failure_then_passing_retry(self):
        import datetime
        reporter = self.reporter()
        fixture = ROOT / 'scripts/ci/tests/fixtures/first-failure-then-pass.log'
        lines = fixture.read_text().splitlines(keepends=True)
        def timestamp(line):
            return datetime.datetime.fromisoformat(line.split()[0][:26] + '+00:00')
        origin = timestamp(lines[0])
        for line in lines:
            self.now = (timestamp(line) - origin).total_seconds()
            reporter.consume(line)
        events = [json.loads(line) for line in self.events.getvalue().splitlines()]
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual(event['item'], 'ClubhouseGoUITests.CompanionImageAttachmentUITests/testPickRemoveAndSendImages')
        self.assertEqual(event['line'], 16)
        self.assertEqual(event['attempt'], 1)
        self.assertEqual(event['item_elapsed_seconds'], 160.835)
        self.assertIn('The preview desktop advertises attachments', event['assertion'])
        self.assertIn('passed (97.944 seconds)', self.output.getvalue())
        self.assertEqual(self.output.getvalue().count('::warning '), 1)

    def test_swift_testing_issue_and_absent_start_are_not_given_invented_timing(self):
        reporter = self.reporter()
        reporter.consume('✘ Test refusedNewChat() recorded an issue at RecoveryTests.swift:120:9: Expectation failed: fresh != old\n')
        event = json.loads(self.events.getvalue())
        self.assertEqual(event['item'], 'refusedNewChat()')
        self.assertIsNone(event['item_elapsed_seconds'])
        self.assertEqual(event['line'], 120)
        self.assertEqual(event['assertion'], 'Expectation failed: fresh != old')

    def test_untrusted_command_properties_and_message_are_escaped(self):
        reporter = self.reporter()
        reporter.label = 'lane%,::error\r\ninjected'
        reporter.failure('suite/test', 'XCTAssertTrue %\r\n::error::untrusted', 'Tests/a,b:c%.swift', 5)
        annotation = self.output.getvalue()
        self.assertEqual(len(annotation.splitlines()), 1)
        self.assertIn('file=Tests/a%2Cb%3Ac%25.swift', annotation)
        self.assertIn('XCTAssertTrue %25%0D%0A::error::untrusted', annotation)

    def test_launch_or_timeout_failure_without_assertion_still_names_the_item(self):
        reporter = self.reporter()
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' started.\n")
        reporter.consume("Test Case '-[ClubhouseGoUITests.MenuTests testOpen]' failed (120 seconds).\n")
        self.assertEqual(json.loads(self.events.getvalue())['item'], 'ClubhouseGoUITests.MenuTests/testOpen')

    def test_nonfailure_output_is_identical_and_real_pipefail_status_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            event = str(Path(directory) / 'events.jsonl')
            # This is a shell/stream test, not xcodebuild, Swift or a simulator.
            result = subprocess.run(['bash', '-o', 'pipefail', '-c',
                                     'printf "ordinary output\\n"; exit 17'], capture_output=True)
            filtered = subprocess.run([sys.executable, str(SCRIPT), '--label', 'lane', '--events', event],
                                      input=result.stdout, capture_output=True)
            self.assertEqual(filtered.returncode, 0)
            self.assertEqual(filtered.stdout, result.stdout)
            pipeline = subprocess.run(['bash', '-o', 'pipefail', '-c',
                                      '(printf "ordinary output\\n"; exit 17) | "$1" "$2" --label lane --events "$3"',
                                      '_', sys.executable, str(SCRIPT), event], capture_output=True)
            self.assertEqual(pipeline.returncode, 17)
            self.assertEqual(pipeline.stdout, b'ordinary output\n')


if __name__ == '__main__':
    unittest.main()
