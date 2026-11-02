# Frozen-client wire compatibility audit

Scratch evidence only; no production Go changes. Icon PR #214 remains separate and its wire adapter stays off.

Pinned clients: build 147 `6c32b12`, current-main comparison `9441c43`.
Final CH #2682 serializer: `ae2cf9b7d95ed2ae4229221d4be37320686f960a`.
Final CH #2686 permission fixture/command: `1a684c1cef0d1b7ca7b3da6dff04ceccab500d2a`.

Tests use real Annex envelope decoding, transport receive/cursor handling, CompanionLiveService, projector, observable Store, and terminal channel/session/screen. IO/socket/runtime/clock are controlled. No host app, phone, live desktop, installs, native UI automation, or shared simulator. Rendered wording is established by observable model plus the pinned SwiftUI source; these are not screenshot tests.

## Final permission and overflow findings

Each focused test below passed on both pinned clients. All overflow proposal inputs are synthetic, because the proposal was not built. Actual CH fixture tests are explicitly identified.

| Evidence | Result on both clients |
| --- | --- |
| `final2686RealPermissionFixtureBothRoutesAndPersistentOptions` | Actual `chat-permission-incomplete.json`, both live `chat:event` and HTTP `pendingPermissions`: warning leads the visible summary and expandable detail. ID/title/tool/options, queued message, pending question, status, session and cursor survive. Allow refuses with exact desktop sentence, restores pending, and Deny settles. Always is desktop-only without persistent capability; with capability it requires confirmation and refuses identically. |
| `final2686ActualCommandReceiptsSmallMismatchRestartAndPreview` | Real CH `executeChatCommand`, with controlled runtime: normal small and 4096-byte requests approve; changed label, added/reordered live options, preview marker, remembered preview even below 4096, old 4097 bytes, once-whole 8 KiB after record restart, oversized Allow/Always refuse. Rejected cards remain deniable. Actual Go commands are exported and fed back through this CH function; 11 emitted commands per client pass expected outcomes, including normal-small approval. |
| `final2686RealToolPreviewFixtureAndSyntheticNoticeOptions` | Actual `chat-event-tool-call-preview.json`: one tool row, ID `call_write`, displayed title `Write big.ts`, summary `big.ts`, kind edit, awaiting approval, cursor 101. Outer seq 1000 follows initial snapshot seq 999. Literal fixture has no locations; their preservation is untested. Unknown truncation marker does not itself draw a tool warning. Separate synthetic old proposal: leading description warning and trailing note survive a summary over 400 characters; rawInput content fallback alone is cut to 400 Characters. Synthetic 16 options, 256-byte labels/scopes preserve IDs; retained Deny works. |
| `proposedPendingOverflowRefreshAndRemoval` | Previous partial-list proposal is unsafe: a current HTTP fold removes a live card absent from both event tail and pending list. Pending list absence alone does not remove a request still in the tail. Stale pages preserve newer Store items but are not a safe protocol guarantee. Resolution does not fetch HTTP. Leaving/re-entering a loaded synchronized chat does not fetch. Menu **Refresh conversation** does, and reveals the next server-returned card. |
| `proposedAllRowsOr503CachedAndColdRecovery` | Replacement all-rows-or-error proposal: exact 503 maps to **Desktop request failed (503): pending_overflow.** Server message/count ignored. Existing chat/items/cards/questions/queue/status/cursor kept; loading stops; no automatic retry/reconnect. `requiresResync` disables chat send and decisions until a successful forced refresh. Cold open shows **Conversation unavailable** and **Try again**, no endless loading; subsequent smaller response recovers. Safe state preservation, but desktop action is required while overflow persists. |
| `proposedMinimalDenyOnlyZeroOptionsAndDuplicateTail` | Successful minimal all-row pages: reject_once/cancel_turn work; reject_always needs persistent capability or is shown desktop-only. No approval option invented; unknown kinds remain read-only. Empty or missing options: **Review this request on desktop.**, no decision buttons or pinned action, forged options blocked; chat still works. Minimal pending row overrides same-ID/same-seq full request from event tail, keeping warning and removing full detail/approve actions. |
| `proposedQuestionFallbacksMustNotInventOrOmitPromptText` | Missing prompt text is **unsafe**: projector drops the malformed prompt, keeps a question with empty prompts, `validAnswers([:])` succeeds and a real empty answer map is sent. No options with exact full ID/prompt and free text disabled is view-only (Send answers disabled); with free text enabled an answer can still be sent. Prefer explicit bounded retrieval failure, leave original pending on desktop, emit no partial/missing-text question. |

