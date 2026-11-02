# Desktop #2732 compatibility audit

Desktop head **ba560869b10bddee3f1feab309e13ce088de4d40**, based on
**e3952f3877bfb1ed7fd021493c9f03e51f93e2dc**. Head rechecked unchanged.
Go **6c32b12** (147) and **be3272103f4232a4bb8e59e480946b54a0ec68d7**
(origin/main at final run). The first main run was 35a9dae; the subsequent
be327210 changes only fixtures and contract tests, and the focused audit was
rerun there. All audit cases passed on both versions. No production Go edits.

## Results

| Item | Both Go versions | Proof |
| --- | --- | --- |
| Critical event over 16 MiB, fresh reconnect snapshot | **Safe with a new checkpoint at/past the event.** One reconnect, no gap; replay cursors `[8]`, then `[9,9,9]` across repeated equal snapshots. A subsequent real server event at global 10 reaches chat session cursor 17. | `criticalOversizeReconnectAndGapAdoptFreshCheckpoint(false)` |
| Critical event, held old checkpoint before gap | **Safe only once a fresh first snapshot follows.** Two reconnects, one gap; replay `[8]`, `[8]`, `[9,9,9]`. Gap `lastSeq:9` is ignored; the next snapshot supplies cursor 9. Existing cached permission/question/queue remain; explicit history refresh clears resync. | `criticalOversizeReconnectAndGapAdoptFreshCheckpoint(true)` |
| Older replay cursor | **Same restriction.** Cursor8 → gap9 closes once → fresh snapshot9 → clean replay9. Repeated stale snapshot8 is unsafe: three stale checkpoints produced three gaps/reconnects; fresh9 stopped them. | `olderCursorBeforeCheckpointGapNeedsOneFreshSnapshot`, `repeatedStaleSnapshotsRepeatGapsUntilCheckpointAdvances` |
| Omitted text, final fits | **Safe.** `frame:omitted` advances the global cursor without a chat row. Fitting ~3 MiB final replaces the prefix once, no duplicate, no streaming flag. | `omittedTextFitsFinalOrEndsPrefixThenHistoryReplacesOnce` |
| Omitted final, then turn ended | **No stuck state; presentation is incomplete until refresh.** The old `Visible prefix` remains, nonstreaming, status idle, with no live omission warning. Real `/chat` preview (249135 UTF-8 bytes, warning within its text) replaces it once. Real history stub removes the prefix and shows `Something here is too large to show. It's on the desktop.` once. A second refresh adds nothing. | Same test, preview and stub arguments |
| Canvas marker, project and global | **Safe to ignore.** Both markers leave chat, existing pending cards, queue, cursor and connected state unchanged; Go has no canvas model to erase. | `canvasMarkersAreIgnoredWithoutTouchingState` |

Go source references, **147 / main**:

- Gap ignored and new first snapshot adopted: `Annex/Annex/Transport/AnnexReplay.swift:43,47` / `:49,53`.
- Gap causes disconnect and snapshot requests replay from cursor: `Annex/Annex/Transport/AnnexTransport.swift:519,532` / `:582,606`.
- Service marks conversations for resync: `Annex/Annex/Companion/Adapters/CompanionLiveService.swift:678` / `:788`.
- Conversation view requests history on recovered connection: `Annex/Annex/Companion/Views/CompanionConversationView.swift:120` / `:170`. This package harness performs that force-load explicitly; it does not run SwiftUI.
- Final replaces chunks; turn ends streams: `Annex/Annex/Companion/Adapters/CompanionChatProjector.swift:115,71` / `:127,88`.
- History replaces timeline at equal/newer sequence: `Annex/Annex/Companion/Domain/CompanionStore.swift:229` / `:255`.
- Unknown canvas/omission frames ignored by service: `Annex/Annex/Companion/Adapters/CompanionLiveService.swift:745` / `:874`. Global transport cursor still consumes the omission seq.

Desktop source at the stated head:

