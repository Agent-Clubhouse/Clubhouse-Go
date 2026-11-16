# UI shard balance, November 16, 2026

The seven-shard catchall timed out in all 13 completed audit runs. Eight whole-class shards preserve every UI class and test method, with the catchall still covering future classes. The 55-minute timeout, retries, test assertions, hosted gate, and iPad job are unchanged. The preview follow diagnostic runs only after failure; it remains best effort and failure artifacts are still uploaded.

## Estimate and limits

Timing input: the 45-run audit in `.clubhouse/agents/qa-artifacts/go-ci-efficiency-audit-2026-11-16.md` (runs 43702476235–43804543773, November 15–16). Its UI logs supply first-attempt elapsed times, taking the median per method across available runs. Repeated attempts within a job do not count as independent samples. Renamed project-page and Needs-you methods retain the corresponding historical sample.

After main #489 adds its second Diagnostics method, the integrated inventory has **56 classes / 303 zero-argument test methods**, including managed-spawn coverage from #454. 218 methods have a matching historical sample. An unsampled method reserves **60 seconds**; known multi-appearance loops reserve 60 seconds per appearance or independently checked viewport. Live-only methods that skip in ordinary PR CI reserve one second for their existing guard, without changing that guard. Each shard adds five minutes for setup/results, and the hosted shard adds another five minutes. These are planning estimates, not guarantees or new gates.

The multi-appearance budgets are: Home subtitle 5, offline banner 10 (5 appearances × Home/Needs you), permission portrait 4, Search 5, recovery banner 5, Unicode created-notice drafts 5, and Needs-you action cards 5. Landscape permission and Project info each launch once and use the ordinary 60-second unsampled budget.

The initial 302-method balance estimated 40.6–41.1 minutes; #489 adds one unsampled Diagnostics method (60 seconds) to Dispatcher/Terminal. Eight shards now estimate **40.6–41.6 minutes**, leaving about 14 minutes under the unchanged timeout. A ninth shard adds another setup job against a saturated 4–5-slot macOS pool; it is deferred until real measurements justify it. After the first PR CI run, record each actual job duration. Revisit nine shards if any exceeds about 48 minutes. CI contention, retries and newly added tests can exceed these estimates.

## Shard counts

Before and after use the same source inventory. Class counts in the old matrix overlap because PreviewSmoke was split by method. The new matrix assigns each class exactly once. Method counts include existing guarded/skipped live tests.

| Before shard | Classes touched | Methods |
| --- | ---: | ---: |
| UI tests (preview) | 3 | 25 |
| UI tests (sheets, review, terminal) + unit tests | 5 | 20 |
| UI tests (dispatcher, auto quota) | 3 | 32 |
| UI tests (reading, input) | 10 | 34 |
| UI tests (agents, keyboard) | 4 | 17 |
| UI tests (feedback, shake) | 3 | 27 |
| UI tests (other) | 30 | 148 |

| After shard | Classes | Methods | Estimated minutes including reserves |
| --- | ---: | ---: | ---: |
| UI tests (preview, project pages) | 5 | 38 | 41.0 |
| UI tests (feedback, needs you) | 6 | 39 | 40.7 |
| UI tests (dispatcher, terminal) | 9 | 47 | 41.6 |
| UI tests (unicode, home) | 6 | 35 | 40.8 |
| UI tests (search, permissions) | 7 | 22 | 40.9 |
| UI tests (composer, sheets) | 7 | 33 | 41.1 |
| UI tests (reading, grants) + unit tests | 6 | 37 | 40.8 |
| UI tests (other) | 10 | 52 | 40.6 |

## Per-class counts and placement

The method count is unchanged in every row. Sampled is the number of methods with a historical median; estimated seconds exclude per-job setup and hosted reserves. Old/new shard numbers refer to table order above.

