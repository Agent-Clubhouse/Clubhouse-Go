# Readable mobile chat

## Rules and desktop parity (#2664)

The domain folding model groups chronological adjacent routine tool calls. Routed messages break tool runs and remain individual message rows, with their sender and contents visible. Failed tools, nonzero structured terminal exit codes, pending permissions, tool images, own messages, structured questions, notices, and active/uncertain delivery or queue states also break runs. A failure/permission update splits a run; resolving it can rejoin it. The first fragment is the stable key. No text search guesses failures. Finished empty assistant messages are carried uncounted only between countable tools; live empty replies stay visible.

Framebriar **1c74d5b8** reported helper replies hidden behind avatar/count cards. Go now follows desktop main's `MessageBlocks.tsx` `SentPart` separation: each routed part has a small sender face/name and its own visible body. This applies to known, gone and legacy senders because routed metadata does not reliably distinguish helpers from other agents. Long parts start expanded on mobile; the reader can explicitly collapse them with their caption, and that choice survives refresh/navigation. Clubhouse `fromClubhouse` parts remain visible as plain caption text with no bubble or visible steer label; delivery metadata remains available to VoiceOver. Lifecycle notices use a leading caption without the information icon or extra vertical padding. User-authored messages retain their existing presentation.

Named mobile parity exceptions:

- **Single-item tool activity:** one routine tool also gets a compact expandable row; desktop groups runs of at least two.
- **Long routed messages:** text starts expanded, while desktop initially collapses long messages. Mobile readers should see the helper's contents without first opening a card.

Running status remains visible in the tool summary. Opening a run exposes its ordered tools, outputs and content links. Closed tool runs create no detail views, content-link scans, slices or Markdown. Failed tool rows always show status and exit code; output up to six nonempty lines starts open, longer output starts folded with its last line visible. A saved user toggle wins.

Existing wire subagent IDs are preserved through streamed chunks and tool updates. Go labels their inline text as helper activity and splits tool runs at sender changes; it does not implement the desktop full-capability subagent card.

Jump stops are nonempty user-facing assistant replies (including streaming replies, slash output and projected plan documents) and structured questions. Own messages, tools, system rows and routed traffic are excluded. Previous selects the current stop when its top is above the viewport; otherwise the prior stop. Next selects the first stop below. Controls have VoiceOver labels and sit within the transcript above its composer.

Reading bookmarks retain the first intersecting entry key plus offset, shown history window, and following choice per target. The near-bottom band is 16 points; an upward gesture pauses following even inside it. Reaching the true bottom (within 1 point) resumes following and hides Latest, including after keyboard/layout changes. SwiftUI’s available container height excludes composer/keyboard insets; the adapter converts it to full bounds before calculating the range. The Latest target includes the transcript’s bottom padding. Upward motion is accumulated across fractional samples, including when the first geometry callback precedes the interaction phase. Bookmarks are session-memory state, like expansion choices, not cross-launch storage. Each target bookmark owns one viewport geometry holder, avoiding discarded allocations when SwiftUI recreates the view. Geometry clears on unmount, while the bookmark survives. Removed-host bookmarks and derived timeline projections are pruned together. #211's hidden-tab unmounting remains separate; its bookmark changes will need reconciliation with this stronger entry-relative bookmark.

Full history loads and replay snapshots advance a separate history revision; streamed chunks do not. Geometry can pause following or save a bookmark only after that loaded revision has been anchored by its mounted transcript. This excludes the offset reset between partial live items and full history even when the reported content height is unchanged. Followers re-anchor to latest; an existing reader keeps the saved entry and offset through the replacement.

Native status-bar top requests pause following synchronously in UIKit's `scrollViewShouldScrollToTop`, before the first SwiftUI geometry sample. Until top arrives, pending bottom geometry and entry restoration cannot reclaim the viewport. The saved target is the top of the currently shown history window; older pages remain behind Show earlier messages. A new transcript touch, drag or explicit navigation takes ownership from the native jump. The delegate adapter observes only its enclosing transcript scroll view, preserves the original delegate's veto and forwards its other callbacks.

The #252 deterministic hosted control fails on unchanged main because following is still enabled immediately after that native request. Its synthetic animation nevertheless reaches top, and the unchanged named UI test passed 10/10 on each fresh iPhone 17 and iPad Pro 11-inch (M4), iOS 26.0. Closing the pre-geometry window is not yet proof that it caused the reported on-device animation cancellation; #252 remains open for device confirmation.

