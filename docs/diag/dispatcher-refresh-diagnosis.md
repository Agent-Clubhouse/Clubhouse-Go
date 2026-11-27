# Dispatcher chat refresh slowness: client-side diagnosis (read-only)

Base: main c207871. Scope: Go mobile client only. These are notes, not a fix. Host timings come from the host owner's traces (desktop 0.43.0-beta.8). The phone build is unknown.

## Request-flow map

All paths below are under `Annex/Annex/`.

**Open (connected host, conversation not loaded):**
- `Companion/Views/CompanionConversationView.swift:293` runs `.task(id: target)` → `store.load` (`Companion/Domain/CompanionStore.swift:381-433`).
- That calls `service.history` (`Companion/Adapters/CompanionLiveService.swift:136-207`), which makes one read: `GET /mobile/agents/:id/chat`. It is unbounded, with no `limit` (`Transport/AnnexTransport.swift:241`).
- `conversation.isLoading` drives the composer's "Refreshing…" (`CompanionConversationComposer.swift:300-303, 547-553`). Only this read gates it.
- In parallel, the composer runs `.task(id: modelSettingsKey)` (`CompanionConversationComposer.swift:358`, `:384`). That issues `GET /mobile/agents/:id/settings` for the Session-vs-Saved model badge only. It gates nothing.

