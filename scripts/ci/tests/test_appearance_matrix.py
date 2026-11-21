"""The scheduled appearance lane must fail closed.

Theme-only variants skipped on every push (UIAppearanceMatrix.swift) run nightly. These checks keep that lane honest:
its selection is derived from the sources, and its result check fails when the full-matrix switch is missing, a gated
method is skipped, missing or failed, a loop runs fewer variants than it lists, or any other selected test is skipped.
Synthetic records follow the shape of `xcresulttool get test-results tests` and the helper's printed marker.
"""
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("appearance_matrix", ROOT / "scripts/ci/appearance_matrix.py")
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)
WORKFLOW = ROOT / ".github/workflows/ui-appearance-nightly.yml"
LOOPS = {"CompanionPermissionMenuUITests/testPortraitEveryLevelFitsWithoutScrollingAcrossThemes",
         "CompanionPermissionMenuUITests/testXLargePortraitEveryLevelFitsWithoutScrollingAcrossThemes",
         "CompanionNeedsYouActionCardUITests/testSeveralRequestsAndDesktopsAppearanceMatrix"}
THEMES = ["Light", "Dark", "Catppuccin Latte", "Catppuccin Mocha"]


def case(identifier, result):
    return {"nodeType": "Test Case", "nodeIdentifier": identifier + "()", "result": result}


def record(results):
    return {"testNodes": [{"nodeType": "Test Plan", "children": [
        {"nodeType": "Unit test bundle", "children": [case(i, r) for i, r in results.items()]}]}]}


def marker(identifier, mode, variants, ran):
    cls, method = identifier.split("/")
    # Exactly the Swift helper's format, including XCTest's `name`.
    return (f"Test Case '-[ClubhouseGoUITests.{cls} {method}]' started.\n"
            f"APPEARANCE_MATRIX test=-[ClubhouseGoUITests.{cls} {method}] mode={mode} "
            f"variants={'|'.join(variants)} ran={'|'.join(ran)}")


class Lane:
    """A synthetic nightly result for the current gated methods."""

    def __init__(self):
        self.expected = matrix.gated_methods()
        self.ids = [f"{cls}/{method}" for cls, method in self.expected]
        self.results = {i: "Passed" for i in self.ids}
        self.lines = [marker(i, "full", THEMES, THEMES) if i in LOOPS else marker(i, "full", ["dark"], ["dark"])
                      for i in self.ids]

    def problems(self):
        return matrix.problems(record(self.results), "\n".join(self.lines), self.expected)


class AppearanceLaneVerifierTests(unittest.TestCase):
    def test_complete_full_mode_lane_passes(self):
        self.assertEqual(Lane().problems(), [])

    def test_missing_switch_fails_even_when_the_representatives_pass(self):
        lane = Lane()
        lane.results = {i: ("Passed" if i in LOOPS else "Skipped") for i in lane.ids}
        lane.lines = [marker(i, "push", THEMES, ["Light"]) if i in LOOPS else marker(i, "push", ["dark"], [])
                      for i in lane.ids]
        issues = lane.problems()
        self.assertTrue(any("push mode" in issue for issue in issues), issues)
        self.assertTrue(any("skipped, expected passed" in issue for issue in issues), issues)

    def test_skipped_only_result_without_markers_fails(self):
        lane = Lane()
        lane.results = {i: "Skipped" for i in lane.ids}
        lane.lines = []
        issues = lane.problems()
        self.assertEqual(sum("skipped, expected passed" in issue for issue in issues), len(lane.ids))
        self.assertEqual(sum("printed no APPEARANCE_MATRIX line" in issue for issue in issues), len(lane.ids))

    def test_a_gated_method_missing_from_the_result_fails(self):
        lane = Lane()
        missing = lane.ids[0]
        del lane.results[missing]
        self.assertIn(f"{missing} did not run", lane.problems())

    def test_a_failed_gated_method_fails(self):
        lane = Lane()
        lane.results[lane.ids[1]] = "Failed"
        self.assertIn(f"{lane.ids[1]} failed, expected passed", lane.problems())

    def test_a_shortened_loop_fails(self):
        lane = Lane()
        loop = sorted(LOOPS)[0]
        lane.lines = [line for line in lane.lines if loop not in line] + [marker(loop, "full", THEMES, ["Light", "Dark"])]
        self.assertTrue(any(issue.startswith(f"{loop} ran ['Light', 'Dark'] of its variants") for issue in lane.problems()))

    def test_an_unexpected_skip_or_failure_elsewhere_fails(self):
        lane = Lane()
        lane.results["CompanionPermissionMenuUITests/testLandscapeEveryLevelIsReachableAndFullAccessStillConfirms"] = "Skipped"
        self.assertTrue(any(issue.startswith("unexpected skipped test") for issue in lane.problems()))

    def test_a_marker_from_another_method_does_not_count(self):
        lane = Lane()
        target = lane.ids[2]
        lane.lines = [line for line in lane.lines if target not in line]
        self.assertIn(f"{target} printed no APPEARANCE_MATRIX line", lane.problems())


