# URLSession per-host pool probe (macOS loopback, 2026-11-27)

Question: can slow or held REST reads delay the WebSocket ping/pong, or other reads, to the same desktop host?
Probe: `Tests/ClubhouseTransportTests/URLSessionPoolProbeTests.swift` + `Fixtures/pool-server.mjs`. It's opt-in:
`ANNEX_POOL_PROBE=1 swift test --filter URLSessionPoolProbe`. It measures and prints `POOLPROBE` lines and doesn't
assert timings. Base: eb993348.

## Configuration (verified from source)
- `PinnedAnnexIO.configuration()` (`Annex/Annex/Transport/AnnexIO.swift:132-143`) is `.ephemeral` with no cache,
  cookies or credential storage, `timeoutIntervalForRequest = 30` and `timeoutIntervalForResource = 60`. It sets no
  `httpMaximumConnectionsPerHost` and uses `delegateQueue: nil` (`:130`).
- One `PinnedAnnexIO`, so one session, per `AnnexTransport` (`AnnexTransport.swift:44`). REST and
  `URLSessionWebSocketTask` share it (`AnnexIO.swift:207`). Full-event downloads make their own session per download
  (`AnnexFullEventIO.swift:22-24`), so they have a separate pool.
- Effective default limit, read at runtime on macOS 26.6.1: `default`, `ephemeral` and production all report **6**.
  The iOS 27.2 and macOS 27.2 SDK `NSURLSession.h:1472-1476` headers are identical: "The default value is `6`", and
  the limit is per session. That is header documentation; the value at runtime on an iOS device hasn't been measured.
- Protocol: the desktop is Node `https.createServer` with no `ALPNProtocols` (Clubhouse
  `src/main/services/annex-server.ts:4864`, `annex-tls.ts:182-189`, local checkout d7400c6). Against the same server
  shape, the client reports `networkProtocolName = http/1.1` and the server reports ALPN `http/1.1`. There's no h2, so
  there's no multiplexing.
- Isolation: the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY`
  (pbxproj :512-513), but every `Transport/*.swift` file is a **membership exception** of the app target
  (pbxproj :17-55). The app links them as the `ClubhouseTransport` SwiftPM product (:10, :353), so the app builds
  the ping and REST path with the package's settings (tools 6.2, Swift 6 mode, nonisolated default). These are the
  same settings as `swift test`.

## Measurements (real PinnedAnnexIO: pinned TLS + mTLS, loopback, macOS)
| K held reads | new read | reached server | WS ping RTT during hold |
|---|---|---|---|
| 1 | 6.2 ms | yes | 0.2 ms |
| 4 | 7.4 ms | yes | 0.2 ms |
| 5 | 7.2 ms | yes | 0.2 ms |
| 6 | queued >3 s | no | 0.4-1.2 ms |
| 8 | queued >3 s (2 holds also queued) | no | 0.3-0.6 ms |

- The WebSocket doesn't use one of the 6 HTTP slots. With 6 reads held, the server had 7 sockets open (6 HTTP plus
  the WS). A WS opened behind 8 held reads (6 active, 2 queued) still connected in 22 ms, with a 0.6 ms ping.
- Cancelling a held read's Swift task frees its slot: a queued read completed 22.6 ms later. The queue is FIFO: with
  K=8, the slot went to the next queued hold, not to the new read.
- Six holds that never answer fail at 30.0 s (-1001). A read queued 0.5 s behind them reached the server only as they
  failed.
- Six slow but live reads (a body byte every 2 s, so they don't hit their own idle timeout): a read queued behind them
  **fails with -1001 at 30.0 s and never reaches the server**. Queue wait counts toward `timeoutIntervalForRequest`.
- Ping caveat: URLSession reads pongs only while a `receive()` is outstanding, as `PinnedWebSocketTests.swift:148`
  already notes. Without a receive loop, a second ping never completes. Production always has one
  (`AnnexTransport.swift:597`).

## Not proven here
iOS runtime limit, iOS networking stack, cellular or Wi-Fi paths, and the real desktop's behaviour. The app build
wasn't checked: this toolchain can't build it (RootView:69 baseline).
