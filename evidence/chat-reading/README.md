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
- CI run [41394968971](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41394968971), on the earlier `944a6e9d587f6d71e517e210e62668e9cc9718a1` with original State ownership, has successful build, Release and package lanes. Its 26.5 resync result is pending; these local commits are intentionally held unpushed until that run finishes.

`rebased-release-profile-samples.json` records three alternating samples per mode at `35f22dd9d69fbb37230e7836602345435de6dfc0`, in the same Release/PROFILE_OPTIMIZED configuration and two-job setup as the earlier comparison. Median timeline work per 200 chunks:

| History | Baseline | Incremental | Prepared rows |
| --- | ---: | ---: | ---: |
| 1,000 | 411.385ms | 358.739ms | 147 → 2 |
| 5,000 | 209.108ms | 4.292ms | 147 → 2 |

The first scenario includes cold Markdown setup; the second uses warmed shared caches. These are folding/window-preparation measurements, not GPU frame times.