- `src/main/services/annex-server.ts:3835`: real mobile replay handler rejects the oversized retained event with a gap. Existing server tests also pass for ordinary replay, fresh checkpoint and whole 9 MiB replay.
- `:4347`: each new socket captures the replay buffer's current last seq; `:1407` uses that held cursor for the first snapshot. This is the essential compatibility guarantee; Go does **not** advance using the gap's advertised cursor.
- `:1496`: allowlisted text omission; `:1146`: canvas marker.
- `src/main/services/annex-chat-pages.ts:160`: real history projection and stub generation.

## Counts

`go-147.log` and `go-main.log` record each HTTP route count, replay cursor list,
socket count and gap count. Representative final runs:

| Scenario | 147 sockets / gaps / chat reads | Main sockets / gaps / chat reads |
| --- | --- | --- |
| Oversize → fresh | 2 / 0 / 4 | 2 / 0 / 3 |
| Oversize → held old → gap → fresh | 3 / 1 / 4 | 3 / 1 / 3 |
| Old cursor → gap → fresh | 2 / 1 / 2 | 2 / 1 / 2 |

Chat reads include initial loading and the explicitly driven post-resync refresh.
Catalog/capability read counts vary with cancellation of concurrent refreshes;
the logs retain the actual counts. Reconnect delays use the production manual
clock, not wall-time cadence measurements. No new cap or timeout claims.

## Evidence and limitations

`capture-server.patch` adds a capture test to the **real** desktop server unit
harness at the pinned head. The production broadcaster, omission checks, replay
buffer/handler, first-snapshot builder and history page projector execute; disk,
agent runtime and WebSocket endpoints use that harness's mocks. The committed
canonical `frames-over-limit.json` is included. Captured frames and pages are
gzip-compressed in `captures/`, with decoded byte counts and SHA256 in `SOURCE.json`.
The oversized critical question is 17 MiB; capture contains its real bytes.

On Go, the harness injects the earlier measured URLSession cap failure at the
`AnnexIO` leaf: 147 receives `NSPOSIXErrorDomain/EMSGSIZE`, current `PinnedAnnexIO`
normalizes it to `responseTooLarge`. The prior real pinned URLSession proof is
`Tests/ClubhouseTransportTests/PinnedWebSocketTests.swift:322` (20–66 MiB fail,
1.2 MiB succeeds). It was **reused**, not rerun here. No fresh live TLS/socket,
simulator, SwiftUI rendering, or wall-clock retry-cadence test was performed.

The gap, clean replay, fresh snapshot, next event, text, canvas and history bodies
come from the real desktop code. Old checkpoint8 snapshots are synthetic variants
of the captured snapshot9, changing **only** `payload.lastSeq`, to exercise the
held/old cursor and repeated stale checkpoint cases. The Go IO leaf supplies a
small history containing existing pending permission/question/queue state; this
does not claim that the new 17 MiB critical question itself can be read or
answered on the phone. Such an exact pending question may require desktop review.

All 70 archived Go transport/domain/adapter production files were byte-compared
against 6c32b12: zero differences. The scratch 147 package manifest includes only
this audit test file, avoiding unrelated legacy test compiler errors. Production
files are unchanged. No host app, phone, native app or shared simulator was used.

## Reproduction

1. Extract the captures with Python `gzip.decompress` into an ignored scratch
   directory; verify against `SOURCE.json`.
2. In a scratch archive of each pinned Go commit, copy
   `FrameOverLimitAuditTests.swift` to `Tests/CompanionDomainTests/`. Restrict that
   scratch manifest's domain test target sources to this one file for 147.
3. Run `GO2732_CAPTURE_ROOT=<absolute captures directory> swift test --filter FrameOverLimitAuditTests`.
   Add `-Xswiftc -DAUDIT147` only for 147.
4. To regenerate desktop captures, apply `capture-server.patch` with `git apply --unidiff-zero` in a scratch
   desktop checkout at the pinned SHA and run
   `node node_modules/vitest/vitest.mjs run --project main src/main/services/annex-server.test.ts -t 'Go2732 capture exact production frames'`.
   It writes `go2732-capture/`; run the existing focused critical tests with
   `-t 'with a critical event a phone can not receive'`.
