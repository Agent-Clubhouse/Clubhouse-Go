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

# Rebalanced against the 2026-11-19 source inventory and original run
# 44622082206 timings. Fifteen whole-class lanes include measured setup/hosted
# reserves under the unchanged 55-minute job timeout. See docs/ci-shard-balance.md
# for the observation inputs, unsampled reserves and estimate limits.
SHARDS = [
    {
        "name": "UI tests (grants, projects) + unit tests",
        "unit": True,
        "tests": [
            "QA368GrantLayoutUITests",
            "CompanionHeaderEdgeUITests",
            "CompanionProjectPageUITests",
            "CompanionSearchUITests",
            "CompanionOfflineBannerUITests",
        ],
    },
    {
        "name": "UI tests (preview)",
        "tests": [
            "CompanionPreviewSmokeTests",
            "CompanionQueuedBurstUITests",
        ],
    },
    {
        "name": "UI tests (feedback diagnostics)",
        "tests": [
            "FeedbackDiagnosticsWireUITests",
            # Same lane, runs after the wire class: a stalled pinch cannot fail those reveals.
            "FeedbackEditorPinchUITests",
            "CompanionNeedsYouActionCardUITests",
        ],
    },
    {
        "name": "UI tests (dispatcher, settings)",
        "tests": [
            "CompanionDispatcherUITests",
            "DiagnosticSettingsTests",
            "CompanionSlashCommandUITests",
            "CompanionReviewUITests",
        ],
    },
    {
        "name": "UI tests (chips, lifecycle)",
        "tests": [
            "CompanionDispatchChipsUITests",
            "CompanionSessionModelUITests",
            "CompanionAppLifetimeUITests",
            "CompanionManagedSpawnUITests",
            "CompanionHardwareKeyboardUITests",
        ],
    },
    {
        "name": "UI tests (decisions, linked home)",
        "tests": [
            "CompanionPinnedDecisionUITests",
            "CompanionCombinedLinkedHomeUITests",
            "CompanionContextWindowUITests",
            "FramebriarShakeDiagnosticsUITests",
            "CompanionMarkdownFileUITests",
        ],
    },
    {
        "name": "UI tests (home, settings)",
        "tests": [
            "CompanionLinkedHomeUITests",
            "CompanionSettingsRegroupUITests",
            "CompanionLatestUITests",
            "CompanionGlassSchemeUITests",
            "CompanionLargeCatalogUITests",
        ],
    },
    {
        "name": "UI tests (footer, desktop scope)",
        "tests": [
            "CompanionComposerFooterSurfaceUITests",
            "CompanionHomeDesktopScopeUITests",
            "CompanionAppUpdateUITests",
            "CompanionChatHeaderUITests",
            "CompanionMarkdownBlockUITests",
            "FeedbackMenuAttachmentUITests",
        ],
    },
    {
        "name": "UI tests (opening, terminal)",
        "tests": [
            "CompanionReadingOpeningUITests",
            "CompanionTerminalUITests",
            "CompanionChatChromeUITests",
            "CompanionLinkedProjectUITests",
            "CompanionAgentTreeUITests",
            "CompanionHomeVisibilityUITests",
        ],
    },
    {
        "name": "UI tests (launch, native menus)",
        "tests": [
            "CompanionDispatcherLaunchUITests",
            "CompanionAgentRowMenuUITests",
            "CompanionAgentSettingsVisualUITests",
            "CompanionToolbarUITests",
            "CompanionComposerPasteUITests",
            "CompanionLongReplyUITests",
        ],
    },
    {
        "name": "UI tests (unicode, reading)",
        "tests": [
            "CompanionUnicodeFocusUITests",
            "CompanionReadingUITests",
            "CompanionAgentSheetsTests",
            "FeedbackTriggersUITests",
            "FramebriarShakeUITests",
            "CompanionNeedsYouUITests",
        ],
    },
    {
        "name": "UI tests (composer, keyboard)",
        "tests": [
            "CompanionCompactComposerUITests",
            "CompanionKeyboardDismissalUITests",
            "CompanionHomeSubtitleUITests",
            "CompanionGrantRequestUITests",
            "CompanionImageAttachmentUITests",
            "CompanionRecoveryIntegrationUITests",
        ],
    },
    {
        "name": "UI tests (header, catalog)",
        "tests": [
            "CompanionChatHeaderVisualUITests",
            "CompanionLinkedProjectStateUITests",
            "CompanionAutoQuotaUITests",
            "CompanionHelperPresetsUITests",
            "CompanionWakeFocusUITests",
            "CompanionQuestionUITests",
        ],
    },
    {
        "name": "UI tests (activity, permissions)",
        "tests": [
            "CompanionWorkingActivityUITests",
            "CompanionPermissionMenuUITests",
            "CompanionHeaderReflowUITests",
            "CompanionReadingRestoreUITests",
            "CompanionPermissionStatusUITests",
            "CompanionSpawnVisualUITests",
        ],
    },
    {
        "name": "UI tests (other)",
        # Future classes remain covered without a selector edit.
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
