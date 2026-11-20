# UI shard balance

## November 19 recovery forecast

The original [#615 run 44622082206](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44622082206) exhausted the unchanged 55-minute catchall allowance before any of its six link methods started. Its last active method was the dark composer-footer test's third iteration, after two `Reading earlier messages` failures. [#616 run 44624001013](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44624001013) recorded the same footer failure and never started the archive-header method. These original failures and missing executions remain red/incomplete evidence.

The declared source inventory grew from the November 16 plan's 56 classes / 303 methods to 79 classes / 440 zero-argument methods on main `cadce0a45`. The catchall grew from 10 classes / 52 methods to 33 classes / 157 methods. The partition-only candidate `dbf7a9ca6` has 441 methods, adding one math-only regression for the original header unread-span gap. The integrated permission correction adds one more geometry-only method: 442 total; its updated forecast is recorded below. It retains every whole class exactly once, future-class catchall coverage, exactly one hosted-unit lane, the unsigned Release device build, and the separate iPad lane. No assertion, skip guard, per-test allowance, retry policy or 55-minute job timeout is changed.

Fifteen lanes are the selected candidate. The coverage test also checks that footer and archive-opening classes use separate explicit lanes while a future `CompanionTextLinkUITests` class runs once in the remaining lane. Static routing is not execution credit: actual hosted first-attempt results for the six links and `testPausedTranscriptArchiveHeaderStillOpensAndClosesAfterStreaming` remain required after integration/rebase.

### Forecast inputs and resource comparison

[The checked-in forecast data](ci-shard-balance-2026-11-19.json) records class estimates, source counts, source log hashes and observations. Of 440 baseline methods, 297 have terminal timing samples in the eight original job logs. A method uses its maximum observed terminal duration for planning; failed/retried outcomes retain their original status and are not counted as independent first passes. Unobserved methods reserve 60 seconds, with larger explicit class floors for partial or multi-appearance flows. The new math-only header regression also reserves 60 seconds.

Each lane reserves 10 minutes for setup/results: original non-hosted job overhead was approximately 6–9 minutes. The sole hosted lane adds 15 minutes for the observed 13m23s XCTest envelope plus 95s Swift Testing. These are forecasts from one run, not new duration gates or guarantees.

| Whole-class lanes | Forecast runner-minutes | Longest forecast job | Margin below 55m |
| --- | ---: | ---: | ---: |
| 14 | 650.9 | 49.5 | 5.5 |
| 15 (selected) | 660.9 | 46.4 | 8.6 |
| 16 | 670.9 | 44.4 | 10.6 |

Fifteen saves 10 runner-minutes against sixteen while retaining 8.6 minutes of forecast margin. Fourteen leaves only 5.5 minutes for timing uncertainty and existing retry behavior. The complete 440-method baseline with eight setup reserves forecasts 589.9 runner-minutes, so the 441-method partition candidate adds 71 minutes: 70 for seven additional setup/result envelopes and one for the new regression. The observed original eight-lane total was 380.7 minutes, but its cancellations omitted many methods; it is not a complete-work cost baseline.

`max-parallel:8` retains the previous eight-lane peak. Account-level capacity and spending settings are unchanged. At the observed 4–5 macOS slots, 660.9 runner-minutes alone imply a best-case 132–165 minutes of wall time, before dependency/queue imbalance; this is not a promised completion time. Nominal UI job allowances total 825 minutes instead of 440; post-cancel cleanup can add time.

Setup reuse already consists of one build-for-testing artifact shared by all UI/iPad jobs. Standard hosted jobs use separate VMs, so reusing a booted simulator across jobs would require different infrastructure; serially combining two ~35-minute UI groups would exceed 55 minutes even after setup reuse. No unmeasured setup saving is claimed. The repository is public and [`macos-26` is a standard GitHub runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), so the documented public standard-runner policy identifies no additional paid compute. Billing, artifact retention/storage and account spending settings are unchanged; any actual budget restriction remains a blocker.

### Partition-only assignment at `dbf7a9ca6`

Forecasts include setup/results and the hosted reserve. The remaining lane includes known small/live-guarded classes and all future classes. The six incoming #615 link methods reserve another 6 minutes there, for 31.7 minutes; their accepted local 26.0 proof does not substitute for hosted 26.5 execution.

| Lane | Declared classes | Methods | Forecast minutes |
| --- | ---: | ---: | ---: |
| UI tests (grants, projects) + unit tests | 5 | 24 | 45.5 |
| UI tests (preview) | 2 | 31 | 44.9 |
| UI tests (feedback diagnostics) | 2 | 24 | 44.6 |
| UI tests (dispatcher, settings) | 4 | 28 | 45.1 |
| UI tests (chips, lifecycle) | 5 | 32 | 45.2 |
| UI tests (decisions, linked home) | 5 | 30 | 45.5 |
| UI tests (home, settings) | 5 | 22 | 45.5 |
| UI tests (footer, desktop scope) | 6 | 23 | 45.5 |
| UI tests (opening, terminal) | 6 | 29 | 45.4 |
| UI tests (launch, native menus) | 6 | 23 | 45.5 |
| UI tests (unicode, reading) | 6 | 50 | 45.0 |
| UI tests (composer, keyboard) | 6 | 32 | 45.5 |
| UI tests (header, catalog) | 6 | 39 | 46.4 |
| UI tests (activity, permissions) | 6 | 23 | 45.4 |
| UI tests (other) | 9 | 31 | 25.7 |

### Original hosted observation

These are actual first workflow-attempt job conclusions, including automatic test retries and cleanup. Test-level failures remain preserved in the logs; a green job alone does not establish every first method attempt passed.

| Original lane | Actual runner-minutes | Conclusion |
| --- | ---: | --- |
| UI tests (other) | 57.2 | cancelled |
| UI tests (preview, project pages) | 53.2 | success |
| UI tests (unicode, home) | 38.8 | success |
| UI tests (feedback, needs you) | 56.3 | cancelled |
| UI tests (search, permissions) | 31.2 | failure |
| UI tests (dispatcher, terminal) | 57.2 | cancelled |
| UI tests (composer, sheets) | 32.2 | success |
| UI tests (reading, grants) + unit tests | 54.5 | failure |

The source repairs target the actual first failures: native-menu targets disappearing from AX after scrolling, an unread header gap after overshoot, and footer gestures crossing the visible transcript into the composer. Menu ownership/order/target/hittability, contiguous full-height text coverage, and footer pixel/OCR/keyboard criteria remain required. Local source and native evidence is scoped below. Final shared repair integration and normal hosted results remain pending; no CI-repaired claim is made by these forecasts.

## Historical November 16 balance (superseded)

The seven-shard catchall timed out in all 13 completed audit runs. Eight whole-class shards preserve every UI class and test method, with the catchall still covering future classes. The 55-minute timeout, retries, test assertions, hosted gate, and iPad job are unchanged. The preview follow diagnostic runs only after failure; it remains best effort and failure artifacts are still uploaded.

### Estimate and limits

Timing input: the 45-run audit in `.clubhouse/agents/qa-artifacts/go-ci-efficiency-audit-2026-11-16.md` (runs 43702476235–43804543773, November 15–16). Its UI logs supply first-attempt elapsed times, taking the median per method across available runs. Repeated attempts within a job do not count as independent samples. Renamed project-page and Needs-you methods retain the corresponding historical sample.

After main #489 adds its second Diagnostics method, the integrated inventory has **56 classes / 303 zero-argument test methods**, including managed-spawn coverage from #454. 218 methods have a matching historical sample. An unsampled method reserves **60 seconds**; known multi-appearance loops reserve 60 seconds per appearance or independently checked viewport. Live-only methods that skip in ordinary PR CI reserve one second for their existing guard, without changing that guard. Each shard adds five minutes for setup/results, and the hosted shard adds another five minutes. These are planning estimates, not guarantees or new gates.

The multi-appearance budgets are: Home subtitle 5, offline banner 10 (5 appearances × Home/Needs you), permission portrait 4, Search 5, recovery banner 5, Unicode created-notice drafts 5, and Needs-you action cards 5. Landscape permission and Project info each launch once and use the ordinary 60-second unsampled budget.

The initial 302-method balance estimated 40.6–41.1 minutes; #489 adds one unsampled Diagnostics method (60 seconds) to Dispatcher/Terminal. Eight shards now estimate **40.6–41.6 minutes**, leaving about 14 minutes under the unchanged timeout. A ninth shard adds another setup job against a saturated 4–5-slot macOS pool; it is deferred until real measurements justify it. After the first PR CI run, record each actual job duration. Revisit nine shards if any exceeds about 48 minutes. CI contention, retries and newly added tests can exceed these estimates.

### Shard counts

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

### Per-class counts and placement

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

### Coverage check

`python3 -m unittest discover -s scripts/ci/tests` checks the emitted Xcode selections against every source UI test class. The union must equal the full inventory, each class must occur exactly once, unknown classes fail, and method selectors fail so a rename cannot silently remove a method. A synthetic future class verifies catchall coverage. Negative controls reject an omitted class and a duplicated class. Existing matrix, selector and strict-host parser tests remain unchanged.

### First CI observation

Pending the first PR run. Report actual durations for all eight shards and the Release job in the PR; compare Release against the audit median of 8.1 minutes per job (443 seconds for the build step). No speedup is promised before measurement.

### Unsigned Release device SDK

A separate commit switches only the Release job destination from `generic/platform=iOS Simulator` to `generic/platform=iOS`, retaining the Release configuration, project/scheme and `CODE_SIGNING_ALLOWED=NO`. This gains the shipping arm64 iOS device SDK compile with Release optimization and conditional paths, for the configured iPhone and iPad families. It deliberately loses the Release-configuration compile of both simulator slices (arm64 and x86_64). Debug simulator builds, hosted/UI/iPad tests and all existing gate/timeout/retry rules remain unchanged. No archive, signing, launch or install is added.

Validate once locally through FIFO using the actual device destination and unsigned settings. Check effective `Release`, `iphoneos`, `arm64`, `-O`, whole-module compilation, no `DEBUG`, device families 1/2, Mach-O platform iOS and absence of a code signature. The local build is a compile check; the first PR CI run supplies the comparable timing against the audit's 8.1-minute job / 443-second build-step medians.

The first local iPhone 17 / iOS 26.0 execution at `dbf7a9ca6` ran all nine selected methods once: seven passed and two failed, with no skipped or expected failures. The header's host tag retained an unread gap from 1.333pt to 10pt; requested 19pt pans included observed 9pt movements and larger jumps, so requested distance is not execution evidence. The successor navigation targets the first unread point at the viewport center and uses the available travel with an 8pt edge inset. It keeps the ten-drag ceiling and connected full-height coverage; arithmetic fixtures do not establish native motion.

The same run's light keyboard-up overflow screenshot contains a real 15-level step at y=434pt in both margin strips, above the existing keyboard exclusion. The conversation background was attached to the shrinking transcript before its bars; the successor places the same background around transcript and bars together. Pixel limits remain 3 for adjacent-row steps and 4 for the surface comparison. Dark overflow never launched after the light failure. Both overflow appearances, the existing footer controls, and the affected header path require new exact-head original verification; the failed run remains preserved.

### Integrated permission correction

The reviewed permission source at `3569f0ba0` is integrated byte-for-byte, including its existing native title/layout guards, measured bounded pans and near/exact-pane-height arithmetic fixtures. Its independent local native verdict covers four methods once on iPhone 17 / iOS 26.0: four passed, six app launches, with the existing draft, full-row and confirmation assertions retained. The native run used no pan below 24pt; sub-24pt touch recognition, hosted compact menus / iOS 26.5 and combined-head CI remain unproved. Earlier permission failures and the held unrun predecessor remain preserved.

[The integrated forecast](ci-shard-balance-integrated-permissions.json) keeps the original partition forecast unchanged as an input. The only inventory addition is one geometry method in permission lane 13: 79 classes / 442 methods, 24 methods in that lane, and another conservative 60 seconds. Selected fifteen-lane aggregate use forecasts 661.9 runner-minutes; the longest lane is now permission at 46.4077 minutes, leaving 8.5923 minutes below 55. The equivalent full 442-method inventory with eight setup reserves forecasts 591.9 minutes, a 70-minute setup difference. Against the complete 440-method baseline at 589.9 minutes, the addition is 72 minutes: 70 for extra setups plus the two new math controls. Peak UI concurrency stays eight; the 55-minute gate, device/iPad/hosted coverage and spending settings stay unchanged. These are forecasts, not actual integrated timing or green CI evidence.

### Verified local successor and final integration gates

The independently reviewed successor `2b03c1e9c` ran the seven affected header/footer methods once: seven passed, no skipped or expected failures, eight actual app launches. The unread-span helper method launches no app; pending and overflow each reached both light and dark. Its Header/Footer test and conversation-view bytes are retained exactly in the integration. On local iPhone 17 / iOS 26.0, independent native-frame reconstruction established connected coverage of all five labels, including the long name and previously incomplete host tag. The final host frame fits fully inside the measured viewport. Requested pan offsets and partial pre-pan log prefixes are not substituted for observed frames. Five focused original pictures were visually inspected; this is not a photographic record of every intervening text line or an all-38-image visual audit.

Independent pixel analysis of all 18 original footer surface pictures reproduced all 36 leading/trailing measurements: maximum guarded adjacent step 2.5834 against the unchanged limit 3, and maximum enabled ordinary surface difference 2.1112 against 4. Overflow reached light and dark; at the former y434 seam, the light strips measured 0.25/0.75 and dark 0.4167/0.1667. Pending/overflow retain their original surface-comparison exemption, and the bottom 40 points above the keyboard retain their original logged-only status. All recorded cleanup checks and the actual 317.293-second after-FIFO bound passed. This acceptance covers local iOS 26.0 native connected-read and sampled footer surfaces; hosted iOS 26.5, physical-device rendering, continuous every-label photographic coverage and integrated CI remain separate. The original nine-method run's two failures remain unchanged evidence.

The integration also carries Settings draft source `b892b9763` and Reading prepend source `faa5bfa0a` (observational child of reviewed readiness source `ff812e463`) byte-for-byte. Settings replaces nil-object predicate waiting with existing-style main-actor polling under the same five-second deadline and retains both the deadline result and final state assertion. Reading reuses the existing eight-second public-frame readiness helper before the unchanged four-pixel prepend assertion; it never waits for the expected bookmark position. Stable wrong positions still fail the original assertion. A retained attachment records the exact marker, before/after positions, displacement and limit, using the same captured post-readiness position as that assertion; elapsed time runs from before the tap through helper completion, including its existing evidence capture. Their independent source reviews passed; focused first native results and final hosted outcomes remain pending. The Settings proof's first configuration attempt stopped before admission/build because a FIFO hash field was a scalar where the worker expects a dictionary; this setup failure remains preserved and supplies no test or build credit.

The final-source forecast retains 79 classes / 442 methods and the fifteen existing placements. It adds six conservative seconds to the Reading lane for the largest additional readiness window (8s instead of the replaced fixed 2s), without changing a runtime gate. The aggregate is now 662.0 runner-minutes; the longest lane remains 46.4077 minutes with 8.5923 minutes below 55. Equivalent full eight-lane use is 592.0 minutes, retaining the 70-minute setup difference; versus the original complete 440-method baseline the difference is 72.1 minutes. These are planning allowances from the original timing inputs, not integrated measurements or a reliability claim. Peak concurrency remains eight and account/spending settings remain unchanged. After the remaining focused gates, one normal hosted integration run must provide actual lane durations and first-attempt outcomes; the rebased link candidate must separately execute all six links and the archive-header method.
