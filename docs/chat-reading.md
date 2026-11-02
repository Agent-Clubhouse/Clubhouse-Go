# Readable mobile chat

## Rules and desktop parity (#2664)

The domain folding model groups chronological adjacent routine tool calls and routed parts. Failed tools, nonzero structured terminal exit codes, pending permissions, tool images, own messages, structured questions, notices, and active/uncertain delivery or queue states break runs. A failure/permission update splits a run; resolving it can rejoin it. The first fragment is the stable key. No text search guesses failures. `fromClubhouse` always stays visible, including routine “helper started” notices, until severity is reliable. `[QUESTION FROM HELPER:` parts stay visible too. System/thought rows remain boundaries because Go has no thought discriminator. Finished empty assistant messages are carried uncounted only between countable items; live empty replies stay visible. There was no compaction-specific notice coalescing in Go to preserve.

Named mobile parity exceptions:

- **All routed text:** routine parts collapse regardless of length; desktop shows short single-line parts.
- **Single-item activity:** one routine item also gets a compact expandable row; desktop groups runs of at least two.
- **Attachment summary:** routed attachment counts appear in the summary; tool images remain visible outside runs.

Running status remains visible in the summary. Opening a run exposes its ordered children, existing sender/avatar metadata, Copy message, tool outputs and content links. Existing per-part folds stay independent; expansion choices survive transcript refresh and navigation in the per-target store. Closed runs create no detail views, content-link scans, slices or Markdown. Failed tool rows always show status and exit code; output up to six nonempty lines starts open, longer output starts folded with its last line visible. A saved user toggle wins.

Existing wire subagent IDs are preserved through streamed chunks and tool updates. Go labels their inline text as helper activity and splits tool runs at sender changes; it does not implement the desktop full-capability subagent card.

Jump stops are nonempty user-facing assistant replies (including streaming replies, slash output and projected plan documents) and structured questions. Own messages, tools, system rows and routed traffic are excluded. Previous selects the current stop when its top is above the viewport; otherwise the prior stop. Next selects the first stop below. Controls have VoiceOver labels and sit within the transcript above its composer.

Reading bookmarks retain the first intersecting entry key plus offset, shown history window, and following choice per target. The near-bottom band is 16 points; an upward gesture pauses following even inside it. Reaching the true bottom (within 1 point) resumes following and hides Latest, including after keyboard/layout changes. SwiftUI’s available container height excludes composer/keyboard insets; the adapter converts it to full bounds before calculating the range. The Latest target includes the transcript’s bottom padding. Upward motion is accumulated across fractional samples, including when the first geometry callback precedes the interaction phase. Bookmarks are session-memory state, like expansion choices, not cross-launch storage. Each target bookmark owns one viewport geometry holder, avoiding discarded allocations when SwiftUI recreates the view. Geometry clears on unmount, while the bookmark survives. Removed-host bookmarks and derived timeline projections are pruned together. #211's hidden-tab unmounting remains separate; its bookmark changes will need reconciliation with this stronger entry-relative bookmark.

## Test plan

- Domain: mixed runs/order/keys; all tool kinds; running status; failure/permission split and rejoin; tool image boundary; short/long routed rows; helper questions/notices; pending queues and failed/uncertain delivery; attachment counts; no Markdown slices or links for collapsed traffic; expansion persistence; structured terminal exit codes; assistant/question navigation boundaries; bookmark prepend/resize; Latest drag/keyboard/bounce geometry.
- UI (isolated preview, owned simulator): collapsed detail absence, expansion and Copy; sender folds survive refresh/navigation; viewport holds during streaming, keyboard, history prepend and tab/navigation return; previous/next and Latest; existing long reply scrolling; app, preview and Dispatcher suites.
- Validation: low-job package coverage, coverage ratchet, Debug/Release builds, lag branch benchmark before/after. Live test9c is edited but must be run by the orchestrator, never by this helper.

## Live E2E expectation changes

`test9cAgentDispatcherSwitchesAndRealMCPDelivery`: expand the containing activity row before looking for the short real delivery and before checking the long-part fold. `companion-routed-<id>-<index>` and exact open short-part labels remain unchanged. A long routed part retains its independent inner fold. No live test was run during this work.

## Incremental projection and local measurements

A per-target derived-row cache uses conversation revisions rather than comparing the whole item array on each UI update. It retains no source item array. Assistant chunks replace one hard-boundary row; routine tool chunks replace only their existing run. Attention, image, owner and other structural changes invalidate folding. Snapshots release obsolete cached payloads immediately. Deterministic tests cover 200 assistant chunks and 200 tool chunks against 5,000 prior items, with no history regrouping during those updates.

