"""Theme-only variants skipped on every push must still run in the scheduled appearance lane.

UIAppearanceMatrix.swift lets a UI test run one representative appearance on every push and every variant when
CLUBHOUSE_UI_APPEARANCE_MATRIX=full. This check fails if a method using it is missing from the nightly workflow's
selection, so moving a variant off the per-push path can never silently drop it.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
UI_TESTS = ROOT / "Annex/AnnexUITests"
WORKFLOW = ROOT / ".github/workflows/ui-appearance-nightly.yml"
GATES = ("requireFullAppearanceMatrix(", "appearanceMatrix(")


def gated_methods():
    """(class, method) for every zero-argument test method whose body uses the appearance switch."""
    found = set()
    for source in sorted(UI_TESTS.glob("*.swift")):
        if source.name == "UIAppearanceMatrix.swift":
            continue
        text = source.read_text()
        classes = re.findall(r"\bclass\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", text)
        if not classes:
            continue
        cls = classes[0]
        for match in re.finditer(r"\bfunc\s+(test\w+)\s*\(\s*\)[^{]*\{", text):
            depth, index = 1, match.end()
            while depth and index < len(text):
                depth += {"{": 1, "}": -1}.get(text[index], 0)
                index += 1
            if any(gate in text[match.end():index] for gate in GATES):
                found.add((cls, match.group(1)))
    return found


def nightly_selection():
    return set(re.findall(r"-only-testing:ClubhouseGoUITests/(\w+(?:/\w+)?)", WORKFLOW.read_text()))


class AppearanceMatrixTests(unittest.TestCase):
    def test_every_gated_method_runs_in_the_nightly_lane(self):
        selected = nightly_selection()
        missing = sorted(f"{cls}/{method}" for cls, method in gated_methods()
                         if cls not in selected and f"{cls}/{method}" not in selected)
        self.assertEqual(missing, [], "Add these to ui-appearance-nightly.yml or keep them on every push")

    def test_the_nightly_lane_turns_the_full_matrix_on(self):
        self.assertIn("TEST_RUNNER_CLUBHOUSE_UI_APPEARANCE_MATRIX: full", WORKFLOW.read_text())

    def test_some_methods_are_gated(self):
        # Guards the parser itself: an empty result would make the first check vacuous.
        self.assertGreaterEqual(len(gated_methods()), 10)

    def test_nightly_selection_names_existing_classes(self):
        classes = set()
        for source in UI_TESTS.glob("*.swift"):
            classes.update(re.findall(r"\bclass\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", source.read_text()))
        unknown = sorted(entry for entry in nightly_selection() if entry.split("/")[0] not in classes)
        self.assertEqual(unknown, [])


if __name__ == "__main__":
    unittest.main()
