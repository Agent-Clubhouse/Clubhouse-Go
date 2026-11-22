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

# Source and cost provenance, unknown-duration and retry sensitivity are recorded in
# docs/ci-execution-budget.md. Placement changes no class/method, retry, timeout,
# iPad repeat, hosted bundle or required check. Timings are estimates, not waivers.
# Same eight jobs, balanced over the complete retained class inventory.
SHARDS = [
    {
        "name": "UI tests (preview, project pages)",
        "tests": [
            "CompanionHeaderReflowUITests",
            "CompanionImageAttachmentUITests",
            "CompanionLinkedHomeUITests",
            "CompanionLongReplyUITests",
            "CompanionPermissionMenuUITests",
            "CompanionPermissionStatusUITests",
            "CompanionSessionModelUITests",
            "CompanionToolbarUITests",
            "CompanionUnicodeFocusUITests",
            "FramebriarShakeDiagnosticsUITests",
        ],
    },
    {
        "name": "UI tests (feedback, needs you)",
        "tests": [
            "CompanionAgentRowMenuUITests",
            "CompanionAgentTreeUITests",
            "CompanionAutoQuotaUITests",
            "CompanionChatHeaderUITests",
            "CompanionHomeVisibilityUITests",
            "CompanionLatestUITests",
            "CompanionReadingRestoreUITests",
            "CompanionSlashCommandUITests",
            "FramebriarShakeUITests",
            "QA368GrantLayoutUITests",
        ],
    },
    {
        "name": "UI tests (dispatcher, terminal)",
        "tests": [
            "CompanionAppUpdateUITests",
            "CompanionCombinedLinkedHomeUITests",
            "CompanionDispatcherLaunchUITests",
            "CompanionHomeSubtitleUITests",
            "CompanionLinkedProjectStateUITests",
            "CompanionOfflineBannerUITests",
            "CompanionQueuedBurstUITests",
            "CompanionReadingOpeningUITests",
            "CompanionRecoveryIntegrationUITests",
            "CompanionReviewUITests",
        ],
    },
    {
        "name": "UI tests (unicode, home)",
        "tests": [
            "CompanionComposerFooterSurfaceUITests",
            "CompanionComposerPasteUITests",
            "CompanionHeaderEdgeUITests",
            "CompanionLiveE2ETests",
            "CompanionLiveSmokeTests",
            "CompanionPhoneWorkflowTests",
            "CompanionPinnedDecisionUITests",
            "CompanionProviderSmokeTests",
            "CompanionReadingUITests",
            "CompanionTerminalUITests",
            "CompanionWakeFocusUITests",
            "CompanionWorkingActivityUITests",
            "FeedbackMenuAttachmentUITests",
        ],
    },
    {
        "name": "UI tests (search, permissions)",
        "tests": [
            "CompanionAgentSettingsVisualUITests",
            "CompanionContextLimitsUITests",
            "CompanionHelperPresetsUITests",
            "CompanionMarkdownBlockUITests",
            "CompanionNeedsYouActionCardUITests",
            "CompanionPreviewSmokeTests",
            "CompanionQuestionUITests",
            "CompanionSpawnVisualUITests",
        ],
    },
    {
        "name": "UI tests (composer, sheets)",
        "tests": [
            "CompanionAdditionalProviderTests",
            "CompanionChatChromeUITests",
            "CompanionDesktopQuestionsUITests",
            "CompanionDispatchChipsUITests",
            "CompanionDispatcherUITests",
            "CompanionGrantRequestUITests",
            "CompanionHardwareKeyboardUITests",
            "CompanionLinkedProjectUITests",
            "CompanionProjectInfoUITests",
            "CompanionProjectPageUITests",
        ],
    },
    {
        "name": "UI tests (reading, grants) + unit tests",
        "unit": True,
        "tests": [
            "CompanionAgentSheetsTests",
            "CompanionCompactComposerUITests",
            "CompanionGlassSchemeUITests",
            "CompanionHomeDesktopScopeUITests",
            "CompanionLargeCatalogUITests",
            "CompanionMarkdownFileUITests",
            "CompanionSearchUITests",
            "DiagnosticSettingsTests",
            "FeedbackTriggersUITests",
        ],
    },
    {
        "name": "UI tests (other)",
        # Complete complement plus every future class remains selected once.
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
