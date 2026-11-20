"""Check the executable iPad selectors and gates, independently of UI class shards."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
EXPECTED_UI = {
    "ClubhouseGoUITests/FeedbackTriggersUITests/testClearQueuedFeedbackIsReachableFromEnrollmentSheetAndSettings",
    "ClubhouseGoUITests/FeedbackTriggersUITests/testHeldReportsRequireConfirmationAndCanBeClearedWhileUnenrolled",
    "ClubhouseGoUITests/CompanionAgentTreeUITests/testProjectUsesSameTreeAndCrossProjectCaption",
}


class IPadPartitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        cls.job = cls.workflow.split("  ipad-tests:\n", 1)[1].split("  # One check", 1)[0]
        match = re.search(r"matrix: \$\{\{ fromJSON\('(.*?)'\) \}\}", cls.job)
        if match is None:
            raise AssertionError("iPad requires separate complete hosted and UI jobs")
        cls.lanes = json.loads(match[1])["include"]

    def test_complete_hosted_and_same_three_ui_selectors_run_once(self):
        selectors = [lane["tests"].split() for lane in self.lanes]
        self.assertEqual(len(selectors), 2)
        self.assertIn(["-only-testing:ClubhouseGoTests"], selectors)
        ui = next(s for s in selectors if s != ["-only-testing:ClubhouseGoTests"])
        self.assertEqual(len(ui), len(EXPECTED_UI))
        self.assertEqual(set(ui), {"-only-testing:" + s for s in EXPECTED_UI})
        self.assertEqual(len({s for lane in selectors for s in lane}), 4)
        for identifier in EXPECTED_UI:
            _, name, method = identifier.split("/")
            source = (ROOT / "Annex/AnnexUITests" / (name + ".swift")).read_text()
            self.assertRegex(source, rf"\bfunc {method}\(\)")
        self.assertIn('TEST_SELECTORS: ${{ matrix.tests }}', self.job)
        self.assertIn('read -ra selectors <<< "$TEST_SELECTORS"', self.job)
        self.assertEqual(self.job.count('"${selectors[@]}"'), 1)

    def test_serial_jobs_retain_deadlines_and_strict_results(self):
        self.assertIn("timeout-minutes: 25\n", self.job)
        self.assertIn("fail-fast: false\n", self.job)
        self.assertIn("max-parallel: 1\n", self.job)
        self.assertIn("-parallel-testing-enabled NO", self.job)
        self.assertIn("-default-test-execution-time-allowance 120", self.job)
        self.assertNotIn("-retry-tests-on-failure", self.job)
        self.assertIn("--no-retries-in ClubhouseGoTests --no-retries-in ClubhouseGoUITests", self.job)
        self.assertIn("name: test-results-ipad-${{ strategy.job-index }}", self.job)
        result = self.workflow.split("  ci-result:\n", 1)[1]
        needs = re.search(r"needs: \[(.*?)\]", result)[1].split(", ")
        self.assertIn("ipad-tests", needs)
        self.assertIn("if: always()", result)
        self.assertIn("not in ('success', 'skipped')", result)


if __name__ == "__main__":
    unittest.main()
