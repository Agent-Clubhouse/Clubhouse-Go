"""The emitted Xcode selectors must partition the complete UI class inventory."""
import collections
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("ui_shards", ROOT / "scripts/ci/ui_shards.py")
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)


def ui_classes():
    classes = set()
    for source in (ROOT / "Annex/AnnexUITests").glob("*.swift"):
        text = source.read_text()
        # XCTest discovers zero-argument test methods; exclude the common helper base.
        if re.search(r"\bfunc\s+test\w+\s*\(\s*\)", text):
            classes.update(re.findall(r"\bclass\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", text))
    return classes


def selected_classes(entry, inventory):
    only, skipped = set(), set()
    for flag in entry["selection"].split():
        mode, selector = flag.split(":", 1)
        target, _, cls = selector.partition("/")
        if target != shards.UI_TARGET:
            continue
        if "/" in cls:
            raise AssertionError("Keep each UI class together: " + selector)
        chosen = set(inventory) if not cls else {cls}
        if mode == "-only-testing":
            only.update(chosen)
        elif mode == "-skip-testing":
            skipped.update(chosen)
    return only - skipped


class UIClassCoverageTests(unittest.TestCase):
    def assert_partition(self, inventory, entries=None):
        counts = collections.Counter()
        for entry in entries if entries is not None else shards.matrix()["include"]:
            selected = selected_classes(entry, inventory)
            self.assertLessEqual(selected, inventory, entry["name"])
            counts.update(selected)
        self.assertEqual(set(counts), inventory, "No source UI class may be dropped")
        self.assertEqual(dict(counts), dict.fromkeys(inventory, 1), "No UI class may run in two shards")

    def test_union_is_the_full_source_class_set_without_duplicates(self):
        inventory = ui_classes()
        self.assertTrue(inventory, "An empty discovery must never satisfy the coverage check")
        self.assert_partition(inventory)

    def test_future_classes_are_covered_once_by_the_catchall(self):
        self.assert_partition(ui_classes() | {"FutureUIRegressionTests"})

    def test_unknown_class_selector_fails(self):
        inventory = {"CurrentTests"}
        with self.assertRaises(AssertionError):
            self.assert_partition(inventory, [{"name": "stale", "selection": "-only-testing:ClubhouseGoUITests/RenamedTests"}])

    def test_method_selectors_cannot_silently_split_or_rename_a_class(self):
        # Whole classes include every current and future test method. A stale method
        # name must never slip through discovery as it did before #488.
        with self.assertRaises(AssertionError):
            selected_classes({"selection": "-only-testing:ClubhouseGoUITests/CurrentTests/testOldName"}, {"CurrentTests"})

    def test_missing_and_duplicated_classes_fail(self):
        current = {"name": "current", "selection": "-only-testing:ClubhouseGoUITests/CurrentTests"}
        with self.assertRaises(AssertionError):
            self.assert_partition({"CurrentTests", "MissingTests"}, [current])
        with self.assertRaises(AssertionError):
            self.assert_partition({"CurrentTests"}, [current, current])

    def test_every_method_once_with_only_the_three_intentional_ipad_repeats(self):
        scope_spec = importlib.util.spec_from_file_location('scope_inventory', ROOT / 'scripts/ci/ui_scope.py')
        scope = importlib.util.module_from_spec(scope_spec)
        scope_spec.loader.exec_module(scope)
        inventory = scope.Inventory(ROOT).methods
        counts = collections.Counter()
        for entry in shards.matrix()['include']:
            for cls in selected_classes(entry, inventory):
                counts.update((cls, method) for method in inventory[cls])
        expected = {(cls, method) for cls, methods in inventory.items() for method in methods}
        self.assertTrue(expected)
        self.assertEqual(dict(counts), dict.fromkeys(expected, 1))
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        ipad = workflow.split('\n  ipad-tests:', 1)[1].split('\n  ci-result:', 1)[0]
        repeats = re.findall(r'-only-testing:ClubhouseGoUITests/(\w+)/(\w+)', ipad)
        self.assertEqual(set(repeats), {
            ('FeedbackTriggersUITests', 'testClearQueuedFeedbackIsReachableFromEnrollmentSheetAndSettings'),
            ('FeedbackTriggersUITests', 'testHeldReportsRequireConfirmationAndCanBeClearedWhileUnenrolled'),
            ('CompanionAgentTreeUITests', 'testProjectUsesSameTreeAndCrossProjectCaption'),
        })
        self.assertEqual(len(repeats), 3)
        for item in repeats:
            self.assertIn(item, expected)
            counts[item] += 1
        self.assertEqual({item for item, n in counts.items() if n == 2}, set(repeats))
        # Whole hosted bundle retained once on iPhone and once on iPad. This is
        # selection proof, not a claim of actual SDK discovery/execution.
        self.assertEqual(sum('-only-testing:ClubhouseGoTests' in e['selection']
                             for e in shards.matrix()['include']), 1)
        self.assertEqual(ipad.count('-only-testing:ClubhouseGoTests'), 1)


if __name__ == "__main__":
    unittest.main()
