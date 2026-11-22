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

    def test_dispatcher_recovery_uses_existing_home_lane(self):
        inventory = ui_classes()
        entries = shards.matrix()["include"]
        self.assertEqual(len(entries), 8, "Do not add another hosted runner for recovery")
        home = next(entry for entry in entries
                    if entry["name"] == "UI tests (unicode, home)")
        self.assertIn("CompanionDispatcherRecoveryUITests", selected_classes(home, inventory),
                      "Recovery must not wait behind the catchall's unrelated UI classes")
        catchall = next(entry for entry in entries
                        if entry["selection"].startswith(f"-only-testing:{shards.UI_TARGET} "))
        self.assertNotIn("CompanionDispatcherRecoveryUITests", selected_classes(catchall, inventory))

    def test_provider_and_archive_controls_share_one_existing_home_lane(self):
        entries = shards.matrix()["include"]
        self.assertEqual(len(entries), 8)
        inventory = ui_classes()
        for cls in ("CompanionProviderV2UITests", "CompanionReadingArchiveHeaderUITests"):
            owners = [entry["name"] for entry in entries if cls in selected_classes(entry, inventory)]
            self.assertEqual(owners, ["UI tests (unicode, home)"])
        expected = {
            "CompanionProviderV2UITests": {
                "testProviderV2CaptureAccessibilityLargeReviewRows",
                "testProviderV2CaptureUnsupportedStartReason",
                "testProviderV2ApplyAndStartStaySeparate",
                "testProviderV2ApplyAtAccessibilityLargeKeepsReviewReachable",
                "testProviderV2LostApplyStaysUnknownAfterReopeningAndEqualRead",
                "testProviderV2LostStartNeverRequestsAnotherStart",
                "testProviderV2ApplyDoesNotImplyStartCapability",
            },
            "CompanionReadingArchiveHeaderUITests": {
                "testPausedTranscriptArchiveHeaderStillOpensAndClosesAfterStreaming",
            },
        }
        all_methods = collections.Counter()
        for source in (ROOT / "Annex/AnnexUITests").glob("*.swift"):
            all_methods.update(re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", source.read_text()))
        for cls, methods in expected.items():
            source = (ROOT / "Annex/AnnexUITests" / (cls + ".swift")).read_text()
            self.assertEqual(set(re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", source)), methods)
            self.assertEqual({method: all_methods[method] for method in methods}, dict.fromkeys(methods, 1))

    def test_future_classes_are_covered_once_by_the_catchall(self):
        self.assert_partition(ui_classes() | {"FutureUIRegressionTests"})

    def test_text_links_including_saved_archive_use_the_headroom_lane_once(self):
        inventory = ui_classes()
        source = (ROOT / "Annex/AnnexUITests/CompanionTextLinkUITests.swift").read_text()
        methods = set(re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", source))
        self.assertIn("testSavedSentAndReceivedRowsUseTheSameTapRoute", methods)
        owners = [
            entry["name"] for entry in shards.matrix()["include"]
            if "CompanionTextLinkUITests" in selected_classes(entry, inventory)
        ]
        self.assertEqual(owners, ["UI tests (composer, sheets)"])
        counts = collections.Counter(
            method for entry in shards.matrix()["include"]
            if "CompanionTextLinkUITests" in selected_classes(entry, inventory)
            for method in methods
        )
        self.assertEqual(dict(counts), dict.fromkeys(methods, 1))

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


if __name__ == "__main__":
    unittest.main()
