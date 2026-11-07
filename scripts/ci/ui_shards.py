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

# Attempt-time estimates use runs 41713658226/41713894400 and the preceding 7a3356b run.
# Setup, installation, retries and artifact collection also consume the 55-minute job budget.
SHARDS = [
    {
        # Mixed-run worst observed attempts: ~31 minutes, including content-preview retries.
        "name": "UI tests (preview)",
        "tests": [
            "CompanionChatHeaderVisualUITests",
            "CompanionPreviewSmokeTests/testAgentDetailsSheetMatchesTheDesktopHoverCard",
            "CompanionPreviewSmokeTests/testAgentDetailsSheetLinksToAgentSettings",
            "CompanionPreviewSmokeTests/testAgentDetailsSheetForAnAgentWithoutSession",
            "CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval",
            "CompanionPreviewSmokeTests/testProjectPageFinishedChangesAndWake",
            "CompanionPreviewSmokeTests/testExploredFoldAndApprovalCardMatchDesktop",
            "FeedbackTriggersUITests",
            "CompanionPreviewSmokeTests/testContentPreviewDismissesWhileToolUpdatesStream",
        ],
    },
    {
        # ~22 minutes of timed attempts, plus the short hosted Swift Testing cases.
        "name": "UI tests (sheets, review, terminal) + unit tests",
        # The ClubhouseGoTests bundle takes seconds; it shares this shard's invocation (and launch cost).
        "unit": True,
        "tests": [
            "CompanionAgentSheetsTests",
            "CompanionTerminalUITests",
            "CompanionReviewUITests",
            "CompanionImageAttachmentUITests",
            "DiagnosticSettingsTests",
        ],
    },
    {
        # Runs 41713658226/41713894400: these classes consumed 21–30 minutes,
        # including retries. Separate them from reading/input's projected 28–31.
        "name": "UI tests (dispatcher, auto quota)",
        "tests": [
            "CompanionRecoveryIntegrationUITests",
            "CompanionRecoveryXCUIDiagnosticTests",
            "CompanionDispatcherUITests",
            "CompanionAutoQuotaUITests",
        ],
    },
    {
        # ~28 minutes in main; ~36 using each method's slowest observed attempt total.
        "name": "UI tests (reading, input)",
        "tests": [
            "CompanionReadingRestoreUITests",
            "CompanionReadingUITests",
            "CompanionMarkdownBlockUITests",
            "CompanionSlashCommandUITests",
            "CompanionHelperPresetsUITests",
            "CompanionContextWindowUITests",
            "CompanionLongReplyUITests",
            "CompanionComposerPasteUITests",
            "CompanionQueuedBurstUITests",
            "CompanionQuestionUITests",
        ],
    },
    {
        # About 23 minutes in each recent run, ~32 in a mixed worst-case estimate.
        # The CLI settings retry moves here; content-preview retries share the preview lane.
        "name": "UI tests (agents, keyboard)",
        "tests": [
            "CompanionCompactComposerUITests",
            "CompanionAgentTreeUITests",
            "CompanionKeyboardDismissalUITests",
            "CompanionPreviewSmokeTests/testAgentSettingsConfirmsCliChangeAndCancelKeepsTheOldSelection",
        ],
    },
    {
        # Run42323580352 recorded 872.735s of completed attempts in these three
        # classes before the catchall hit its55-minute limit; unfinished work is additional.
        # Separate the existing classes without changing methods, deadlines or retries.
        "name": "UI tests (feedback, shake)",
        "tests": [
            "FeedbackDiagnosticsWireUITests",
            "FramebriarShakeDiagnosticsUITests",
            "FramebriarShakeUITests",
        ],
    },
    {
        # Remaining preview/diagnostics and new UI classes. Header/composer and restore/recovery run above.
        # Live-test guards and all existing skip behavior remain as before.
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
