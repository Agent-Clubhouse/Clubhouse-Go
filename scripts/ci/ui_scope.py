#!/usr/bin/env python3
"""Plan a small pre-merge UI scope for pull requests and pushes; the coalesced daily run takes every UI test.

Every change that builds into the app runs, before merge:
- SMOKE: a fixed, fast native smoke of the main journeys (launch and settings, a scoped chat and markdown reply,
  Needs you, the Dispatcher row, search, the Full access confirmation, an incomplete approval, a grant answer and
  shake-to-feedback);
- the UI test classes the change edits, exactly;
- the critical journeys of every product area the change touches (JOURNEYS, matched on file names): one or two
  methods per ordinary area (the composer included), and the whole proof classes for privacy, security, destructive and
  draft/Unicode/paste data-integrity areas,
  even over budget;
- for a hub or an unknown product file, the BROAD tier: smoke plus one representative journey per area. This is an
  explicit escalation, not the full suite; add the `ci:full` label (then push or re-run) for every lane.
The hosted unit bundle runs for any product or hosted-test change. The Release build runs only for release-sensitive
diffs (project, settings, scheme, entitlements, privacy manifest, Info.plist, dependencies, assets, the app entry, or an
added or removed #if/#else/#endif line in Swift) and for unknown build or workflow inputs, which escalate; the daily run
always builds Release. The iPad lane only for iPad-specific code, iPad-run classes or areas that need it (privacy). The iPad run of the hosted
bundle otherwise waits for the daily run. Everything else waits for the daily run.

Input: `ui-shards=<json>` on stdin (the daily matrix; used only to keep the same output contract), and a
`git diff --name-status -M` file, with `--diff` the same diff at -U0 (without it, any app change builds Release). Output for $GITHUB_OUTPUT: `ui-shards`, `ui`, `ipad`, `release`, `unit`.
"""
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
UI_DIR, HOSTED_DIR, PRODUCT_DIR = "Annex/AnnexUITests/", "Annex/AnnexTests/", "Annex/Annex/"
UI_TARGET, UNIT_TARGET = "ClubhouseGoUITests", "ClubhouseGoTests"
SHARD_TEST_MINUTES = 35.0   # leaves room for retries and setup under the 55-minute job timeout
HOSTED_MINUTES = 4.0
UNSAMPLED_SECONDS = 60.0