Post-rebase Release profiling at `35f22dd9d69fbb37230e7836602345435de6dfc0`, `-j 2 -DPROFILE_OPTIMIZED`, three alternating runs of each mode on the same machine/head:

| History items | Prior #215 folding, timeline / 200 chunks | Incremental mobile projection / 200 chunks | Prepared rows, prior → mobile |
| --- | ---: | ---: | ---: |
| 1,000 | 411.385 ms | 358.739 ms | 147 → 2 |
| 5,000 | 209.108 ms | 4.292 ms | 147 → 2 |

These are medians from the existing lag benchmark; [all alternating samples](https://github.com/Agent-Clubhouse/Clubhouse-Go/blob/90d79ca557e002447a90d98f3fdd9d7e0f74f0e9/evidence/chat-reading/rebased-release-profile-samples.json) are recorded on the separate evidence branch. Its first 1,000-item scenario includes cold reply Markdown setup; the 5,000-item scenario follows with those shared caches warm. Timings measure folding plus window preparation, with projector/store timings recorded separately. The `baseline` mode is the pre-reading #215 folding algorithm retained only in the profiling test, so configuration, source head and workload are identical. Neither mode constructs hidden SwiftUI detail; the mobile domain/UI regressions additionally verify closed activity has no Markdown slices, content-link scan or routed content view.

Reproduce after compiling once:

```sh
swift test -c release -j 2 -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
CLUBHOUSE_PROFILE_LONG_CHAT=1 CLUBHOUSE_PROFILE_FOLD=baseline swift test -c release --skip-build -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
CLUBHOUSE_PROFILE_LONG_CHAT=1 CLUBHOUSE_PROFILE_FOLD=incremental swift test -c release --skip-build -Xswiftc -DPROFILE_OPTIMIZED --filter CompanionLongChatPerformanceTests
```

Optional `permission_request.toolCallId` is preserved as `approval.toolCallID`. Pending, submitting and uncertain approvals keep the linked tool visible/open even when its tool status still says in progress; missing IDs cause no guessed association. Structured terminal exit codes and message/tool subagent IDs are the only other small projector extractions in this change. Projector indexing and publication remain owned by #215.

## Validation evidence and runtime gate

Preview-only screenshots and raw Release samples are committed separately at [93502660397ac95b5a43c1b6e469dee7ceb7b927](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/93502660397ac95b5a43c1b6e469dee7ceb7b927/evidence/chat-reading), from feature code `d3e5465bd48b33c68d3c3c666542e7522908ba70`. All seven affected UI regressions pass, including native long-reply top/bottom, actual tiny-scroll pause/bounce/keyboard, prepend while streaming, return, failed output, expansion and queued joins. Debug and Release builds, 919 coverage tests and the coverage ratchet pass. The base hides chat tabs, so direct #211 hidden-view unmounting still needs an integration check.

The original `@State` viewport holder aborts on iOS 26.0 through `TaskLocal::StopLookupScope` → `swift_task_deinitOnExecutorImpl` → `CompanionReadingViewport` deinit. A controlled same-source comparison now identifies a lifetime-design trigger: the bookmark-owned viewport passes four exact navigation/background/resync/foreground/reopen measurements, with stable identity and request deltas 0/1/1; restoring the eager State holder reproduces the abort. The earlier small-holder probe did not count allocations and was not sufficient evidence. [#218 records the controlled experiment](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6570150488). No actor isolation, unsafe memory or deinit workaround was added.

After the ownership fix, 949 package tests, coverage (Transport 96.43%, Domain 94.10%), Debug/Release builds and all five selected reading/LongReply UI cases pass. The combined app/UI batch still aborts in a separate existing `CompanionPartExpansion` teardown; the same stack reproduces on archived main with unchanged production types. [That general runtime investigation remains in #218](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/218#issuecomment-6570281162). The full app batch is not reported as green.

`CompanionChatResyncViewTests` skips only on the affected iOS 26.0 runtime, with #218 in its message. It runs on later runtimes, including CI's expected iOS 26.5. The generated **UI tests (sheets, review, terminal) + unit tests** shard includes `-only-testing:ClubhouseGoTests`, with no skip for this class; the workflow passes that selection directly and rejects app tests that pass only after a retry. The workflow chooses the newest installed runtime rather than pinning 26.5, so confirm the actual CI runtime and resync result in [run 41394968971](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41394968971), which remains on the original State ownership at `944a6e9d587f6d71e517e210e62668e9cc9718a1`. The ownership and pruning commits are held locally until that run finishes. An abort on 26.5 blocks #217 and requires its stack.
