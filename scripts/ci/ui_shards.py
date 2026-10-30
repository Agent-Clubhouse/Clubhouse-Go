#!/usr/bin/env python3
"""Emit the UI test shard matrix for .github/workflows/ci.yml.

Each shard lists the test classes (or single methods) it runs. The last shard
has no list: it runs every other UI test, so a new test class needs no edit
here. To rebalance, move entries between shards using the per-test durations
that scripts/verify-xcresult.py writes to each shard's job summary.

Usage: ui_shards.py            prints `ui-shards=<json>` for $GITHUB_OUTPUT
       ui_shards.py --pretty   prints the matrix for reading
"""
import json
import sys

UI_TARGET = "ClubhouseGoUITests"
UNIT_TARGET = "ClubhouseGoTests"

# Seconds are first-run durations on macos-26 (runs 40921272638, 40924322455).
SHARDS = [
    {
        "name": "UI tests (preview, heavy)",
        "tests": [
            "CompanionPreviewSmokeTests/testAgentDetailsSheetMatchesTheDesktopHoverCard",  # 151
            "CompanionPreviewSmokeTests/testProjectPageFinishedChangesAndWake",  # 71
            "CompanionPreviewSmokeTests/testContentPreviewDismissesWhileToolUpdatesStream",  # 62
            "CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval",  # 56
            "CompanionPreviewSmokeTests/testHomeFoldsIdleProjectsAndPinsToTop",  # 51
            "CompanionPreviewSmokeTests/testExploredFoldAndApprovalCardMatchDesktop",  # 46
            "FeedbackTriggersUITests",  # 123
        ],
    },
    {
        "name": "UI tests (sheets and review) + unit tests",
        # The ClubhouseGoTests bundle is a few seconds; it rides along with the lightest shard.
        "unit": True,
        "tests": [
            "CompanionAgentSheetsTests",  # 294
            "CompanionImageAttachmentUITests",  # 44
            "CompanionReviewUITests",  # 130
            "DiagnosticSettingsTests",  # 26
        ],
    },
    {
        # Remaining preview smoke tests (~212), Framebriar shake (~186), terminal (~114) and anything new.
        "name": "UI tests (other)",
        "tests": None,
    },
]


def matrix(shards=SHARDS):
    listed = [test for shard in shards if shard["tests"] for test in shard["tests"]]
    duplicates = sorted({test for test in listed if listed.count(test) > 1})
    if duplicates:
        raise SystemExit(f"UI tests listed in more than one shard: {duplicates}")
    rest = [shard for shard in shards if shard["tests"] is None]
    if len(rest) != 1:
        raise SystemExit("Exactly one shard must run the remaining UI tests (tests: None)")

    include = []
    for shard in shards:
        if shard["tests"] is None:
            # A class listed elsewhere is skipped whole; a listed method skips just that method.
            flags = [f"-only-testing:{UI_TARGET}"] + [f"-skip-testing:{UI_TARGET}/{test}" for test in listed]
        else:
            flags = [f"-only-testing:{UI_TARGET}/{test}" for test in shard["tests"]]
        include.append({"name": shard["name"], "selection": " ".join(flags), "unit": bool(shard.get("unit"))})
    if sum(entry["unit"] for entry in include) != 1:
        raise SystemExit(f"Exactly one shard must run {UNIT_TARGET}")
    return {"include": include}


if __name__ == "__main__":
    result = matrix()
    if "--pretty" in sys.argv:
        print(json.dumps(result, indent=2))
    else:
        print(f"ui-shards={json.dumps(result, separators=(',', ':'))}")
