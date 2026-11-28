# Compatibility harness: what it consumes from the desktop

This note is for the owner of the desktop fixtures. It says which routes and frames the Go compatibility harness
(`Tests/CompanionDomainTests/CompatHarness*.swift`) reads from a host fixture. A beta.N variant must supply all of them
in the same shapes.

The harness drives the real `AnnexTransport`, `CompanionLiveService` and `CompanionStore` through a fake `AnnexIO`
(`CompatIO`), on an `AnnexManualClock`. The selection is set through `store.selection`, as RootView sets it.

## File

The file is one JSON object, `version: 1`:

| Key | Type | Use |
|---|---|---|
| `routes` | `{ "<path>": { "status": Int, "body": JSON } }` | Each REST GET is answered by exact `URL.path` match. A path that isn't listed gets `404 {"error":"not_found"}`, and the path is recorded. |
| `snapshot` | `{ "type": "snapshot", "payload": {...} }` | The first frame on every socket, including each reconnect. It is also re-sent as beta.8's refresh snapshot. |
| `chatFrames` | `[ { "type": "chat:event", "seq": Int, "payload": { "agentId", "event": {...} } } ]` | Pushed after the history load, or while it is held. The harness renumbers `seq` onto its own global sequence. |
| `selectedAgent` | String | The agent id of the selection. The target is `(host, "__dispatcher__", selectedAgent)`. |
| `expectedVisibleReply` | String | The text that must appear exactly once, after the user's prompt and before the routed update. |
| `desktopCommit`, `inputSHA256` | provenance | Recorded only. |

Each file's SHA-256 is pinned in `CompatFixture.sha256`, and loading fails on a mismatch. The acceptance pair is
`v2-beta7` / `v2-beta8` (host commit 48c08c27, `capabilities.dispatcher.enabled = true`). The original pair, with
`enabled = false`, is kept only as `negctl-dispatcher-disabled-*`.

## Routes read, in client order

| Route | Read by | Fields that matter |
|---|---|---|
| `GET /api/v1/identity` | transport, on every connection attempt | Synthesized by the harness, not taken from the fixture: `publicKey` and `fingerprint`, which must equal the pinned host id. |
| `GET /api/v1/mobile/capabilities` | transport (before the socket), then the service's refresh | `version`, `epoch`, `controlAvailable`, `commands[]`, `agentAddress`, `agentState`, `dispatcher{enabled,flagOn,projectId,settings.path}`, `helperRouting`, `iconRefs`, `network`, `routes`, and the rest of the feature blocks. An `epoch` change triggers a resync. |
| `GET /api/v1/mobile/network` | refresh, when `capabilities.network` is present | Body decoded as `AnnexNetworkSnapshot`. |
| `GET /api/v1/projects` | refresh (one catalog pass) | An array of `{id, name, ...}`, or `{projects: [...]}`. The harness counts these GETs as catalog passes. |
| `GET /api/v1/projects/:id/agents` | refresh, one per project (serial at f242adf, 4 at a time from abe8d06 on) | An array of agents, or `{agents: [...]}`. The fixture has 14. |
| `GET /api/v1/mobile/agents/state` | refresh catch-up, when `capabilities.agentState` is present | `{agents: [{agentId, projectId, status, sessionId, sessionState, pendingPermission, pendingQuestion, detailedStatus}]}` |
| `GET /api/v1/mobile/agents/:id/chat` | `store.load` → `service.history` | `sessionId`, `events[]` (chat events with per-session `seq`), `state`, `readOnly`, `canStart`, `capabilities`, `chatControls`, `pendingPermissions[]`, `pendingQuestions[]`, `queuedMessageIds`, `queueStateSeq`, `truncated`, `lastSeq`, `slashCommands`, `contentRoots`, `epoch` |
| `GET /api/v1/mobile/dispatcher/settings` | when the snapshot's dispatcher changes | Not in the 19 exported GETs. The harness answers 404, and it shows up in the recorded paths. |

The harness answers any POST with 500 and counts it. Every acceptance test asserts zero POSTs. It also asserts that every
request carried `Authorization: Bearer`.

## Frames

- **Snapshot:** `payload.lastSeq` is the global baseline (1000 in the fixtures). `payload.machine.fingerprint` must equal the
  pinned host id. The harness rewrites only that field. The service reads `projects`, `agents{projectId: [...]}`,
  `dispatcher`, `dispatcherPresence`, `quickAgents`, `helperRequests`, `helperRoutingRevision`, `projectState`,
  `finishedQuickAgents`, `idleDays`, `theme`/`terminalColors`, `ptyHost.platform`, `grantRequests` (the capability's
  `snapshotField`), `appUpdate`, `projectLinks`, `agentIcons`/`projectIcons`, and `snapshotTruncated`.
  On the same socket, a snapshot whose `lastSeq` equals the client's cursor is delivered. A lower one is dropped as a
  duplicate, and a higher one causes a resync (`AnnexReplay.swift:42-48`).
- **Event frame:** `{type, seq, payload}`. `chat:event` carries `payload.agentId` and `payload.event`, which is a chat event
  with `sessionId`, `seq`, `type` and `data`. The client ignores `permission:request` frames, but they advance the cursor.
- **beta.8 refresh churn:** one `permission:request` (seq+1) plus one snapshot refresh on create, and one snapshot
  refresh on withdraw. beta.7 sends only the `permission:request`. Each refresh snapshot is the fixture snapshot at the
  current `lastSeq`.

## What a beta.N variant must keep

The paths and status codes; `selectedAgent` present in `snapshot.dispatcher.agent` or in a project's agents; the chat
body's `sessionId` matching the `chatFrames`' `event.sessionId`; and contiguous `chatFrames` seqs. To exercise
`409 chat_read_changed`, the harness needs no fixture change: it answers a held read with
`409 {"error":"chat_read_changed"}` itself.

## Not covered

URLSession (its per-host connection pool, request and resource timeouts, TLS), SwiftUI scheduling, device CPU, real
network, and live sessions. The selected Dispatcher in the fixtures is sleeping and read-only, so passing proves the
display contract only, not the live action contract.
