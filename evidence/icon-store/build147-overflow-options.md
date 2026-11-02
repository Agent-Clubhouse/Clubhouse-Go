Archived from icon PR214 commit `03f51504b5bdd0aac65492aa8d33b5a0c9877907`, `docs/testing/build147-overflow-options.md`.

# Go 147 overflow behavior and image decoder audits

Frozen source: `6c32b12`. The package audit exercises actual `AnnexTransport` receiving
bytes, envelope decoding/replay validation, `CompanionLiveService`, and observable
`CompanionStore` state. HTTP identity/capabilities/catalog/history/commands are scripted;
close 1013 is sent by a real private loopback WebSocket peer. No physical device, desktop
app or build-147 install was used. Most state cases use `AnnexManualClock`; a separate real-time test measures D
cadence because the retry-reset logic also uses `ContinuousClock`. Healthy pings continue. Before reconnect, the warm cases load normal/Dispatcher chat and two helper
approvals. The desktop has not yet shipped the proposed metadata-only overflow fallback.

| Option | Catalog and chat | Helper approvals | Connection/retries | Commands |
|---|---|---|---|---|
| A: empty projects/agents, marker; Dispatcher/helper fields omitted | Observable empty Home frame, then successful REST catch-up restores normal project/agent. Both chats retained because 147 keeps omitted Dispatcher state. | Previous two retained | No retry loop | Warm service commands work |
| A: also `dispatcher:null`, `helperRequests:[]` | Empty Home frame, then REST restores normal project/agent. Dispatcher disappears; `CompanionStore.apply(.hosts)` clears its chat. Normal chat retained. | Both removed and not restored by REST | No retry loop | Warm service commands work; missing snapshot-only state remains lost |
| B: `snapshot_too_large`, socket open | Cached catalog/chats retained | Cached requests retained | Still Connecting after 120 clock seconds, no reconnect, healthy pings | Connection-gated UI blocked. Warm service commands work; cold service commands fail, although raw transport commands work |
| C: peer closes 1013 | Cached catalog/chats retained | Cached requests retained | Generic connection loss; immediate jittered exponential retry, no snapshot grace. Repeated closes keep retrying | Fail between capability handshakes; connection-gated UI blocked during reconnect |
| D: `snapshot_failed`, socket open | Cached catalog/chats retained | Cached requests retained | Connecting for 30 s, then timeout and initial 0.25–0.5 s jitter. Each real grace resets the attempt counter. Successful retry REST catch-up can mark Connected while still awaiting snapshot | Warm service commands work during grace. Cold service commands fail until refresh, although raw transport commands work |

Repeated D refusals each get another 30 seconds and reset to initial 0.25–0.5 second
jitter: a real-time run reconnected at **30.309 s** and **60.679 s**, with backoffs
**0.30256 s** and **0.36550 s**. Its retry reset uses real `ContinuousClock`, so a manual
Annex clock alone misleadingly produces increasing D backoffs. The real-time check is
included in the frozen audit and takes about 61 seconds.

C does use increasing jitter: observed 0.269, 0.766, 1.998, 2.242 and 5.024 seconds,
without D's extra grace. Its ranges are 0.25–0.5, 0.5–1, 1–2, 2–4, 4–8, 8–16,
then 15–30 seconds. Exact samples vary by jitter.
`CompanionStore` keeps `requiresResync` on conversations after reconnect until history is
reloaded. The conversation view normally reloads on a usable connection; these tests
report store state and service command results separately, rather than treating a
successful transport command as proof that the UI is enabled.

On both macOS and the private iPhone 17 Pro / iOS 26.0 (23A343) simulator, a peer's actual
`88 02 03 f5` close frame (1013) surfaced as URLSession close code **1005**, with a
receive error `NSPOSIXErrorDomain/57`. An identical 1000-close control surfaced **1000**.
Go's socket abstraction forwards the receive error and does not expose close codes,
so it cannot honor a 1013 cooldown or reason. The simulator audit passed with both peers.

All 33 omission/icon-map cases from [the shape audit](build147-snapshot-compatibility.md)
also passed through this real transport. A missing snapshot sequence was deliberately
rejected as `malformedResponse`: preserve nonnegative envelope `lastSeq` or payload
`lastSeq`, and a matching capability epoch if the envelope includes `epoch`. Preserving
only projects/agents/quickAgents/Dispatcher/protocolVersion is insufficient.

## SVG and GIF

Real base64 data URLs were decoded using the unchanged build-147 data-URL helper and
`UIImage(data:)` call on the private simulator. SVG returned nil. ImageIO produced a
nonnil source with no type and zero images; it had no usable thumbnail. The store rejects
SVG before rendering, including zero-image sources. An exploratory thumbnail call on
an empty ImageIO source crashed only the disposable simulator test app; the final audit
and store guard image count before thumbnail creation.

A generated real animated GIF has two frames (red then blue). `UIImage(data:)` returns a
non-nil 8×8 image. Pixel checks confirm that both UIKit and the store render the red
first frame. The store downsamples only index zero and never constructs an animation.

## Reproduction

Run from the worktree root, using a new disposable `build/build147` directory:

```sh
mkdir -p build/build147
git archive 6c32b12 | tar -x -C build/build147
cp Tests/Compatibility/Build147*Tests.swift build/build147/Tests/CompanionDomainTests/
python3 Tests/Compatibility/websocket_close_peer.py --code 1013 --out build &
# Wait for build/close1013-port, then:
swift test --package-path build/build147 --filter Build147TransportAuditTests
# Stop only the fixture above, using its owned stop file:
touch build/close1013-stop
```

The optional simulator audit additionally needs the same peer with `--code 1000`. Set
`TEST_RUNNER_ICON_AUDIT_WS_PORT` and `TEST_RUNNER_ICON_AUDIT_WS_CONTROL_PORT` from their
port files when running `CompanionIconDecoderTests`. Without these explicit fixture
variables the close-code test skips. SVG/GIF audits need no network. Use only a new,
private simulator, then delete it. No live E2E script or host desktop launch is involved.
