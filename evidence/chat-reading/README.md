# Readable chat evidence

Preview-only screenshots from code commit `d3e5465bd48b33c68d3c3c666542e7522908ba70` on branch `go-chat-reading/readable-chat` (draft PR #217). No desktop is connected in these fixtures. Captured on the dedicated `Go Chat Reading` iPhone 17 Pro simulator, iOS 26.0 (23A343), Xcode 26.0.1 (17A400), on 2026-11-01. The code branch was later rebased directly onto main after #215 merged as `59b75b0`; the captures retain the source provenance above.

| Screenshot | What it verifies |
| --- | --- |
| [Collapsed activity](activity-collapsed.png) | Routine routed runs show counts and senders; the Clubhouse notice remains visible between runs. |
| [Expanded activity](activity-expanded.png) | Sender/part boundaries and exact short content remain available on demand. |
| [Folded failed output](failure-folded.png) | Failed exit status and the final error line remain visible while long output is folded. |
| [Paused near bottom](latest-paused.png) | A slow native drag moves content 14pt, pauses following inside the 16pt band and offers Latest. |
| [Actual bottom with keyboard](latest-bottom-keyboard.png) | Returning/bouncing to the true bottom hides Latest; keyboard/layout changes keep it hidden. Controls stay above the composer. |
| [Running activity with keyboard](streaming-running-keyboard.png) | A compact run keeps its running status/spinner visible; navigation remains above the composer while streaming. |

## Validation

- 919 Swift package tests pass with code coverage. Ratchet passes: Transport 96.37%, Domain 93.98%.
- Debug build-for-testing and Release app build pass.
- `ReadingRegressions.xcresult`: 7/7 pass: all four reading scenarios, LongReply, the existing explored-fold/link preview and queued-join UI. Reading covers history prepend during streaming, keyboard, leave/reopen and tab return. The base hides tabs inside chat, so tab return uses back → Agents → Home → reopen; #211’s direct hidden-chat unmount behavior remains an integration check.
- LongReply was compared with untouched main. On this head, native top/actual-last-row checks pass and three full round trips each take 11.3s; the test completes in 47.9s.
- The wider preview run passed Dispatcher 4/4 and 16/17 preview cases. The remaining fold case used a short drag that could retap the stationary header; after changing it to geometry-directed transcript scrolling, it passes in the 7/7 regression run. Earlier stronger viewport and tiny-scroll assertions found real geometry issues and are now green.
- 9 app-hosted Swift Testing tests and the icon XCTest pass. The isolated rendering/typing/reconnect XCTest also passes. The separate navigation/foreground resync measurement aborts in the runtime deinit path and is tracked under #218; the app-hosted profiling run is not reported as green. The same resync steps pass on main `9441c4362b6359abe6c87ffe9e5815ce0aa5c772`, which does not release this new viewport class. See the #218 follow-up for stack investigation.
- Vendored Framebriar source verification and 66 tests pass; 17 CI-script tests pass; `git diff --check` passes.

## Release folding comparison

`release-profile-samples.json` contains all three alternating before/after samples, with milliseconds and prepared-row counts. Both modes run on code head `3bfbb867ddb8bddb69b15aa86705d24ab92dc636` with `-j 2 -DPROFILE_OPTIMIZED`. The baseline is the prior #215 folding algorithm, retained only in its profiling test. The first 1k scenario includes cold Markdown setup; the following 5k scenario uses those shared caches warm.

| History | Baseline timeline / 200 chunks | Incremental timeline / 200 chunks | Prepared rows |
| --- | ---: | ---: | ---: |
| 1,000 | 401.276ms | 345.448ms | 147 → 2 |
| 5,000 | 201.975ms | 4.195ms | 147 → 2 |

Deterministic tests prove that 200 assistant updates and 200 routine tool updates do not regroup the preceding 5,000 items. Closed activity rows have no Markdown slices or content-link scan, and their detail is absent from the UI hierarchy.

The app-hosted Debug rendering measurement is additional observation, not a comparison with Release: 40 streaming timeline builds total 20.295ms, max 0.827ms; 20 typing timeline builds total 0.371ms, max 0.022ms; two prepared rows. These measure body construction, not GPU frame rate.

## Live follow-up

The orchestrator must run `test9cAgentDispatcherSwitchesAndRealMCPDelivery`: expand the outer activity before checking the short delivery and the long part’s independent inner fold. Exact short labels and `companion-routed-<id>-<index>` remain unchanged. This helper did not run live E2E, touch a phone/shared simulator, publish, merge or restart the host Clubhouse app.

## Post-rebase validation and ownership experiment

Additional local validation at `35f22dd9d69fbb37230e7836602345435de6dfc0`, based directly on main `59b75b0914c6f844ee66e26bb340f419f8d300b8`:

- 949 package tests and the coverage ratchet pass (Transport 96.43%, Domain 94.10%). Debug build-for-testing and Release build pass.
- The viewport is now owned once by the per-target reading bookmark; transient geometry clears on unmount. Removed-host bookmarks, viewports and timeline projections are released. Tests cover reuse, geometry reset and pruning.
- The exact navigation/background/resync/foreground/reopen diagnostic passes four times on iOS 26.0 with bookmark ownership, preserving one viewport identity and request deltas 0/1/1. Restoring only the original `@State` ownership on the same source reproduces the viewport deinit abort. The diagnostic bypassed the 26.0 skip only locally and was removed after the experiment.
- All five selected reading and LongReply UI tests pass after the ownership change. The combined app/UI batch is not green: a separate `CompanionPartExpansion` teardown abort also reproduces on archived main with unchanged production types. Both stacks and steps are recorded in [#218](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6570281162); no general runtime workaround was added.
- CI run [41394968971](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41394968971), on the earlier `944a6e9d587f6d71e517e210e62668e9cc9718a1` with original State ownership, has successful build, Release and package lanes. It later finished with the failed resync assertion/fixture precondition and avatar regression described below; it did not hit the viewport allocator abort on 26.5.

`rebased-release-profile-samples.json` records three alternating samples per mode at `35f22dd9d69fbb37230e7836602345435de6dfc0`, in the same Release/PROFILE_OPTIMIZED configuration and two-job setup as the earlier comparison. Median timeline work per 200 chunks:

| History | Baseline | Incremental | Prepared rows |
| --- | ---: | ---: | ---: |
| 1,000 | 411.385ms | 358.739ms | 147 → 2 |
| 5,000 | 209.108ms | 4.292ms | 147 → 2 |

The first scenario includes cold Markdown setup; the second uses warmed shared caches. These are folding/window-preparation measurements, not GPU frame times.

## Final rebase and CI follow-up

Code source `eae2c2e83c8aabc9ebe83e8394b43f9bccaf07e0`, rebased on main `68a11b2`. #231 was still open at final validation; the three new reading-model owners are classified ARC-only in the code document for its lint integration. No general runtime workaround was added.

- 984 package tests pass with coverage; ratchet passes (Transport 96.43%, Domain 94.08%). Debug build-for-testing and Release app build pass.
- Full `CompanionPreviewSmokeTests`: **18/18 pass**, including actual on-screen known/gone/quick summary avatars while routed detail remains collapsed. [Collapsed sender faces](collapsed-sender-faces.png) show both closed activity rows and the visible Clubhouse notice, captured on the dedicated iOS 26.0 simulator. App source matches the code source above.
- Dispatcher/LongReply/avatar were each repeated three times with no retries: nine passing executions. The subsequent broad reading/tree run passed all reading, LongReply, avatar and tree methods, plus three Dispatcher methods; Copy-menu setup failed once because its target was underneath the dock, despite reporting hittable. [The saved frame](copy-target-under-dock.png) and AX geometry show Reviewer at y=722–804 behind the composer. The geometry correction then passed **three consecutive Copy runs**, each at y=470–552, checking the exact full raw delivery after leaving/reopening the chat. This was a code correction between runs, not an assertion retry.
- Final app-hosted batch is **not green** on 26.0: the avatar fixture's deferred release aborts in `CompanionPartExpansion` → dictionary → `CompanionTranscriptExpansion`, through `StopLookupScope`, matching the earlier main reproduction under #218. The isolated real-composer typing test passes, but its interrupted execution in the full batch is not counted as a pass. Nine Swift Testing cases, icon/rendering measurements complete; resync skips only 26.0. #231 owns the general fix.

Original-head CI at `944a6e9d587f6d71e517e210e62668e9cc9718a1` ran on **iOS 26.5 (23F77), Xcode 26.5 (17F42)**. All four reading UI cases passed on their first attempts, including real keyboard/Latest and streaming/prepend/return. The unit resync measurement ran twice through all phases with reads 0/1/1 and **no viewport deinit abort**, but failed the final resync flag assertion. Attempt three then trapped the test-only fixture retention limit, a different SIGTRAP stack. The revised test awaits in-flight reads, retains exact state/request assertions, removes unnecessary process-lifetime retention and logs loading/error; its new 26.5 result is still required. [#218 result](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6573117868).

Two original CI failure frames, extracted from preview-only XCTest recordings:

- [Copy/Paste editor contains the full raw delivery](ci-paste-editor-complete.png), despite the focused AX-value assertion failing. The new navigation/draft assertion checks the stored model too.
- [LongReply really contains only St](ci-truncated-typing.png). This is not dismissed as a flake. [#234](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/234) tracks the same symptom observed without reading changes in #213. Local main and reading controls each pass three times with all ten UIKit insertions, binding lengths 1…10 and no focus loss; the reading branch also retains 52 paced +100 rapid characters during stream/layout updates. A hosted main control aborts before typing in #218's DecisionQueue path and proves nothing about input. Preview-only numeric tracing and the unchanged full-string assertion run in the next 26.5 CI attempt. The cause of the failed input is still unknown.

`final-release-profile-samples.json`: same source/configuration, three alternating samples per mode, after local UI testing stopped. Medians per 200 chunks:

| History | Baseline | Incremental | Prepared rows |
| --- | ---: | ---: | ---: |
| 1,000 | 366.240ms | 315.424ms | 147 → 2 |
| 5,000 | 187.083ms | 3.774ms | 147 → 2 |

Cold Markdown in the first case and warmed shared caches in the second remain as documented above. This measures timeline folding/window preparation, not GPU frame times.