**Foreground (resume) and reconnect:**
1. Suspend (`CompanionLiveService.swift:933-941`), a WS disconnect (`:1229-1232`) or a transport resync (`:1252-1258`) emits `resyncRequired`. The store retires in-flight loads and sets `requiresResync` (`CompanionStore.swift:1946-1957`, `:372-378`; the retirement was added by #632).
2. The transport reconnects. It reads identity → capabilities, then opens the WS (`AnnexTransport.swift:460-486`). It transitions `.connected` only after the first snapshot frame has been received and parsed (`AnnexTransport.swift:705-719`).
3. The service's serial event drain (`CompanionLiveService.swift:1074-1089`) takes `.connected`, sets `.synchronizing` and calls `scheduleRefresh` (`:1215-1226`, `:1102-1113`).
4. `refresh(hostID:)` (`:1356-1480`) is strictly serial:
   - capabilities (1359)
   - network (1362)
   - projects (1366)
   - **agents, one project at a time** (1369-1373; a `for` loop with `try await` in the body)
   - catch-up `agents/state` (1467-1472)
   - `connection = .connected` (1474)
   - `await refreshHelperRoutingLabels` (1475; `GET /helper-routing` on a label-cache miss)
   - `emitHosts` (1480)
5. Only then does the view reload the chat. `CompanionConversationView.swift:316-318` calls `load(force:)` when `connection.canOperate && requiresResync`.
6. That load is the unbounded `/chat` read. The composer settings read refires because its key includes `connection.label` and `sessionID` (`CompanionConversationComposer.swift:370-375`). There is also a `chatHistory limit=1` read (`refreshWakePermission`, `:1594`).

Header text while waiting: "Refreshing the conversation before you continue." (`.synchronizing`, `Companion/Domain/CompanionModels.swift:123`). Send and approve require `.connected` (`CompanionModels.swift:95`, `CompanionStore.swift:327-331`).

## Findings

### Confirmed by code and by the probe

1. **Visible chat reload is serialized behind the whole catalog refresh.** The probe was run with a fixed 50 ms per-read latency:

   | Projects | Resync → `/chat` read |
   |---|---|
   | N=1 | 270 ms |
   | N=14 | 962 ms |

   That is about 53 ms per extra project, strictly serial. It matches the host trace for 14:45: 14 serial agents GETs, then agents/state, then chat at 10.717 (WS → chat 7.512 s).
2. **The connection gate awaits helper-routing on a label-cache miss** (`CompanionLiveService.swift:1474-1480`, `:599-605`). The probe held `/helper-routing` open: the host stayed `.synchronizing` and the read order was capabilities, projects, agents, helperRouting. This affects cold start, a changed revision, or capability withdrawal. It was not in play in the 14:45 window (no helper-routing request).
3. **The serial WS drain awaits helper-routing in the snapshot handler** (`CompanionLiveService.swift:1295`, and `:1304` for `helper_routing:changed`). With that read held, a `chat:event` that had arrived was not projected into the conversation (items stayed at 1).
4. **Agent settings never gate chat render, loading or send.** The 6 s settings call is a sidecar that every refresh re-triggers.
5. **`/chat` is requested unbounded** (`Transport/AnnexTransport.swift:241`; `CompanionLiveService.swift:144`). The client decodes the whole body to `AnnexJSON` (`Transport/AnnexTransport.swift:299-300`) and replays every event (`CompanionLiveService.swift:155`). The paged route `chatHistory(limit:beforeSeq:)` exists and is used only by the archive reader (`Companion/Adapters/CompanionArchiveReader.swift:22`, limit 300).

### Measured client CPU cost

These are synthetic shapes, run in a macOS debug build, not on a device.

| Payload | Decode | Project + store |
|---|---|---|
| 4.67 MB `/chat`, 2,612 events | 123 ms | 8 ms |
| 7.2 MB `/chat`, 27k chunk events | 701 ms | 54 ms |
| 646 KB snapshot, 39 agents, 0 icon bytes | 1 ms | 67 ms from emit to store update |

Client CPU does not explain multi-second gaps on a Mac. A device could be several times slower, but that is unmeasured.

### Inferred or unexplained

- **The ~3.1 s gap from snapshot sent to capabilities (14:45): unexplained.** The host "sent" time marks a socket write, not phone receipt. `.connected` waits for full receipt and parse of the ~684 KB frame. Candidates: link transfer time, or main-actor contention with SwiftUI work on device. The 0-byte icon await is not it, and measured snapshot handling is about 67 ms on a Mac.
- **The 18.5 s gap after the 1001 reconnect (14:33): unexplained.** Code expectation: `resyncRequired(.reconnected)` is emitted at socket open (`Transport/AnnexTransport.swift:486`), which should trigger refresh immediately. Hypotheses: the app was suspended (code 1001 "going away" fits an iOS background close; the 18 s would then be user time away), or the drain was blocked by an awaited handler. Device telemetry (scenePhase, connection spans) is needed.
- **Gaps of 1–3 s inside the serial agents loop:** unexplained. Candidates are link latency spikes or main-actor stalls.
- **The 15.4 s `/chat` lifetime:** for the host owner. Note that request lifetime includes body delivery: if the 4.7 MB session body is sent whole over a slow phone link, delivery alone could take seconds. This is unverified.

## Candidate regressing commits

- No merge in #616, #621, #622, #632, #634, #638 or #639 changed the serial refresh, the view's reconnect gate or the helper-routing awaits. Blame on those lines points to October and to 5891657a (2026-11-02).
- #632 (e1263b8) retires in-flight loads on connection loss and resync. That routes more reloads through the serialized gate instead of letting a pending `/chat` finish. It is a plausible amplifier, not a root cause.
- #639 is render-only. #634 is terminal-only. #622 adds Dispatcher recovery reads only on user action.
- The most likely change in the window is on the host or in the data: chat 873 ms → 2.4 s p50, settings at 6 s, and a 4.7 MB session read whole. The client's unbounded `/chat` makes it pay that cost on every reconnect.

## Proposed deterministic regression tests

The tests are in `docs/diag/dispatcher-refresh-probe.patch` and apply cleanly with `git apply` on c207871. Captured output is in `dispatcher-refresh-probe-output.txt`.

- `ScriptedAnnexTransport.setReadDelay` adds a per-read latency (4 lines).
- `visibleChatReloadDoesNotScaleWithProjectCount` compares N=1 with N=14 at 50 ms and asserts that no agents read happens before `/chat`. It fails on main.
- `connectedIsPublishedWhileHelperRoutingIsSlow` fails on main.
- `chatEventIsProjectedWhileSnapshotAwaitsHelperRouting` fails on main.
- `DispatcherPayloadCostProbeTests` records costs and has no assertions.

The view rule at line 316 is reproduced inside the test. A store-level gate would make the test exact.

Run it with `swift test --jobs 2 --filter 'DispatcherRefreshGateProbeTests|DispatcherPayloadCostProbeTests'`. A warm build takes about 1.5 min.

## Fix direction (not implemented)

1. On resync, reload the visible conversation as soon as the transport is operable. Do not wait for the full catalog. Either make `history()` independent of `refresh(hostID:)`, or publish `.connected` before the catalog and agents loop (`CompanionLiveService.swift:1474`; `CompanionConversationView.swift:316-318`).
2. Parallelize the per-project agents reads with bounded concurrency, or use a bulk route (`CompanionLiveService.swift:1369-1373`).
3. Move `refreshHelperRoutingLabels` off the critical path: a detached task after `emitHosts`, and not awaited inside the drain (`:1295`, `:1304`, `:1475`).
4. Load the live chat with a bounded page (`chatHistory` limit plus `beforeSeq` for earlier messages), or replay from `lastSequence`, instead of fetching the unbounded `/chat` (`:144`). This needs a contract check with the host owner for Dispatcher semantics.
5. Keep the composer settings read off `connection.label` churn (`CompanionConversationComposer.swift:370-375`). It is not on the critical path, but it adds host load.

## Evidence gaps

- The phone build is unknown.
- There are no device-side spans. AnnexTelemetry measures each read (`AnnexTransport.swift:224`); a device export would split network time from main-actor time for the 3.1 s, 18.5 s and in-loop gaps.
- Nothing shows whether the 14:33 1001 was an app suspend.
- The real snapshot and `/chat` composition is unknown; the probe payloads are synthetic.
- No device or simulator measurement was possible (simulators are blocked on this host).
