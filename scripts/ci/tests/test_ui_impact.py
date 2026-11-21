"""Narrowing must stay within verified ownership; everything uncertain runs every lane.

Includes the counterexamples from review 71e74130: dependency chains and negated launch flags in product code, a
method-level or inconsistent matrix, a requested class without an owner, hosted and iPad-run classes, and a planned
selection that never executes.
"""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/ci/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


impact = load("ui_impact")
verify = load("verify_selection")
WHOLE_CLASS = {"include": [
    {"name": "UI (search)", "selection": "-only-testing:ClubhouseGoUITests/SearchUITests", "unit": False},
    {"name": "UI (unit)", "selection": "-only-testing:ClubhouseGoUITests/TerminalUITests -only-testing:ClubhouseGoTests", "unit": True},
    {"name": "UI (other)", "selection": "-only-testing:ClubhouseGoUITests -skip-testing:ClubhouseGoUITests/SearchUITests "
                                       "-skip-testing:ClubhouseGoUITests/TerminalUITests", "unit": False},
]}


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(textwrap.dedent(text))


class Fixture:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory()
        root = self.root = Path(self.directory.name)
        (root / "scripts/ci").mkdir(parents=True)
        (root / "scripts/ci/changes.py").write_text((ROOT / "scripts/ci/changes.py").read_text())
        write(root, ".github/workflows/ci.yml", """
            jobs:
              ipad-tests:
                steps:
                  - run: xcodebuild -only-testing:ClubhouseGoTests -only-testing:ClubhouseGoUITests/FeedbackTriggersUITests/testOne
              ci-result:
                steps: []
            """)
        write(root, "Annex/Annex/Companion/Views/SearchScreen.swift", "struct SearchScreen {}\n")
        write(root, "Annex/AnnexUITests/UITestSupport.swift", "class ReliableUITestCase: XCTestCase {}\n")
        for cls in ("SearchUITests", "TerminalUITests", "FeedbackTriggersUITests", "NewUITests"):
            write(root, f"Annex/AnnexUITests/{cls}.swift",
                  f"final class {cls}: ReliableUITestCase {{\n    func testOne() {{}}\n}}\n")
        write(root, "Annex/AnnexUITests/MixedUITests.swift",
              "final class MixedUITests: ReliableUITestCase {\n    func testOne() {}\n}\nextension ReliableUITestCase { func helper() {} }\n")
        write(root, "Annex/AnnexTests/StoreTests.swift", "final class StoreTests: XCTestCase { func testStore() {} }\n")
        self.matrix = json.loads(json.dumps(WHOLE_CLASS))

    def run(self, changed, matrix=None):
        (self.root / "changed.txt").write_text(changed)
        out, err = io.StringIO(), io.StringIO()
        impact.main([str(self.root / "changed.txt")], stdin=io.StringIO("ui-shards=" + json.dumps(matrix or self.matrix)),
                    stdout=out, stderr=err, root=self.root)
        result = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        result["ui-shards"] = json.loads(result["ui-shards"])
        result["summary"] = err.getvalue()
        return result


def selections(result):
    return [entry["selection"] for entry in result["ui-shards"]["include"]]


class OwnershipSelectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()

    def tearDown(self):
        self.fixture.directory.cleanup()

    def assertFull(self, result, matrix=None):
        self.assertEqual(result["ui-shards"], matrix or self.fixture.matrix)
        self.assertEqual([result[k] for k in ("ui", "ipad", "release", "unit")], ["true"] * 4, result["summary"])

    def test_a_single_ui_class_file_runs_exactly_that_class(self):
        result = self.fixture.run("M\tAnnex/AnnexUITests/TerminalUITests.swift\n")
        self.assertEqual(selections(result), ["-only-testing:ClubhouseGoUITests/TerminalUITests"])
        self.assertEqual((result["ui"], result["ipad"], result["release"], result["unit"]), ("true", "false", "false", "false"))

    def test_a_new_class_runs_from_the_catch_all(self):
        result = self.fixture.run("A\tAnnex/AnnexUITests/NewUITests.swift\n")
        self.assertEqual(selections(result), ["-only-testing:ClubhouseGoUITests/NewUITests"])

    def test_a_class_the_ipad_job_runs_also_runs_the_ipad_lane(self):
        self.assertEqual(self.fixture.run("M\tAnnex/AnnexUITests/FeedbackTriggersUITests.swift\n")["ipad"], "true")

    def test_hosted_tests_run_the_bundle_in_the_unit_shard_and_on_ipad(self):
        result = self.fixture.run("M\tAnnex/AnnexTests/StoreTests.swift\n")
        self.assertEqual(selections(result), ["-only-testing:ClubhouseGoTests"])
        self.assertEqual((result["unit"], result["ipad"], result["release"]), ("true", "true", "false"))

    def test_every_product_change_runs_everything(self):
        # Review 71e74130: dependency chains and negated launch flags make product impact unbounded here.
        self.assertFull(self.fixture.run("M\tAnnex/Annex/Companion/Views/SearchScreen.swift\n"))
        self.assertFull(self.fixture.run("M\tAnnex/Annex/Companion/Adapters/CompanionPreviewService.swift\n"))
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/TerminalUITests.swift\nM\tAnnex/Annex/Transport/AnnexWire.swift\n"))

    def test_shared_mixed_deleted_and_renamed_test_files_run_everything(self):
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/UITestSupport.swift\n"))
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/MixedUITests.swift\n"))
        self.assertFull(self.fixture.run("D\tAnnex/AnnexUITests/GoneUITests.swift\n"))
        self.assertFull(self.fixture.run("R100\tAnnex/AnnexUITests/OldUITests.swift\tAnnex/AnnexUITests/TerminalUITests.swift\n"))
        self.assertFull(self.fixture.run("R090\tAnnex/AnnexTests/Old.swift\tAnnex/AnnexTests/StoreTests.swift\n"))

    def test_unsupported_matrix_topologies_run_everything(self):
        by_method = json.loads(json.dumps(WHOLE_CLASS))
        by_method["include"][0]["selection"] = "-only-testing:ClubhouseGoUITests/SearchUITests/testOne"
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/TerminalUITests.swift\n", by_method), by_method)
        drifted = json.loads(json.dumps(WHOLE_CLASS))
        drifted["include"][2]["selection"] = "-only-testing:ClubhouseGoUITests -skip-testing:ClubhouseGoUITests/SearchUITests"
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/TerminalUITests.swift\n", drifted), drifted)
        no_unit = json.loads(json.dumps(WHOLE_CLASS))
        no_unit["include"][1]["unit"] = False
        no_unit["include"][1]["selection"] = "-only-testing:ClubhouseGoUITests/TerminalUITests"
        self.assertFull(self.fixture.run("M\tAnnex/AnnexTests/StoreTests.swift\n", no_unit), no_unit)

    def test_project_workflow_and_script_changes_run_everything(self):
        self.assertFull(self.fixture.run("M\tAnnex/Annex.xcodeproj/project.pbxproj\n"))
        self.assertFull(self.fixture.run("M\tscripts/ci/ui_shards.py\n"))
        self.assertFull(self.fixture.run("M\t.github/workflows/ci.yml\n"))

    def test_docs_and_package_changes_need_no_app_lanes_and_keep_a_valid_matrix(self):
        result = self.fixture.run("M\tdocs/testing.md\nM\tTests/X/YTests.swift\n")
        self.assertEqual(result["ui"], "false")
        self.assertEqual(len(result["ui-shards"]["include"]), 1, "GitHub rejects an empty matrix even for a skipped job")

    def test_status_parsing(self):
        self.assertEqual(impact.parse_changes("R087\told.swift\tnew.swift\nD\tgone.swift\nA\tnew2.swift\nplain.swift\n"),
                         [("renamed", "new.swift", "old.swift"), ("removed", "gone.swift", None),
                          ("added", "new2.swift", None), ("modified", "plain.swift", None)])


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
                         ["ClubhouseGoUITests was selected but executed no test case"])

    def test_method_selectors_and_unknown_classes(self):
        ran = {("ClubhouseGoUITests", "TerminalUITests", "testOne"): "Passed"}
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/TerminalUITests/testOne", ran), [])
        self.assertEqual(self.check("-only-testing:ClubhouseGoUITests/GoneUITests", ran),
                         ["ClubhouseGoUITests/GoneUITests was selected but its source class was not found"])


class SelectionWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def test_changes_come_from_one_immutable_local_diff(self):
        self.assertIn("git diff --name-status -M HEAD^1 HEAD > changed-files.txt", self.workflow)
        self.assertIn("python3 scripts/ci/ui_impact.py changed-files.txt --manifest impact-manifest.json", self.workflow)
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


if __name__ == "__main__":
    unittest.main()