SMOKE = [
    "CompanionAppLifetimeUITests/testRootSettingsActionCanOpenCloseAndReopen",
    "CompanionPreviewSmokeTests/testPreviewOpensScopedConversationAndKeepsCommandsNonLive",
    "CompanionPreviewSmokeTests/testAgentReplyRendersBlockMarkdown",
    "CompanionPreviewSmokeTests/testNeedsYouUsesTheDesktopWords",
    "CompanionNeedsYouUITests/testOfflineNoticeKeepsReachableRequestAndScopedRetry",
    "CompanionDispatcherUITests/testPinnedRowOpensTheDispatchersChatAndSettings",
    "CompanionSearchUITests/testTypingStillFindsAgentNamesTasksAndProjects",
    "CompanionPermissionMenuUITests/testFullAccessConfirmationExplainsUnpromptedEditsAndCommands",
    "CompanionPinnedDecisionUITests/testIncompleteRequestDisablesAllowButKeepsDenyAvailable",
    "CompanionGrantRequestUITests/testAllowOnceAndDeclineAnswerGrantRequests",
    "FeedbackTriggersUITests/testShakeOpensOverSettingsAndClosesBackToSettings",
]
# name: (file-name keywords, selectors, iPad, representative selector for the BROAD tier). Representatives are one
# cheap behaviour per area that smoke doesn't already prove (security, markdown, home and settings are covered there).
JOURNEYS = {
    "privacy": (["Feedback", "Framebriar", "Diagnostic", "Shake"],
                ["FeedbackTriggersUITests", "FeedbackDiagnosticsWireUITests", "FeedbackMenuAttachmentUITests",
                 "FramebriarShakeUITests", "FramebriarShakeDiagnosticsUITests"], True,
                "FeedbackTriggersUITests/testScreenshotPromptSettingTurnsItOff"),
    "security": (["Permission", "Grant", "Approval", "AccessLevel", "Pairing", "Trust"],
                 ["CompanionPermissionMenuUITests", "CompanionPermissionStatusUITests", "CompanionGrantRequestUITests",
                  "QA368GrantLayoutUITests", "CompanionAppLifetimeUITests"], False,
                 None),
    "destructive": (["DispatcherSettings", "Recovery", "Dispose", "Sleep"],
                    ["CompanionDispatcherUITests/testBehaviorClearChatAndForgetEverything", "CompanionRecoveryIntegrationUITests"],
                    False, "CompanionAppUpdateUITests/testSettingsWithoutUpdateShowsPlainVersionAndDestructiveForgetKeepsItsConfirmation"),
    "data": (["Draft", "Unicode", "Paste"],
             ["CompanionUnicodeFocusUITests", "CompanionComposerPasteUITests"], False,
             "CompanionUnicodeFocusUITests/testUserTapAndSendPreserveUnicodeBytes"),
    "composer": (["Composer"],
                 ["CompanionUnicodeFocusUITests/testUserTapAndSendPreserveUnicodeBytes",
                  "CompanionCompactComposerUITests/testIdleControlsStayCollapsedBeforeAndAfterTyping",
                  "CompanionCompactComposerUITests/testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation",
                  "CompanionCompactComposerUITests/testFitInvariantCatchesWronglyCollapsedAndWronglyFullTrays"], False,
                 "CompanionCompactComposerUITests/testFitInvariantCatchesWronglyCollapsedAndWronglyFullTrays"),
    "reading": (["Reading", "Conversation", "Timeline", "Transcript", "Latest", "Scroll", "Message"],
                ["CompanionReadingUITests/testStreamingKeepsFollowingWhenNobodyScrolls",
                 "CompanionReadingUITests/testUserPositionedReplyStaysWhileStreaming"], False,
                "CompanionReadingUITests/testStreamingKeepsFollowingWhenNobodyScrolls"),
    "terminal": (["Terminal"], ["CompanionTerminalUITests/testProjectTerminalEchoesTypingAndOffersTheKeyBar",
                               "CompanionTerminalUITests/testPasteButtonSendsBytesWithKeyboardShownAndHidden"], False,
                 "CompanionTerminalUITests/testPasteButtonSendsBytesWithKeyboardShownAndHidden"),
    "search": (["Search"], ["CompanionSearchUITests/testOpenedAgentsAppearInRecentAndSurviveProcessRelaunch"], False, None),
    "markdown": (["Markdown", "Content", "PDF", "Preview"], ["CompanionMarkdownBlockUITests/testTableAndCodeOpenFullScreenWithCopyAndShare"],
                 False, None),
    "projects": (["ProjectPage", "ProjectInfo", "Linked", "Project"],
                 ["CompanionProjectPageUITests/testSingleProjectMenuKeepsPinInactiveAndReadOnlyInfo",
                  "CompanionProjectPageUITests/testAllTerminalChoosesOneMachineAndOpensOnlyItsShell"],
                 False, "CompanionProjectPageUITests/testSingleProjectMenuKeepsPinInactiveAndReadOnlyInfo"),
    "update": (["AppUpdate"], ["CompanionAppUpdateUITests/testRestartNowAndCancelAreExplicitChoices",
                               "CompanionAppUpdateUITests/testSettingsWithoutUpdateShowsPlainVersionAndDestructiveForgetKeepsItsConfirmation"], False,
               None),
    "spawn": (["Spawn", "Managed", "Create"], ["CompanionManagedSpawnUITests/testManagedCreationRequiresAnExplicitChoiceAndBlankIsLocal",
                                             "CompanionSpawnVisualUITests/testLight"], False,
              "CompanionManagedSpawnUITests/testManagedCreationRequiresAnExplicitChoiceAndBlankIsLocal"),
    "settings": (["AgentSettings", "Settings", "Helper", "Preset"], ["CompanionAgentSettingsVisualUITests/testLight"],
                 False, None),
    "attachments": (["Attachment", "Image", "Icon", "Avatar"], ["CompanionImageAttachmentUITests/testPickRemoveAndSendImages"], False, None),
    "home": (["Home", "Root", "Toolbar", "Chips", "Tree", "Row"], ["CompanionAgentTreeUITests/testProjectUsesSameTreeAndCrossProjectCaption"],
             False, None),
    "dispatcher": (["Dispatcher", "Dispatch"], ["CompanionDispatcherLaunchUITests", "CompanionDispatchChipsUITests"], False, None),
    "header": (["Header", "Chrome", "ChatControls", "Glass"], ["CompanionChatHeaderUITests", "CompanionChatChromeUITests"], False, None),
    "limits": (["AutoQuota", "PlanLimits", "Context", "Usage"], ["CompanionAutoQuotaUITests", "CompanionContextWindowUITests"], False, None),
    "wake": (["Wake"], ["CompanionWakeFocusUITests"], False, None),
    "questions": (["Question"], ["CompanionQuestionUITests", "CompanionDesktopQuestionsUITests"], False, None),
    "review": (["Review"], ["CompanionReviewUITests"], False, None),
    "needsyou": (["Attention", "NeedsYou", "Finished"], ["CompanionNeedsYouActionCardUITests/testActionHeadlineAlignedMetadataAndVisibleReview",
                 "CompanionNeedsYouUITests/testBothOnlineCanShowKnownEmptyState"], False, None),
    "lifecycle": (["Navigation", "Lifecycle", "Scene", "Intent"], ["CompanionAppLifetimeUITests",
                  "CompanionSearchUITests/testOpenedAgentsAppearInRecentAndSurviveProcessRelaunch"], False, None),
    "archive": (["Archive", "Session"], ["CompanionReadingUITests/testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry"], False, None),
    "links": (["Link"], ["CompanionMarkdownBlockUITests/testTableAndCodeOpenFullScreenWithCopyAndShare"], False, None),
    "provider": (["Provider"], ["CompanionPreviewSmokeTests/testProviderApplyKeepsSavedProposalAndStartSeparate"], False, None),
}
# Hubs render or feed most screens: a change there gets the BROAD tier.
HUBS = ("CompanionStore.swift", "CompanionModels.swift", "CompanionPreviewService.swift", "CompanionPreviewRoot.swift",
        "CompanionRootView.swift", "CompanionAppRoot.swift", "CompanionDesign.swift", "CompanionTheme.swift",
        "CompanionSceneTestSupport.swift", "AnnexApp.swift")