## Test plan

- Domain: mixed runs/order/keys; all tool kinds; running status; failure/permission split and rejoin; tool image boundary; short/long routed rows; helper questions/notices; pending queues and failed/uncertain delivery; attachment counts; no Markdown slices or links for collapsed traffic; expansion persistence; structured terminal exit codes; assistant/question navigation boundaries; bookmark prepend/resize; Latest drag/keyboard/bounce geometry.
- UI (isolated preview, owned simulator): collapsed detail absence, expansion and Copy; sender folds survive refresh/navigation; viewport holds during streaming, keyboard, history prepend and tab/navigation return; previous/next and Latest; existing long reply scrolling; app, preview and Dispatcher suites.
- Validation: low-job package coverage, coverage ratchet, Debug/Release builds, lag branch benchmark before/after. Live test9c is edited but must be run by the orchestrator, never by this helper.

## Live E2E expectation changes

`test9cAgentDispatcherSwitchesAndRealMCPDelivery`: routed deliveries are now visible without expanding an activity row. Long parts start expanded and retain their explicit caption toggle. `companion-routed-<id>-<index>` and exact open short-part labels remain unchanged. A long routed part retains its independent inner fold. No live test was run during this work.

## Incremental projection and local measurements

A per-target derived-row cache uses conversation revisions rather than comparing the whole item array on each UI update. It retains no source item array. Assistant chunks replace one hard-boundary row; routine tool chunks replace only their existing run. Attention, image, owner and other structural changes invalidate folding. Snapshots release obsolete cached payloads immediately. Deterministic tests cover 200 assistant chunks and 200 tool chunks against 5,000 prior items, with no history regrouping during those updates.

Final Release profiling at `eae2c2e83c8aabc9ebe83e8394b43f9bccaf07e0` (main `68a11b2` base), `-j 2 -DPROFILE_OPTIMIZED`, three alternating runs of each mode on the same machine/head:

| History items | Prior #215 folding, timeline / 200 chunks | Incremental mobile projection / 200 chunks | Prepared rows, prior → mobile |
| --- | ---: | ---: | ---: |
| 1,000 | 366.240 ms | 315.424 ms | 147 → 2 |
| 5,000 | 187.083 ms | 3.774 ms | 147 → 2 |