| UI class | Methods before → after | Sampled | Estimated test seconds | Before shard(s) | After shard |
| --- | ---: | ---: | ---: | --- | ---: |
| CompanionAdditionalProviderTests | 4 → 4 | 0 | 4.0 | 7 | 3 |
| CompanionAgentSettingsVisualUITests | 5 → 5 | 0 | 300.0 | 7 | 6 |
| CompanionAgentSheetsTests | 7 → 7 | 6 | 399.2 | 2 | 8 |
| CompanionAgentTreeUITests | 2 → 2 | 2 | 221.5 | 5 | 7 |
| CompanionAppLifetimeUITests | 3 → 3 | 3 | 121.7 | 7 | 1 |
| CompanionAppUpdateUITests | 7 → 7 | 7 | 310.0 | 7 | 4 |
| CompanionAutoQuotaUITests | 8 → 8 | 8 | 434.9 | 3 | 7 |
| CompanionChatChromeUITests | 6 → 6 | 6 | 280.4 | 7 | 8 |
| CompanionChatHeaderUITests | 4 → 4 | 4 | 144.6 | 7 | 7 |
| CompanionChatHeaderVisualUITests | 10 → 10 | 10 | 618.1 | 1 | 8 |
| CompanionCompactComposerUITests | 8 → 8 | 8 | 631.3 | 5 | 6 |
| CompanionComposerPasteUITests | 2 → 2 | 2 | 167.4 | 4 | 1 |
| CompanionContextWindowUITests | 3 → 3 | 3 | 119.5 | 4 | 2 |
| CompanionDispatcherUITests | 21 → 21 | 21 | 1061.6 | 3 | 3 |
| CompanionGrantRequestUITests | 5 → 5 | 5 | 207.5 | 7 | 3 |
| CompanionHardwareKeyboardUITests | 4 → 4 | 4 | 109.1 | 7 | 6 |
| CompanionHelperPresetsUITests | 5 → 5 | 5 | 232.8 | 4 | 4 |
| CompanionHomeSubtitleUITests | 3 → 3 | 0 | 420.0 | 7 | 4 |
| CompanionImageAttachmentUITests | 1 → 1 | 1 | 70.8 | 2 | 5 |
| CompanionKeyboardDismissalUITests | 6 → 6 | 6 | 487.8 | 5 | 8 |
| CompanionLinkedProjectUITests | 5 → 5 | 5 | 126.8 | 7 | 4 |
| CompanionLiveE2ETests | 15 → 15 | 0 | 15.0 | 7 | 8 |
| CompanionLiveSmokeTests | 1 → 1 | 0 | 1.0 | 7 | 8 |
| CompanionLongReplyUITests | 1 → 1 | 1 | 116.6 | 4 | 5 |
| CompanionManagedSpawnUITests | 8 → 8 | 0 | 480.0 | 7 | 6 |
| CompanionMarkdownBlockUITests | 2 → 2 | 2 | 162.4 | 4 | 5 |
| CompanionMarkdownFileUITests | 3 → 3 | 3 | 100.7 | 7 | 4 |
| CompanionNeedsYouActionCardUITests | 2 → 2 | 0 | 360.0 | 7 | 2 |
| CompanionNeedsYouUITests | 4 → 4 | 4 | 57.0 | 7 | 2 |
| CompanionOfflineBannerUITests | 3 → 3 | 0 | 720.0 | 7 | 5 |
| CompanionPermissionMenuUITests | 3 → 3 | 0 | 360.0 | 7 | 5 |
| CompanionPhoneWorkflowTests | 1 → 1 | 0 | 1.0 | 7 | 3 |
| CompanionPinnedDecisionUITests | 5 → 5 | 5 | 254.1 | 7 | 2 |
| CompanionPreviewSmokeTests | 26 → 26 | 26 | 1489.9 | 1, 5, 7 | 1 |
| CompanionProjectInfoUITests | 2 → 2 | 0 | 120.0 | 7 | 8 |
| CompanionProjectPageUITests | 3 → 3 | 0 | 180.0 | 7 | 2 |
| CompanionProviderSmokeTests | 2 → 2 | 0 | 2.0 | 7 | 8 |
| CompanionQuestionUITests | 2 → 2 | 2 | 88.9 | 4 | 7 |
| CompanionQueuedBurstUITests | 1 → 1 | 1 | 22.0 | 4 | 3 |
| CompanionReadingRestoreUITests | 1 → 1 | 1 | 33.0 | 4 | 8 |
| CompanionReadingUITests | 15 → 15 | 14 | 601.1 | 4 | 7 |
| CompanionRecoveryIntegrationUITests | 3 → 3 | 2 | 378.2 | 3 | 6 |
| CompanionReviewUITests | 2 → 2 | 2 | 87.3 | 2 | 6 |
| CompanionSearchUITests | 4 → 4 | 0 | 480.0 | 7 | 5 |
| CompanionSessionModelUITests | 2 → 2 | 2 | 411.2 | 7 | 3 |
| CompanionSlashCommandUITests | 2 → 2 | 2 | 180.1 | 4 | 8 |
| CompanionSpawnVisualUITests | 5 → 5 | 0 | 300.0 | 7 | 1 |
| CompanionTerminalUITests | 8 → 8 | 8 | 304.0 | 2 | 3 |
| CompanionUnicodeFocusUITests | 12 → 12 | 1 | 960.7 | 7 | 4 |
| CompanionWakeFocusUITests | 3 → 3 | 0 | 180.0 | 7 | 6 |
| DiagnosticSettingsTests | 2 → 2 | 1 | 84.3 | 2 | 3 |
| FeedbackDiagnosticsWireUITests | 22 → 22 | 22 | 1171.7 | 6 | 2 |
| FeedbackTriggersUITests | 8 → 8 | 8 | 244.5 | 1 | 5 |
| FramebriarShakeDiagnosticsUITests | 2 → 2 | 2 | 78.3 | 6 | 1 |
| FramebriarShakeUITests | 3 → 3 | 3 | 101.3 | 6 | 3 |
| QA368GrantLayoutUITests | 6 → 6 | 0 | 360.0 | 7 | 7 |

## Coverage check

`python3 -m unittest discover -s scripts/ci/tests` checks the emitted Xcode selections against every source UI test class. The union must equal the full inventory, each class must occur exactly once, unknown classes fail, and method selectors fail so a rename cannot silently remove a method. A synthetic future class verifies catchall coverage. Negative controls reject an omitted class and a duplicated class. Existing matrix, selector and strict-host parser tests remain unchanged.

## First CI observation

Pending the first PR run. Report actual durations for all eight shards and the Release job in the PR; compare Release against the audit median of 8.1 minutes per job (443 seconds for the build step). No speedup is promised before measurement.

## Unsigned Release device SDK

A separate commit switches only the Release job destination from `generic/platform=iOS Simulator` to `generic/platform=iOS`, retaining the Release configuration, project/scheme and `CODE_SIGNING_ALLOWED=NO`. This gains the shipping arm64 iOS device SDK compile with Release optimization and conditional paths, for the configured iPhone and iPad families. It deliberately loses the Release-configuration compile of both simulator slices (arm64 and x86_64). Debug simulator builds, hosted/UI/iPad tests and all existing gate/timeout/retry rules remain unchanged. No archive, signing, launch or install is added.

Validate once locally through FIFO using the actual device destination and unsigned settings. Check effective `Release`, `iphoneos`, `arm64`, `-O`, whole-module compilation, no `DEBUG`, device families 1/2, Mach-O platform iOS and absence of a code signature. The local build is a compile check; the first PR CI run supplies the comparable timing against the audit's 8.1-minute job / 443-second build-step medians.