class AppearanceSelectionTests(unittest.TestCase):
    def test_parser_finds_the_gated_methods(self):
        # Guards against a vacuous selection or verifier.
        self.assertGreaterEqual(len(matrix.gated_methods()), 10)

    def test_selectors_name_exactly_the_gated_methods(self):
        expected = [f"-only-testing:ClubhouseGoUITests/{c}/{m}" for c, m in matrix.gated_methods()]
        self.assertEqual(matrix.selectors(), expected)

    def test_every_selected_method_exists_in_its_class(self):
        sources = {p.stem: p.read_text() for p in (ROOT / "Annex/AnnexUITests").glob("*.swift")}
        for cls, method in matrix.gated_methods():
            self.assertRegex(sources[cls], rf"\bfunc\s+{method}\s*\(\s*\)")

    def test_a_commented_out_gate_is_not_gated(self):
        with tempfile.TemporaryDirectory() as directory:
            tests = Path(directory) / "Annex/AnnexUITests"
            tests.mkdir(parents=True)
            (tests / "SampleUITests.swift").write_text(
                "final class SampleUITests: ReliableUITestCase {\n"
                "    func testActive() throws {\n        try requireFullAppearanceMatrix(\"dark\")\n    }\n"
                "    func testCommented() throws {\n        // try requireFullAppearanceMatrix(\"dark\")\n    }\n"
                "}\n")
            self.assertEqual(matrix.gated_methods(Path(directory)), [("SampleUITests", "testActive")])

    def test_the_nightly_workflow_actively_uses_generated_selection_and_the_verifier(self):
        active = [line.strip() for line in WORKFLOW.read_text().splitlines() if not line.strip().startswith("#")]
        self.assertIn("TEST_RUNNER_CLUBHOUSE_UI_APPEARANCE_MATRIX: full", active)
        self.assertIn("SELECTION=$(python3 scripts/ci/appearance_matrix.py selectors)", active)
        self.assertIn("$SELECTION \\", active)
        self.assertIn("python3 scripts/ci/appearance_matrix.py verify TestResults/tests.json xcodebuild-ui.log", active)
        self.assertFalse(any(re.search(r"-only-testing:ClubhouseGoUITests/", line) for line in active),
                         "Hand-written selectors can drift; derive them from the sources")

    def test_the_marker_format_matches_the_swift_helper(self):
        helper = (ROOT / "Annex/AnnexUITests/UIAppearanceMatrix.swift").read_text()
        self.assertIn('print("APPEARANCE_MATRIX test=\\(name) mode=\\(runsFullAppearanceMatrix ? "full" : "push") "', helper)
        self.assertIn('"variants=\\(variants.joined(separator: "|")) ran=\\(running.joined(separator: "|"))"', helper)


if __name__ == "__main__":
    unittest.main()