# The UI suite runs the socket-free preview service: transport, the live service and wire decoders are proven by
# package and hosted tests (smoke still runs).
NO_UI_DIRS = ("Annex/Annex/Transport/", "Annex/Annex/Companion/Adapters/CompanionLive")
NO_UI_SUFFIXES = ("Decoding.swift",)
# Read only by the build job's deinit policy step, or only by the Linux Plan job; neither reaches UI tests.
BUILD_ONLY = ("scripts/isolated-deinit-policy.json", "scripts/check-isolated-deinits.py", "scripts/deinit_surface.py",
              "scripts/isolated-deinit-surface.swift", "scripts/deinit/")
PLAN_ONLY = ("scripts/ci/tests/", "scripts/ci/ui_shards.py", "scripts/ci/ui_timings.json")
# Release compiles and ships differently only through these: build settings, packaging, entitlements, dependencies,
# the app entry, or conditional compilation; an unknown non-product build or workflow input also builds Release.
RELEASE_SUFFIXES = (".pbxproj", ".xcconfig", ".xcscheme", ".entitlements", ".xcprivacy", "Info.plist", "Package.swift",
                    "Package.resolved", "AnnexApp.swift")
RELEASE_DIRS = ("Annex/Annex/Assets.xcassets/", "Annex/Annex.xcodeproj/")
CONDITIONAL = re.compile(r"^[+-]\s*#\s*(if|elseif|else|endif)\b")
IPAD_MARKERS = re.compile(r"horizontalSizeClass|userInterfaceIdiom|NavigationSplitView|\.pad\b")
TEST_CLASS = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", re.M)
TOP_LEVEL_TYPE = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*"
                            r"(class|struct|enum|actor|protocol|extension)\s+\w+", re.M)


def parse_changes(text):
    entries = []
    for line in text.splitlines():
        parts = [p for p in line.rstrip("\n").split("\t") if p]
        if not parts:
            continue
        if len(parts) == 1:
            entries.append(("modified", parts[0], None)); continue
        status = parts[0].upper()
        if status[0] in "RC":
            entries.append(("renamed" if status[0] == "R" else "copied", parts[2], parts[1]))
        else:
            entries.append(({"D": "removed", "A": "added"}.get(status, "modified"), parts[1], None))
    return entries


