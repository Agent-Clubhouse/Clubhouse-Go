# Reading first-paint seeding (#582): proposal before code

Base: main `77b24899`. This change follows #569 product A; its correction and original six-point assertions remain unchanged.

The current transcript starts with `followLatest=true`, `atLatest=true`, the initial window limit and a bottom-edge `ScrollPosition`. The history task applies the saved bookmark after the first body. A reopened paused chat can therefore show the latest window before restoration.

QA approved the direction with conditions: seed once per actual transcript opening; do not reset during reload/resync/streaming; show the saved entry in the first paused frame even after earlier history was expanded; hand provisional Latest state to live geometry without saving or cancelling; preserve composer State and per-target identity. First semantic paint does not claim layout-dependent six-point restoration is already complete.

## Revision after QA direction review (before code)

Use the simpler transcript-child scope, not the keyed cache. Extract the existing timeline builder and reading-only helpers into a private `CompanionConversationTranscript` View. Its four State values (plus existing reading-only debug/control State) live inside the subtree that is already removed by `isVisible=false`. Parent composer/draft/header State stays in CompanionConversationView. Give the child `.id(target)` so a same-identity parent target change cannot share reading State. The initializer copies only semantic values from the already Store-owned bookmark; constructing/discarding a child View creates no holder, service, task, viewport or dependency. SwiftUI retains its original State on ordinary parent initializer/body recreation. Existing onDisappear/managed-visibility geometry authorities remain exactly as today; no cache or manual State reset required.

Pass the existing header and entry builders as ViewBuilder closures and the existing composer-dismiss action, rather than moving the composer or changing row/menu logic. This is a mechanical extraction first; final diff will separate moved code from behavioural edits. The same-target historyRevision task, including window widening and stale-geometry rejection, remains unchanged. No historyRevision key, no reseeding during reload/resync/streaming. Explicit hosted controls cover reload while paused/open and while hidden, with exactly one new seed on re-show.

For a paused bookmark with an entry ID, seed ScrollPosition(id: saved.entryID, anchor:.top), using the SDK's public initializer, with scrollTargetLayout on the existing stack of entries. The latest path retains the bottom-edge seed; the existing missing-entry/old-session fallback stays with the unchanged history task. First-frame evidence must cover a bookmark below the loaded window's first row (earlier messages expanded), proving ID positioning rather than assuming the window starts at the bookmark. Measure the first rendered bookmark's distance and label this row-level semantic paint, not six-point final restoration. Verify alias/grouped-entry IDs before deciding whether a tiny canonical-ID adapter is needed; do not add guessed offsets or alter window bounds just to pass.

Allow Latest from the paused semantic seed until the first nonempty live metrics arrive, then use actual geometry immediately. This provisional control state must neither save a position nor cancel restoration. All post-layout six-point/prefix/cancellation and scrolling assertions remain unchanged. New scrollTargetLayout must be covered by the existing gestures, native top, rotation, streaming and Latest controls, as well as first-frame measurements. No new actor-holder teardown policy is necessary if the extraction remains values/closures only; check compiled gate regardless.

Please confirm this revised, narrower product shape before implementation; the original cache design is superseded.

## Evidence required before acceptance

- Record first frames for fresh/latest, paused remount, retained tab, destination reopen, target switch and history/session replacement. Start recording before the mount action. Record first-frame distance, not only eventual readiness.
- Hosted actual-view lifetime checks: no dependency construction from discarded initializers, stable State across parent re-evaluation, separate targets, expanded window retained. Reload while open must not reseed; reload while hidden must seed exactly once on return.
- Latest/paused controls across two chats, keyboard and draft, normal streaming, alias/grouped and missing bookmark controls.
- Original six-point Reading checks, prefix-trim regression, timeout/real drag, value/hidden suites, original ordered C23/C50, cold Reading, Reading on SE.
- Same 16-step scroll CPU overlay on main and head. If counts differ, add the live Home comparison. No unmeasured claim of native gesture CPU cost.
- Exact-head build/deinit/policy and fresh combined coverage on current main at run time. Device acceptance remains deferred.

No heavy ticket or simulator is queued while beta.3 phone/archive/live E2E owns the host. All later admission uses the normal FIFO, global measured guard and one-simulator rule.

## Implementation inventory and review conditions

The mechanical extraction is commit `ef3d56d7`. Moved values: `followLatest`, `atLatest`, `readingScrollPosition`, `shownEntries`, `nextAssistantMessageID`, DEBUG `followPauseCount`/`followSawDeceleration`, and the same text-size-scaled `navigationClearance`. The child's Reduce Motion and Dynamic Type environments have the same keys. Row/header builders, composer memory/focus/dismissal counters, keyboard/header state, and `decisionChatJump` remain in the parent. The parent still clears shared geometry on managed visibility=false; the child receives the current visibility-management flag and keeps the existing late-onDisappear protection. It invokes the parent's existing dismiss action. No new actor-owned lifetime is introduced.

The initial ID is resolved only for a row the existing paused-window retention rule includes. A grouped-question alias uses `CompanionTimelineEntry.jumpTarget`; ordinary and sliced IDs remain exact. Unknown/deleted/session-old IDs and unrealised aliases use an explicit bottom-edge fallback. The saved semantic bookmark is unchanged, and the existing history task validates/removes unavailable IDs as before. The first numeric restore must replace the initial identity request; the DEBUG opening probe and hosted assertion check that `ScrollPosition.viewID` is nil after that scroll.

QA accepted a DEBUG-only optional Show-in-chat request input for hosted routing proof. It feeds the original parent-owned request State and the same child task, with no release hook. Main does not clear that request after use: it runs once per opening and per new request UUID. Preserve and document this policy here; no extra request-clearing fix is included. The hosted test checks hidden/new-request/parent-recreation/re-reveal cardinality and clears its hook during teardown.

The recording fixture is opt-in, socket-free, and starts unmounted so external video begins before the mount command. Its 100ms close/reopen interval is an explicit fixture action, not a hidden/delayed product paint. Its first public AX observation may occur after first paint and is labelled accordingly; only the recording establishes the first rendered frame. Body/geometry/history/scroll probes are observation-only DEBUG callbacks and reset in teardown. They contain IDs and numbers, not transcript/draft text. Full keyboard/draft and six-point controls remain separate from the semantic first-frame claim.