These are medians from the existing lag benchmark; [all alternating samples](https://github.com/Agent-Clubhouse/Clubhouse-Go/blob/379ee7aafccdaf3d5ee4894fa88fdda693930a1e/evidence/chat-reading/final-release-profile-samples.json) are recorded on the separate evidence branch. Its first 1,000-item scenario includes cold reply Markdown setup; the 5,000-item scenario follows with those shared caches warm. Timings measure folding plus window preparation, with projector/store timings recorded separately. The `baseline` mode is the pre-reading #215 folding algorithm retained only in the profiling test, so configuration, source head and workload are identical. Neither mode constructs hidden SwiftUI detail; the mobile domain/UI regressions additionally verify closed activity has no Markdown slices, content-link scan or routed content view.

Reproduce after compiling once:

```sh
swift test -c release -j 2 -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
CLUBHOUSE_PROFILE_LONG_CHAT=1 CLUBHOUSE_PROFILE_FOLD=baseline swift test -c release --skip-build -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
CLUBHOUSE_PROFILE_LONG_CHAT=1 CLUBHOUSE_PROFILE_FOLD=incremental swift test -c release --skip-build -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
```

Optional `permission_request.toolCallId` is preserved as `approval.toolCallID`. Pending, submitting and uncertain approvals keep the linked tool visible/open even when its tool status still says in progress; missing IDs cause no guessed association. Structured terminal exit codes and message/tool subagent IDs are the only other small projector extractions in this change. Projector indexing and publication remain owned by #215.

## Validation evidence and runtime gate

Latest preview-only screenshots, CI failure frames and raw Release samples are committed separately at [379ee7aafccdaf3d5ee4894fa88fdda693930a1e](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/379ee7aafccdaf3d5ee4894fa88fdda693930a1e/evidence/chat-reading), with source provenance per capture. At main-68a11b2 rebase: 984 package tests and coverage ratchet pass (Transport 96.43%, Domain 94.08%), Debug/Release builds pass, all 18 preview smoke tests pass, all four reading cases and LongReply pass, both tree cases pass. The broad UI run exposed a Copy gesture under the dock; after a geometry correction its exact draft-persistence assertion passes three consecutive runs, with the other three Dispatcher cases already passing. The app-hosted batch remains failed by #218's existing expansion teardown; individual completed methods are not used to call that batch green. The base hides chat tabs, so direct #211 hidden-view unmounting still needs an integration check. Earlier captures/results are preserved with their original source SHAs in the evidence README.

The original `@State` viewport holder aborts on iOS 26.0 through `TaskLocal::StopLookupScope` → `swift_task_deinitOnExecutorImpl` → `CompanionReadingViewport` deinit. A controlled same-source comparison now identifies a lifetime-design trigger: the bookmark-owned viewport passes four exact navigation/background/resync/foreground/reopen measurements, with stable identity and request deltas 0/1/1; restoring the eager State holder reproduces the abort. The earlier small-holder probe did not count allocations and was not sufficient evidence. [#218 records the controlled experiment](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6570150488). No actor isolation, unsafe memory or deinit workaround was added.

After the ownership fix, 949 package tests, coverage (Transport 96.43%, Domain 94.10%), Debug/Release builds and all five selected reading/LongReply UI cases pass. The combined app/UI batch still aborts in a separate existing `CompanionPartExpansion` teardown; the same stack reproduces on archived main with unchanged production types. [That general runtime investigation remains in #218](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6570281162). The full app batch is not reported as green.

`CompanionChatResyncViewTests` skips only iOS 26.0, with #218 in the reason, and is verified in the unit-test UI shard. Original-head CI [41394968971](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41394968971/job/125119032199) actually ran it on iOS 26.5 (23F77), Xcode 26.5 (17F42). Two attempts reached all phases with request deltas 0/1/1 and no viewport deinit abort, but failed the final resync-state assertion. Attempt three hit the test-only eight-object retention precondition, a SIGTRAP with a different stack. The measurement was not green. The revised test removes that process-lifetime retention, waits with a bounded deadline for in-flight history to finish, asserts request counts as well as final state, and logs loading/error state; its 26.5 rerun remains required.

The old avatar smoke assertion caught a real product regression: closed activity omitted sender faces. Summary avatars now keep known/gone/quick identities accessible without building routed bodies. The strengthened UI test verifies exact labels, actual on-screen faces and collapsed detail. For Copy, the original CI failure video shows the full delivery in the editor despite a failed focused-field value predicate; the new exact check leaves/reopens the conversation to test the stored draft too. A separate local menu failure was traced to a message at y=722–804 behind the composer dock despite `isHittable`; the test now uses entry geometry to bring it inside the transcript before pressing.

LongReply's truncated `Still here` → `St` is independently tracked in [#234](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/234), also observed on #213 without reading changes. It is not dismissed as a flake. Both this branch and main `68a11b2` pass three local LongReply controls with all ten UIKit insertions and binding updates, focus retained. A real-composer hosted control on this branch retains 52 paced and 100 rapid characters during streaming/layout, with stable input identity/focus. The hosted main control aborts before typing in #218's existing DecisionQueue path and proves nothing about typing. DEBUG-only numeric tracing, enabled only by the preview test argument plus environment flag, distinguishes missing input deliveries, focus loss and binding rollback on the next 26.5 run. Full text assertions remain, with no missing-character retype. No cause has yet been proved for the failing 26.5 input.

## Reading-owner deinit classification for #231 integration

All three reading-owned classes are `arc_only` under #231's reviewed policy: `CompanionReadingBookmark` owns only a reading-position value, Bool and its viewport; `CompanionReadingViewport` owns only gesture/metrics values, String-to-Double-range geometry, numbers and flags; `CompanionTimelineProjection` owns value rows/indices/counters and UUIDs. Rows contain only message/tool/question/approval values and immutable Data-backed image bytes, with no UIKit view/image, callback or injected service ownership. Each constructor is internal to the per-target store/bookmark. Apply #231's empty `nonisolated deinit` and add these entries/source fingerprints when its policy lands; do not infer UI affinity from these class names. No root/decision-queue lifetime changes belong to this PR.

The Store's added bookmark/projection dictionaries retain only these reviewed ARC-only owners. Existing expansion changes add keyed lookup without UI/callback fields; wire/model additions are optional String/Int values, and preview additions are Boolean fixture flags. Re-review the corresponding full-source fingerprints when #231's policy is merged; the policy/lint files are absent from the current main-68a11b2 base.
