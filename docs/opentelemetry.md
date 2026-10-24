# Local OpenTelemetry diagnostics

Clubhouse Go uses the official OpenTelemetry Swift Core **2.6.0** API and trace SDK,
with explicit instrumentation and a synchronous bounded memory exporter. It does
not use automatic URLSession instrumentation, device/resource detection or global
SDK registration. Capture is **off by default**. Settings → Connection diagnostics
allows opt-in, review, clear and explicit sharing of a sanitized JSON snapshot.
Remote export is always disabled in this implementation. Framebriar feedback stays
separate and does not receive traces.

## Coverage

| Area | Recorded data |
|---|---|
| App and navigation | launch, foreground/background, conversation selection, settings |
| Discovery/manual entry | browse lifetime, result count, resolve/failure, explicit address inspection |
| Trust and access | inspection, pairing, restore, revoke/forget, categorized trust/auth failures |
| Annex connection | identity/capability requests, connection/reconnect through valid snapshot, backoff attempts/delay, ping |
| HTTP and TLS | bounded byte counts/status, available DNS/connect/TLS/first-byte timings, pin/auth decisions, timeout/error categories |
| Live chat | observed turn duration, first live text delta latency, last/max inter-delta gap, chunk/byte totals, completion/cancellation |
| Control | send/steer/queue, wake/start, interrupt, spawn, permission/question responses, queued removal |
| Recovery | duplicate/gap/replay request/overflow and reconnect |
| History/media | archive/history reads and media download timings/errors/bytes |

First-token means first observed **text delta**, not model tokenization. It starts
at a live `turn_started`, not prompt submission. Historical reads do not generate
stream timings; duplicate session sequence numbers are ignored. Disconnect ends
an observed turn rather than pretending its offline time was streaming latency.
HTTP command and nested request spans share SDK trace context; stream turns have
separate traces because provider events do not reliably identify the initiating
mobile command. No trace headers are sent to desktops. This is client-side
correlation, not distributed server tracing. WebSocket creation is distinct from
connection-to-snapshot timing. URLSession may omit timings on reused connections;
absent values are not zero-duration claims.

## Privacy and limits

Only closed operation/event/failure enums, numeric counts/timings, random SDK
trace/span IDs and timestamps are exported. No URL, host/IP, device identity,
project/agent/session ID, path, body, message, credentials, screenshot, exception
description or SDK resource data is exported. Transient stream keys remain in the
app's existing process memory and are not attributes. Legacy AppLog now discards
arbitrary text before its memory buffer and OSLog; it retains severity and an
allowlisted category. No regular-expression redaction of raw retained data.

Default ring: 256 records, hard maximum 512. Active spans: 128, swept after ten
minutes on begin/snapshot. At most 24 attributes and 32 fixed-name events per span;
32 observed conversations; no per-chunk event allocation. Counts/timings clamp to
finite bounded values. Opt-out/clear advances a generation fence so late callbacks
cannot restore erased data. Export JSON is capped at 512 KiB and failure does not
consume the buffer. No background export task, retry queue, disk spool or network
connection exists. The SDK exporter independently rejects non-allowlisted data.
The diagnostic JSON is a review format, **not OTLP wire data**. These are traces
and trace-derived numeric measurements, not an OTel metrics/logs pipeline.

## Collector enablement (not enabled here)

OTel's official Swift exporter package supports OTLP/HTTP and OTLP/gRPC. A future
remote exporter must apply this same sanitization boundary *before* transmission,
use bounded batching/backoff, and require a separately approved HTTPS collector
URL, authentication strategy, retention policy and explicit opt-in. Do not export
raw SDK SpanData directly. No credentials or collector have been provisioned. Existing desktop code has
Azure Monitor and generic OTLP/HTTP-JSON destinations under
`src/main/telemetry/destinations/` and a separate opt-in Framebriar destination.
Those are outbound exporters, not an Annex collector endpoint. Mobile must not
copy desktop secrets/settings or assume the Annex port accepts OTLP. An approved
OTLP collector could bridge mobile traces to the same backend later; phone
loopback refers to the phone, not the desktop. No live configuration was read.

Official references:
- https://opentelemetry.io/docs/languages/swift/
- https://opentelemetry.io/docs/languages/swift/instrumentation/
- https://github.com/open-telemetry/opentelemetry-swift-core/releases/tag/2.6.0
- https://github.com/open-telemetry/opentelemetry-swift/releases/tag/2.6.0

## Validation

Deterministic package tests cover SDK parentage, default-off/no-remote behavior,
opt-out/clear fences, capacity/expiry, cancellation, error privacy, numeric clamps,
export failure, stream timing and replay suppression. Hosted CI must also compile
the complete SwiftUI app and run existing app/UI suites. No local builds, tests,
simulator launches, device signing or live remote exports were performed for this
feature. Physical network/device validation remains separate.