class Inventory:
    """UI test classes and methods in the checked-out tree, and the timing table."""

    def __init__(self, root):
        self.root = root
        self.methods = {}
        self.files = {}
        for path in sorted((root / UI_DIR).glob("*.swift")):
            text = path.read_text(errors="replace")
            classes = TEST_CLASS.findall(text)
            methods = re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", text)
            if classes and methods:
                self.methods.setdefault(classes[0], set()).update(methods)
                self.files[str(path.relative_to(root))] = (classes[0], len(TOP_LEVEL_TYPE.findall(text)) == 1 and len(classes) == 1)
        timings = root / "scripts/ci/ui_timings.json"
        self.timings = json.loads(timings.read_text())["methods"] if timings.exists() else {}

    def exists(self, selector):
        cls, _, method = selector.partition("/")
        return cls in self.methods and (not method or method in self.methods[cls])

    def minutes(self, selector):
        cls, _, method = selector.partition("/")
        names = [method] if method else sorted(self.methods.get(cls, ()))
        return sum(self.timings.get(cls, {}).get(n, [UNSAMPLED_SECONDS])[0] for n in names) / 60

    def ipad_classes(self):
        workflow = (self.root / ".github/workflows/ci.yml").read_text()
        start, end = workflow.find("\n  ipad-tests:"), workflow.find("\n  ci-result:")
        return set(re.findall(rf"-only-testing:{UI_TARGET}/(\w+)", workflow[start:end] if start >= 0 else ""))


def configured_selectors():
    selectors = list(SMOKE)
    for _, (_, tests, _, representative) in JOURNEYS.items():
        selectors += tests + ([representative] if representative else [])
    return selectors


def conditional_compilation(diff_text):
    """Files whose -U0 diff adds or removes an #if/#elseif/#else/#endif line in Swift."""
    files, current = [], None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
        elif current and current.endswith(".swift") and not line.startswith(("+++", "---")) and CONDITIONAL.match(line):
            if current not in files:
                files.append(current)
    return files


def plan(entries, root, changes, diff_text=None):
    inventory = Inventory(root)
    missing = [s for s in configured_selectors() if not inventory.exists(s)]
    if missing:
        raise SystemExit(f"ui_scope.py names UI tests that don't exist: {missing}")
    selected, reasons = set(), []
    app = ui = unit = release = ipad = broad = False
    areas = set()
    for status, path, previous in entries:
        for candidate in [path] + ([previous] if previous else []):
            if changes.classify(candidate) != changes.APP:
                continue
            if candidate.startswith(PLAN_ONLY):
                reasons.append(f"{candidate}: Plan job or daily matrix only"); continue
            app = True
            if candidate.endswith(RELEASE_SUFFIXES) or candidate.startswith(RELEASE_DIRS):
                release = True; reasons.append(f"{candidate}: release-sensitive (settings, packaging, dependencies or entry)")
            if candidate.startswith(BUILD_ONLY):
                reasons.append(f"{candidate}: build job deinit policy only"); continue
            ui = True
            if candidate.startswith(UI_DIR):
                info = inventory.files.get(candidate) if candidate == path and status not in ("removed",) else None
                if info and info[1]:
                    selected.add(info[0]); reasons.append(f"{candidate}: its class")
                    ipad |= info[0] in inventory.ipad_classes()
                else:
                    broad = True; reasons.append(f"{candidate}: shared, mixed, deleted or renamed UI test file → broad tier")
                continue
            if candidate.startswith(HOSTED_DIR):
                unit = True; reasons.append(f"{candidate}: hosted bundle in the unit shard (iPad's run is daily)")
                continue
            if candidate.startswith(PRODUCT_DIR):
                unit = True
                name = Path(candidate).name
                if candidate.startswith(NO_UI_DIRS) or candidate.endswith(NO_UI_SUFFIXES):
                    reasons.append(f"{candidate}: transport, proven by package and hosted tests"); continue
                text = (root / candidate).read_text(errors="replace") if (root / candidate).is_file() else ""
                ipad |= bool(IPAD_MARKERS.search(text))
                matched = [a for a, (keys, _, _, _) in JOURNEYS.items() if any(k in name for k in keys)]
                if name in HUBS or status in ("removed", "renamed") or not matched:
                    broad = True; reasons.append(f"{candidate}: {'hub' if name in HUBS else 'unmapped, removed or renamed'} → broad tier")
                for a in matched:
                    areas.add(a); reasons.append(f"{candidate}: {a} journeys")
                continue
            broad = release = True; reasons.append(f"{candidate}: build, project or workflow input → broad tier and Release")
    if app and diff_text is None:
        release = True; reasons.append("no line diff: Release-only code can't be ruled out")
    for path in conditional_compilation(diff_text or ""):
        release = True; reasons.append(f"{path}: adds or removes conditional compilation → Release build")
    if not ui:
        return {"ui": [], "unit": False, "release": release, "ipad": False, "build": app,
                "reasons": reasons or ["no app lanes"]}
    selected |= set(SMOKE)
    for a in areas:
        selected |= set(JOURNEYS[a][1]); ipad |= JOURNEYS[a][2]
    if broad:
        selected |= {rep for _, (_, _, _, rep) in JOURNEYS.items() if rep}
    # A whole class subsumes its methods.
    whole = {s for s in selected if "/" not in s}
    selected = {s for s in selected if "/" not in s or s.split("/")[0] not in whole}
    return {"ui": sorted(selected), "unit": unit, "release": release, "ipad": ipad, "broad": broad, "build": True,
            "areas": sorted(areas), "reasons": reasons}


