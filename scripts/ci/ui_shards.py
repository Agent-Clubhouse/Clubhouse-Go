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

# Estimates use first-attempt method medians from the 2026-11-16 CI audit.
# Unsampled methods reserve 60s per appearance/checked viewport; add 5m setup and
# 5m for hosted tests in the unit shard. These are estimates, not timeout gates.
# See docs/ci-shard-balance.md for the unchanged inventory and measurement limits.
SHARDS = [
    {
        # Estimated elapsed: 41.0 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (preview, project pages)",
        "tests": [
            "CompanionPreviewSmokeTests",
            "CompanionSpawnVisualUITests",
            "CompanionComposerPasteUITests",
            "CompanionAppLifetimeUITests",
            "FramebriarShakeDiagnosticsUITests",
        ],
    },
    {
        # Estimated elapsed: 40.7 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (feedback, needs you)",
        "tests": [
            "FeedbackDiagnosticsWireUITests",
            "CompanionNeedsYouActionCardUITests",
            "CompanionPinnedDecisionUITests",
            "CompanionProjectPageUITests",
            "CompanionContextWindowUITests",
            "CompanionNeedsYouUITests",
        ],
    },
    {
        # Estimated elapsed: 40.6 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (dispatcher, terminal)",
        "tests": [
            "CompanionDispatcherUITests",
            "CompanionSessionModelUITests",
            "CompanionTerminalUITests",
            "CompanionGrantRequestUITests",
            "FramebriarShakeUITests",
            "DiagnosticSettingsTests",
            "CompanionQueuedBurstUITests",
            "CompanionAdditionalProviderTests",
            "CompanionPhoneWorkflowTests",
        ],
    },
    {
        # Estimated elapsed: 40.8 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (unicode, home)",
        "tests": [
            "CompanionUnicodeFocusUITests",
            "CompanionHomeSubtitleUITests",
            "CompanionAppUpdateUITests",
            "CompanionHelperPresetsUITests",
            "CompanionLinkedProjectUITests",
            "CompanionMarkdownFileUITests",
        ],
    },
    {
        # Estimated elapsed: 40.9 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (search, permissions)",
        "tests": [
            "CompanionOfflineBannerUITests",
            "CompanionSearchUITests",
            "CompanionPermissionMenuUITests",
            "FeedbackTriggersUITests",
            "CompanionMarkdownBlockUITests",
            "CompanionLongReplyUITests",
            "CompanionImageAttachmentUITests",
        ],
    },
    {
        # Observed 35m57s to 37m55s on #617/#619; reserve 13m for unsampled link scenarios.
        # This is a first-attempt estimate, not a timeout or retry-policy change.
        "name": "UI tests (composer, sheets)",
        "tests": [
            "CompanionCompactComposerUITests",
            "CompanionManagedSpawnUITests",
            "CompanionRecoveryIntegrationUITests",
            "CompanionAgentSettingsVisualUITests",
            "CompanionWakeFocusUITests",
            "CompanionHardwareKeyboardUITests",
            "CompanionReviewUITests",
            "CompanionTextLinkUITests",
        ],
    },
    {
        # Estimated elapsed: 40.8 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (reading, grants) + unit tests",
        "unit": True,
        "tests": [
            "CompanionReadingUITests",
            "CompanionAutoQuotaUITests",
            "QA368GrantLayoutUITests",
            "CompanionAgentTreeUITests",
            "CompanionChatHeaderUITests",
            "CompanionQuestionUITests",
        ],
    },
    {
        # Estimated elapsed: 40.6 minutes; timeout/retry policy is unchanged.
        "name": "UI tests (other)",
        # Catch all remaining classes, including future additions and live-test guards.
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
