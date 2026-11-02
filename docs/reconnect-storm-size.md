# Oversized snapshot reconnect investigation

## Test plan and scope

Use `swift test` only: a throwaway pinned mTLS WebSocket on loopback, the existing
transport fake sockets, and `AnnexManualClock`. Never start/stop/update the host
Clubhouse app, use a phone or simulator, install/publish, run live e2e, or merge.

1. Observe raw URLSession text and binary messages at limit minus one, limit, and
   limit plus one. Record NSError domain/code, elapsed time, and peer close code.
2. Require the pinned adapter to normalize only the size error, leaving accepted
   messages unchanged. This regression test failed before the adapter fix with
   `NSPOSIXErrorDomain` code 40 instead of `responseTooLarge` (both frame types).
3. Exercise repeated size failures through `run`, its injected sleep clock, and
   eventual recovery. Check no retry before the ceiling, cancellation, and one
   immediate attempt after explicit disconnect/connect.
4. Check the independent transport byte guard at exactly 16 MiB and one byte over,
   malformed JSON's existing behavior, the host's readable status, no rediscovery
   callback, and Retry recovery.
5. Measure seven short-lived socket failures with the normal backoff, then run
   `swift test --enable-code-coverage` and `scripts/coverage.sh --skip-tests --check`.

## Measured evidence

On this Mac, real `URLSessionWebSocketTask` with `maximumMessageSize = 1024`:

| Message | 1023 bytes | 1024 bytes | 1025 bytes |
| --- | --- | --- | --- |
| Text | received | received | POSIX EMSGSIZE, peer close 1009 |
| Binary | received | received | POSIX EMSGSIZE, peer close 1009 |

The oversize error was `NSError(domain: NSPOSIXErrorDomain, code: 40)`. In the first
run receive failed in 0.34–1.35 ms after the send command; the loopback server saw
1009 in 0.20–0.81 ms after sending. These are observations, not timing assertions.
Under-limit and exactly-at-limit messages were received unchanged. The fixture
records actual incoming close frames, independently of URLSession's local state.

Previously the error reached `run`, `terminalError` returned nil, and
`AnnexDiagnosticFailure.classify` returned `unknown`. Thus it used the ordinary
backoff. The adapter now throws `AnnexTransportError.responseTooLarge`, classified
as `tooLarge`; that error is recoverable in `run`. The independent byte-count guard
also uses `responseTooLarge` rather than conflating size with malformed JSON.

Default equal-jitter delays for attempts 1–7 are 0.25–0.5, 0.5–1, 1–2, 2–4, 4–8,
8–16, and 15–30 seconds. With a 170 ms connection lifetime, accept intervals are
0.42–0.67, 0.67–1.17, 1.17–2.17, 2.17–4.17, 4.17–8.17, 8.17–16.17, and 15.17–30.17
seconds, plus request/scheduling overhead. One measured injected-clock run yielded
0.466, 1.079, 1.806, 4.101, 6.400, 13.841, 20.788 seconds. Seven attempts increased
normally; a short socket did not reset the attempt counter.

The existing 30-second reset measures the whole identity/capability/socket attempt
with `ContinuousClock`, not just time since socket acceptance. A slow preflight can
therefore also reset it. This change does not alter that existing policy.

A fresh `run` begins at zero. `CompanionLiveService.resume` calls `reconnect`, which
disconnects/connects; route rediscovery can relocate and register a new transport.
Either can explain a new burst (including the reported 02:39:24 burst), but no local
test proves which happened on the real phone. The incident team's reports of a
31.8 MB snapshot and a fast 1009 close are consistent with this size-limit path;
we did not inspect or operate the phone or real desktop to establish causality.

## Bounded recovery

Every oversize failure now waits at least the configured ordinary backoff ceiling,
with jitter from 1 to 1.5 times that ceiling (30–45 seconds by default). It emits a
distinct recoverable `retrying` state so the reachable desktop does not trigger
`onUnreachable` and reset the wait through rediscovery. The existing host issue row
and desktop settings row explain: “The desktop sent more data than your phone can
accept. We'll try again shortly.” Retry and foreground reconnect cancel the wait
and allow an immediate attempt; another oversize result starts another slow wait.
A later acceptable snapshot recovers normally. No limit increase or snapshot
arrival deadline is introduced; #207's explicit `snapshot_failed` grace remains.

## Receive limits and memory

- `PinnedAnnexIO` defaults to 16 * 1024 * 1024 bytes and sets URLSession's
  `maximumMessageSize` to that value before starting the WebSocket.
- `AnnexTransport.receive` independently requires `data.count <= 16,777,216`,
  then decodes `AnnexEnvelope` with `JSONDecoder`. Invalid JSON is malformed;
  decoding has no separate snapshot byte budget. Snapshot sequence/epoch are
  validated afterward.
- `CompanionIdentityColor.data(fromDataURL:)` requires a base64 data URL and uses
  `Data(base64Encoded:)`. Invalid base64 produces no icon. There is no independent
  icon byte/dimension budget here. The unrelated 12 MiB base64 check in the media
  read path is not a snapshot icon limit.
- `CompanionIconCache` decodes with `UIImage(data:)` and caches without an explicit
  decoded-byte cost limit or downsampling.

Wire compatibility requires the **entire serialized UTF-8 JSON message**, including
all catalog fields, icon data-URL prefixes and base64, to fit in 16,777,216 bytes.
The boundary test accepts exactly that size; budget strictly below it in production.
A conservative desktop target of at most 8 MiB for the complete message provides
wire headroom, preferably far smaller with thumbnails. This is a proposed budget,
not a measured guarantee of phone memory safety. Base64 consumes about 4/3 of
compressed image bytes; even an 8 MiB all-icon budget fits less than 6 MiB of image
files after accounting for other JSON.

Peak memory can substantially exceed wire size: URLSession's text/data, JSON strings,
retained icon catalog, decoded icon Data, subscriber buffers/previous host models,
and full-resolution decoded images can coexist. An image's decoded footprint is
roughly width * height * 4 bytes regardless of compressed size. Rebuilding and
broadcasting a large snapshot repeats allocation, parsing and base64/image work;
wire size alone cannot establish a safe memory ceiling. Desktop thumbnails and a
total serialized-message budget address that separately.