Exact rejected approval sentence:

> This request is too large to review here. Review it on the desktop to approve it, or deny it here.

A zero-deny row must not retain the standard warning's promise “You can still deny it here.” Use desktop-only wording when no supported actual deny is available; the measured card has no button.

The actual permission fixture abbreviates the preview's middle; this audit does not claim it contains a literal 256 KiB payload. Large original server events are synthesized from its fields for command-boundary cases. Record restart uses the real `_forgetSentPermissionsForTest` hook. CH runtime is fake, but its command fold, pending lookup, bounds, guard and respond path are unchanged extracted source. The outer HTTP server/router is not running.

Client approval projection preserves array order, IDs, labels and scopes. Commands send only `requestId` and selected `optionId` (plus routing/envelope), never options or labels. Go cannot cause a server live-options mismatch by rewriting those fields. CH compares its own event/live arrays by exact JSON serialization, so a server-side order difference still refuses.

Relevant production references (same relative files in each archived commit):

- `Transport/AnnexPairing.swift:78` retains safe HTTP error code, discards server message.
- `Companion/Adapters/CompanionLiveService.swift:80` builds a new history projector; `:86` applies events, `:88` pending rows with `allowOlderPending`; readable error at 147 `:1194`, main `:1203`.
- `Companion/Domain/CompanionStore.swift:108` disables operation on resync; `:194` load guard; `:217` stale-page merge; `:229` current-page replacement; `:233` failure preserves items; `:370` permission submission/rejection; `:484` answer validation.
- `Companion/Views/CompanionConversationView.swift:90` manual refresh, `:119` entry load, `:300` explicit loading/error/Try again; `CompanionQuestionCard.swift:46` Send answers enabled by validAnswers.
- Permission projector: 147 `CompanionChatProjector.swift:150`, main `:153`. Missing prompt is compact-mapped at 147 `:179`, main `:182`. Raw input 400-Character fallback: 147 `:344`, main `:426`.
- Approval summary is outside disclosure: 147 `CompanionTimelineCards.swift:530`, main `:525`; empty option text: 147 `:586`, main `:581`. One-off/persistent availability: `CompanionModels.swift:531`.
- CH `annex-chat-bounds.ts:159` final refusal precedence; `mobile-control.ts:215` actual permission command lookup/bounds/guard/respond.

## Earlier evidence reused unchanged

The six initial frame proposal cases, pinned HTTP size recovery, and terminal cases were already reported to the orchestrator. They were not broadly rerun for permission-only changes.

