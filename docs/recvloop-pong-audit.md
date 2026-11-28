# Receive-loop pong audit (2026-11-27)

**Question.** Can a held await, the event drain or the byte/frame path in the production transport delay observing a
pong past the 10 s ping deadline, even though the pong reached the wire?

**Code compared.** These SHAs have byte-identical `Annex/Annex/Transport` (tree 7a68f4d5),
`Tests/ClubhouseTransportTests`, `Package.swift` and `Package.resolved`:

- f242adfc (field build)
- a0ad2b83
- eb993348 (base)

**Replay.** `Tests/ClubhouseTransportTests/ReceiveLoopPongTests.swift`. Run it with
`swift test --filter recvAudit`.

## Ping path
1. Sending the ping. The task-group child at `AnnexTransport.swift:593-597` sleeps 20 s on `AnnexClock`, then calls
   `socket.ping()`. A `group.addTask` closure has no inherited actor context, and this one captures `socket`, not
   `self`, so it runs on the global executor. The package uses Swift 6 mode with no upcoming features, so it isn't
   nonisolated(nonsending).
2. The deadline. `URLSessionAnnexWebSocket.ping` (`AnnexIO.swift:255-280`) is a nonisolated class. It starts an
   unstructured `Task` that sleeps 10 s and then calls `resolve(timedOut)` and `close()` (`:259-265`).
   `task.sendPing`'s pong handler runs on the session's delegate queue (`delegateQueue: nil`, `:130`) and resolves
   through the lock-only `AnnexPingCompletion` (`:294-315`).
3. Neither the AnnexTransport actor nor the MainActor is on this path. The only thing that gates observation is
   URLSession reading the pong, and it reads a pong only while a `receive()` is outstanding
   (`PinnedWebSocketTests.swift:148`; probe 7e067051).

## Receive loop: processing happens before re-arming
`AnnexTransport.swift:600-603` runs `let data = try await socket.receive()`, then
`try await self.receive(data, ...)`, then loops. No `receive()` is outstanding during:

- (a) the hop onto the actor at `:603`, which waits while the actor runs any synchronous work;
- (b) `receive(_:)` itself, `:643-741`. This is all synchronous on the actor: the `JSONDecoder` envelope decode at
  `:654`, the cursor, and `emit`.
- (c) the one loop-path await inside it, `try await socket.send(replay)` at `:739`. It runs after every first
  snapshot on a connection (`requestSnapshotReplay = awaitingFirstSnapshot`, `:689`, `:735`) and after a snapshot
  resync. The awaits at `:666-667` and `:711-712` are inside detached deadline Tasks, not on the loop path.

## Event delivery can't back-pressure the loop
- `events()` uses `.bufferingOldest(eventCapacity = 256)` (`:42`, `:50`), and `terminalEvents()` uses 4096 (`:81`).
- `yield` is synchronous. When a buffer is full, `emit` finishes that subscriber with `queueOverflow` (`:61-74`).
  It never suspends.
- CompanionLiveService reads the stream in its own Task (`CompanionLiveService.swift:1030-1033`). It appends to
  `pendingEvents` (cap 256, `:1098-1101`) and drains in a separate Task (`:1103-1110`). A slow drain
  (refreshDispatcherSettings, icons) therefore can't reach the transport. Its REST reads do re-enter the actor, and
  `read` decodes the body synchronously on the actor (`:290`). That's bounded case (a).

## Replay matrix
The fake socket reads pongs only while a `receive()` is outstanding, in wire order. Its `ping()` has the production
structure, using `AnnexPingCompletion` and the 10 s deadline on the manual clock. Everything above the socket is the
production AnnexTransport.

| Scenario | f242adfc | a0ad2b83 | eb993348 |
|---|---|---|---|
| Control: idle loop, pong before deadline | answered | answered | answered |
| Subscriber never drains, 400 frames then a pong | answered (subscriber overflows at 256) | same | same |
| 1 and 10 snapshots of 700 KB ahead of the pong | answered, after ~50 / ~500 ms wall | same | same |
| Replay `send` held at `:739`, pong on the wire at 20 s | **timed out at 30 s; pong never read; receive never re-armed** | same | same |
| AnnexJSON decode on the actor, 700 KB / 16 MiB | ~53 ms / ~1.03 s | same | same |

Timings are macOS debug builds on Apple Silicon. They aren't device timings.

## Proven and not proven
**Proven, under the fake socket's URLSession model, on all three SHAs:**
- The production loop does its frame processing before re-arming `receive()`.
- One await inside frame processing (`:739`) can hold re-arming indefinitely. With it held, a pong that has reached
  the wire isn't observed, and the ping times out at exactly 10 s.
- Consumer back-pressure can't do this.
- Frame and REST decode on the actor delays the pong only by its CPU time: about 50 ms per 700 KB, and about 1 s at
  the 16 MiB cap, on a Mac.

**Not proven:**
- That `URLSessionWebSocketTask.send` of a small replay frame can stall for more than 10 s on a live path. On
  loopback it can't. It plausibly can when the path is already dead, and that case is indistinguishable from
  "the pong never arrived".
- That the device spent more than 10 s in actor CPU work. That would take more than 150 such decodes back to back.
- That URLSession also answers the host's pings only under an outstanding receive. If it does, a parked loop would
  also explain the host closing the connection as unresponsive. This was not tested.

No cause is claimed for the field capture.

## Observability gap
A failed or slow `.ping` span records only its duration and failure (`AnnexTelemetry.swift:426-438`). Nothing
records the receive loop's state. These device signals would tell "never arrived" apart from "arrived but
observation was delayed":

1. Whether a `receive()` was outstanding when the deadline fired, and since when.
2. Milliseconds since the last `receive()` returned, and since the last frame was processed.
3. The in-flight processing phase when the deadline fired (actor hop, decode, or the `:739` send) and how long it
   had been in it.
4. Type and byte count of the last frame.

If a receive was outstanding for the whole 10 s window, the app wasn't delaying observation. If receive wasn't
re-armed for most of the window, observation was delayed on the app side.
