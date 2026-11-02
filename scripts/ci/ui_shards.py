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

# Seconds are measured on macos-26 (runs 41020974154, 41023516202). Every `xcodebuild test` invocation also
# spends 2–3 minutes installing and launching before its first test, so each shard is a single one.
SHARDS = [
    {
        "name": "UI tests (preview)",
        "tests": [
            "CompanionPreviewSmokeTests/testAgentDetailsSheetMatchesTheDesktopHoverCard",  # 170–200
            "CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval",  # 90–100
            "CompanionPreviewSmokeTests/testProjectPageFinishedChangesAndWake",  # 75
            "CompanionPreviewSmokeTests/testExploredFoldAndApprovalCardMatchDesktop",  # 45–55
            "FeedbackTriggersUITests",  # 110–130
        ],
    },
    {
        "name": "UI tests (sheets, review, terminal) + unit tests",
        # The ClubhouseGoTests bundle takes seconds; it shares this shard's invocation (and launch cost).
        "unit": True,
        "tests": [
            "CompanionAgentSheetsTests",  # 230–350
            "CompanionTerminalUITests",  # 155–180
            "CompanionReviewUITests",  # 80
            "CompanionImageAttachmentUITests",  # 40–70
            "DiagnosticSettingsTests",  # 25
        ],
    },
    {
        # Split from "other" after run 41487601605 took 50 minutes of test time.
        # These classes contributed 1,473 s of test bodies; the remainder 1,310 s
        # (including one 48 s failed attempt). Each gets its own launch budget.
        "name": "UI tests (chat)",
        "tests": [
            "CompanionDispatcherUITests",  # 341
            "CompanionAutoQuotaUITests",  # 211
            "CompanionReadingUITests",  # 194, before the native-top regressions
            "CompanionMarkdownBlockUITests",  # 144
            "CompanionSlashCommandUITests",  # 139
            "CompanionHelperPresetsUITests",  # 105
            "CompanionContextWindowUITests",  # 104
            "CompanionLongReplyUITests",  # 86
            "CompanionComposerPasteUITests",  # 73
            "CompanionQueuedBurstUITests",  # 46
            "CompanionQuestionUITests",  # 29
        ],
    },
    {
        # Remaining preview, agent tree and diagnostics tests, plus every new UI class.
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
        if shard.get("unit"):
            flags.append(f"-only-testing:{UNIT_TARGET}")
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