def pack(selectors, unit, inventory):
    """First-fit-decreasing shards of at most SHARD_TEST_MINUTES; the hosted bundle rides the first shard."""
    items = sorted(selectors, key=lambda s: -inventory.minutes(s))
    shards = []
    for selector in items:
        cost = inventory.minutes(selector)
        for shard in shards:
            if shard["minutes"] + cost <= SHARD_TEST_MINUTES:
                shard["tests"].append(selector); shard["minutes"] += cost; break
        else:
            shards.append({"tests": [selector], "minutes": cost})
    if unit:
        if not shards:
            shards.append({"tests": [], "minutes": 0.0})
        shards[0]["minutes"] += HOSTED_MINUTES
    include = []
    for index, shard in enumerate(shards):
        flags = [f"-only-testing:{UI_TARGET}/{s}" for s in sorted(shard["tests"])]
        runs_unit = unit and index == 0
        if runs_unit:
            flags.append(f"-only-testing:{UNIT_TARGET}")
        include.append({"name": f"UI scope {index + 1}" + (" + unit tests" if runs_unit else ""),
                        "selection": " ".join(flags), "unit": runs_unit, "minutes": round(shard["minutes"], 1)})
    return {"include": include}


def load_changes(root=ROOT):
    spec = importlib.util.spec_from_file_location("changes", root / "scripts/ci/changes.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, root=ROOT):
    options = {"--manifest", "--diff"}
    value = lambda name: argv[argv.index(name) + 1] if name in argv else None
    manifest, diff = value("--manifest"), value("--diff")
    args = [a for i, a in enumerate(argv) if a not in options and (i == 0 or argv[i - 1] not in options)]
    line = stdin.read().strip()
    if not line.startswith("ui-shards="):
        raise SystemExit("Expected a ui-shards= line on stdin")
    daily = json.loads(line[len("ui-shards="):])
    entries = parse_changes(Path(args[0]).read_text()) if args else []
    decision = plan(entries, root, load_changes(root), Path(diff).read_text(errors="replace") if diff else None)
    inventory = Inventory(root)
    matrix = pack(decision["ui"], decision["unit"], inventory)
    total = sum(entry["minutes"] for entry in matrix["include"])
    print(f"UI scope: {len(decision['ui'])} selectors, {len(matrix['include'])} shard(s), ~{total:.1f} test-min; "
          f"areas {decision.get('areas') or 'none'}; broad tier {decision.get('broad', False)}; hosted {decision['unit']}; "
          f"iPad {decision['ipad']}; Release {decision['release']}", file=stderr)
    for reason in decision["reasons"]:
        print(f"  {reason}", file=stderr)
    if manifest:
        Path(manifest).write_text(json.dumps({"changes": entries, "decision": decision, "matrix": matrix}, indent=1))
    shards = matrix if matrix["include"] else {"include": daily["include"][:1]}
    print(f"ui-shards={json.dumps({'include': [{k: v for k, v in e.items() if k != 'minutes'} for e in shards['include']]}, separators=(',', ':'))}", file=stdout)
    print(f"ui={'true' if matrix['include'] else 'false'}", file=stdout)
    for key in ("ipad", "release", "unit"):
        print(f"{key}={'true' if decision[key] else 'false'}", file=stdout)


if __name__ == "__main__":
    main(sys.argv[1:])