- Unknown next-seq frame advances global cursor without reconnect; it does not reconstruct omitted critical changes. Later bounded explicit HTTP history can restore omitted content.
- Tool-update replacement preview without rawOutput finishes; later bounded history restores full output. Append previews duplicate output.
- Hook/outer permission inputs do not draw chat approval cards; actual rich routes are chat:event permission_request and HTTP pendingPermissions.
- Real pinned TLS HTTP, both Content-Length and chunked over 16 MiB: explicit failure/resync, existing state kept, no automatic HTTP retry; bounded later page recovers. Older archive poison pages require bounded events and valid paging cursor.
- Omitted canvases/unknown snapshotTruncated are ignored. Explicit empty icon maps clear images; retained maps preserve them.
- Go does not call HTTP PTY `/buffer`: no read route in AnnexReadRoute, exhaustive transport path switch, terminal attaches solely through WebSocket. New HTTP/TLS endpoint behavior was therefore not tested, per the task's stop condition.
- Final #2682 raw replay uses actual headless/manager/server functions with stub registry/PTY input. Complete raw and missing-earlier-modes replay fit 8 MiB; viewport/cursor match captured xterm, next output lands correctly, one attach/no reconnect. Missing earlier application-cursor/bracketed-paste modes cannot be reconstructed. A 512-byte test budget forces the real screen-only helper branch; this does not claim ordinary 120x30 screens need it at production 8 MiB. Local Go scrollback is limited to 1000 lines; lost older terminal history is unavailable through Go.
- Final #2682 unfit-screen and last-resort oversized-ack emit exact `{type:error,payload:{message:terminal_unavailable,op:pty:attach,agentId}}` with no ack. Both clients immediately show **The desktop couldn't start a shell: terminal_unavailable**, Try again, no auto attach/reconnect over 120 controlled seconds, running agent/chat untouched. Manual retry recovers with a valid ack. Missing op/id instead hangs Connecting; ack.error is ignored; pty:exit mislabels process exit.
- Old captured 25 MiB real TLS/WebSocket ack repeats attach/reconnect; 147 jitter backs off from 0.25–0.5 s, main waits 30–45 s. Oversized other frame families/pre-replay limiting were not fixed by #2682. The superseded empty-buffer fallback was unsafe and is not approved.

The xterm serializer omitted hidden-cursor state from both full and limited samples, a pre-existing limitation. Initial harness mistakes (wrong hidden-cursor expectation, wrong tool display title, deny receipt nesting) were corrected, and focused tests rerun. No production fixes were made to make these tests pass.

## Reproduction

Keep all temporary paths inside this worktree. Archive each client commit to `build/build147` and `build/frame-main`, copy this Swift test to their `Tests/CompanionDomainTests/`, and leave production files untouched. The main archive needed an explicit empty `init() {}` in the **test-only** ScriptedAnnexTransport actor because the current Swift 6.2 toolchain rejected its synthesized nonisolated initializer.

Clone CH into `build/ch-frame-2682` (historical directory name), fetch/check out the exact relevant head. Extract TypeScript 5.9.3 into `build/serializer-typescript` using npm pack/tar with a worktree-local cache, no package scripts/global installation. Terminal captures additionally need only locked @xterm/headless 6.0.0 and addon-serialize 0.14.0 in that temporary clone; never start Electron or a live PTY. Capture scripts assert exact SHAs and transpile unchanged TypeScript.

For #2686:

```sh
node Tests/Compatibility/capture-2686-permission.cjs build/ch-frame-2682 build/frame-2686 build/serializer-typescript/lib/typescript.js
swift test --package-path build/build147 --filter 'FrameWireAuditTests.(final2686|proposedAllRows|proposedMinimal|proposedQuestion|proposedPendingOverflow)'
swift test --package-path build/frame-main --filter 'FrameWireAuditTests.(final2686|proposedAllRows|proposedMinimal|proposedQuestion|proposedPendingOverflow)'
node Tests/Compatibility/capture-2686-permission.cjs build/ch-frame-2682 build/frame-2686 build/serializer-typescript/lib/typescript.js build/frame-2686/go-commands-build147.json
node Tests/Compatibility/capture-2686-permission.cjs build/ch-frame-2682 build/frame-2686 build/serializer-typescript/lib/typescript.js build/frame-2686/go-commands-frame-main.json
```

Seven focused tests passed per client; actual emitted-command replay passes 11 per client. The generator itself checks 12 command outcomes, including deny. Generated captures/large payloads/logs remain in ignored build paths and are reproducible; no client production source is changed.

For the historical terminal cases, use each script at its asserted head, then run only the corresponding named tests. `frame-http-peer.mjs` is a local synthetic TLS/WebSocket peer, launched and stopped by the test. Test-generated TLS material is local/temporary, no desktop credentials.
