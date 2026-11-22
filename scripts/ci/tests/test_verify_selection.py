"""A planned UI selection must execute as planned, and the workflow must feed it immutable inputs."""
import importlib.util
from pathlib import Path
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("verify_selection", ROOT / "scripts/ci/verify_selection.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(textwrap.dedent(text))


class ExecutionVerificationTests(unittest.TestCase):
    """Every declared method of a selected class must report; a skip counts only behind a documented guard."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        write(self.root, "Annex/AnnexUITests/TerminalUITests.swift", """
            final class TerminalUITests: ReliableUITestCase {
                func testOne() {}
                func testLive() throws { try XCTSkipUnless(false, "live only") }
            }
            """)
        write(self.root, "Annex/AnnexTests/StoreTests.swift", "final class StoreTests: XCTestCase { func testStore() {} }\n")

    def tearDown(self):
        self.directory.cleanup()

    @staticmethod
    def record(cases):
        bundles = {}
        for (bundle, suite, method), result in cases.items():
            bundles.setdefault(bundle, {}).setdefault(suite, []).append(
                {"nodeType": "Test Case", "name": f"{method}()", "result": result})
        return {"testNodes": [{"nodeType": "Test Plan", "children": [
            {"nodeType": "UI test bundle" if b.endswith("UITests") else "Unit test bundle", "name": b, "children": [
                {"nodeType": "Test Suite", "name": s, "children": c} for s, c in suites.items()]} for b, suites in bundles.items()]}]}

    def check(self, selection, cases):
        return verify.problems(selection, self.record(cases), self.root)

    def test_all_declared_methods_with_a_guarded_skip_pass(self):
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testOne"): "Passed",
               ("ClubhouseGoUITests", "TerminalUITests", "testLive"): "Skipped",
               ("ClubhouseGoTests", "StoreTests", "testStore"): "Passed"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/TerminalUITests -only-testing:ClubhouseGoTests", ran), [])

    def test_a_missing_method_fails_even_when_another_case_in_the_class_ran(self):
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testLive"): "Skipped"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/TerminalUITests", ran),
                         ["ClubhouseGoUITests/TerminalUITests/testOne was selected but produced no result"])

    def test_an_unguarded_skip_is_not_execution(self):
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testOne"): "Skipped",
               ("ClubhouseGoUITests", "TerminalUITests", "testLive"): "Skipped"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/TerminalUITests", ran),
                         ["ClubhouseGoUITests/TerminalUITests/testOne was skipped without a documented skip guard"])

    def test_a_target_selection_needs_an_executed_case_and_a_passing_bundle_cannot_hide_it(self):
        only_skips = {("ClubhouseGoUITests", "TerminalUITests", "testLive"): "Skipped",
                      ("ClubhouseGoTests", "StoreTests", "testStore"): "Passed"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests -skip-testing:ClubhouseGoUITests/X", only_skips),
                         ["ClubhouseGoUITests was selected but executed no test case",
                          "ClubhouseGoUITests/TerminalUITests/testOne was selected but produced no result"])

    def test_catchall_success_cannot_hide_missing_method_and_respects_exact_exclusions(self):
        write(self.root, "Annex/AnnexUITests/OtherUITests.swift", """
            final class OtherUITests: ReliableUITestCase {
                func testTwo() {}
                func testThree() {}
            }
        """)
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testOne"): "Passed",
               ("ClubhouseGoUITests", "TerminalUITests", "testLive"): "Skipped",
               ("ClubhouseGoUITests", "OtherUITests", "testTwo"): "Passed"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests", ran),
                         ["ClubhouseGoUITests/OtherUITests/testThree was selected but produced no result"])
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests "
                                    "-skip-testing:ClubhouseGoUITests/OtherUITests/testThree", ran), [])
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests "
                                    "-skip-testing:ClubhouseGoUITests/OtherUITests", ran), [])

    def test_method_selectors_and_unknown_classes(self):
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testOne"): "Passed"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/TerminalUITests/testOne", ran), [])
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/GoneUITests", ran),
                         ["ClubhouseGoUITests/GoneUITests was selected but its source class was not found"])


    def test_a_setup_guard_covers_every_method_and_string_braces_do_not_leak_guards(self):
        write(self.root, "Annex/AnnexUITests/LiveUITests.swift", """
            final class LiveUITests: ReliableUITestCase {
                override func setUpWithError() throws { try XCTSkipUnless(false, "live only") }
                func testA() {}
                func testB() {}
            }
            """)
        write(self.root, "Annex/AnnexUITests/BraceUITests.swift", """
            final class BraceUITests: ReliableUITestCase {
                func testOpen() { let s = "{" // }
                }
                func testLive() throws { try XCTSkipUnless(false, "live only") }
            }
            """)
        skipped = {("ClubhouseGoUITests", "LiveUITests", m): "Skipped" for m in ("testA", "testB")}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/LiveUITests", skipped), [])
        both = {("ClubhouseGoUITests", "BraceUITests", m): "Skipped" for m in ("testOpen", "testLive")}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/BraceUITests", both),
                         ["ClubhouseGoUITests/BraceUITests/testOpen was skipped without a documented skip guard"])


class SelectionWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def test_changes_come_from_one_immutable_local_diff(self):
        self.assertIn("git diff --name-status -M HEAD^1 HEAD > changed-files.txt", self.workflow)
        self.assertIn("python3 scripts/ci/ui_scope.py changed-files.txt --diff changes.diff --manifest impact-manifest.json", self.workflow)
        self.assertIn("fetch-depth: 2", self.workflow)
        self.assertNotIn("/files", self.workflow, "No paginated, racing PR files API")

    def test_planned_selection_is_verified_after_running(self):
        self.assertIn('python3 scripts/ci/verify_selection.py "${{ matrix.selection }}" TestResults/tests.json', self.workflow)

    def test_full_runs_daily_by_dispatch_and_by_label_without_write_access(self):
        self.assertIn("schedule:", self.workflow)
        self.assertIn("workflow_dispatch:", self.workflow)
        self.assertIn("grep -qx 'ci:full'", self.workflow)
        self.assertNotIn("labeled", self.workflow.split("jobs:")[0])
        self.assertNotIn("actions: write", self.workflow)
        self.assertFalse((ROOT / ".github/workflows/ci-full-label.yml").exists())

    def test_the_schedule_has_its_own_concurrency_group_and_a_failed_label_lookup_fails(self):
        self.assertIn("github.event_name == 'schedule' && '-schedule'", self.workflow)
        self.assertIn('LABELS=$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels"', self.workflow)


if __name__ == "__main__":
    unittest.main()
