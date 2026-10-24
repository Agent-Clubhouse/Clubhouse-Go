# Local OpenTelemetry diagnostics

Clubhouse Go uses the official OpenTelemetry Swift Core **2.6.0** API and trace SDK,
with explicit instrumentation and a synchronous bounded memory exporter. It does
not use automatic URLSession instrumentation, device/resource detection or global
SDK registration. Capture is **off by default**. Settings → Connection diagnostics
offers Off / This session / Always, review, clear and explicit sharing of a sanitized JSON snapshot.
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
HTTP command and nested request spans share SDK trace context. Authenticated
pinned HTTP/WS requests propagate standard W3C `traceparent`. The outer WebSocket envelope for a live `turn_started`
can carry validated `tc` from the host to parent the mobile stream;
without it the stream gets an independent trace rather than guessing a command.
This requires the companion host implementation for complete distributed traces.
No baggage is propagated. `tracestate` is bounded/syntax-checked but vendor values
are dropped until an approved exporter defines an allowlist. Invalid contexts are
ignored without affecting chat. See [wire contract](annex-trace-context.md). WebSocket creation is distinct from
connection-to-snapshot timing. URLSession may omit timings on reused connections;
absent values are not zero-duration claims.

## Privacy and limits

Only closed operation/event/failure enums, numeric counts/timings, random SDK
trace/span IDs, random process/connection UUIDs and timestamps are exported. No URL, host/IP, hardware identity,
project/agent/session ID, path, body, message, credentials, screenshot, exception
description or SDK resource data is exported. Transient stream keys remain in the
app's existing process memory and are not attributes. Legacy AppLog now discards
arbitrary text before its memory buffer and OSLog; it retains severity and an
allowlisted category. No regular-expression redaction of raw retained data.

Always persists only the collection preference and resumes on future launches;
This session resets to Off on restart. No mode persists trace contents or enables
sharing. Off clears captured records. Local spans are sampled while capture is
enabled, including children of unsampled host context; bounded capacity limits
retention. Changing collection mode resets the current capture generation.

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
loopback refers to the phone, not the desktop. No live configuration was read. Desktop's vendored Framebriar OTel adapter builds
`<endpoint>/v1/otlp/v1/{traces,metrics,logs}` and uses a live bearer-token gate plus
`session.id` resource correlation. With its `/api` endpoint this becomes
`/api/v1/otlp/v1/traces`. The mobile Framebriar package exposes feedback reports,
not this OTel adapter or telemetry consent/session binding. A mobile adapter must
verify token scope/expiry/revocation and the configured service contract before
using that route. Never infer telemetry permission from feedback enrollment.

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

## Process and peer identity

The immutable phone resource is `service.name=clubhouse-go` with a UUIDv4
`service.instance.id` per app process. Capture mode changes and reconnects do not
change that instance; app restart does. A capability-gated, authenticated handshake
verifies echoed phone/attempt IDs and records a distinct host process instance plus
a host-issued connection UUID. These are correlation metadata, never authentication.
Each connection attempt and operation has an independent trace; metadata is bounded.
See the handshake fixture and [wire contract](annex-trace-context.md).

**Ingestion gap found:** Framebriar service source `src/telemetry.mjs` preserves
traceId/spanId/parentSpanId but drops `service.instance.id` from client resource
attributes. It prefixes service.name with registered app scope. A backend owner must
add validated UUIDv4 instance preservation and test downstream Azure mapping before
claiming complete shared-backend instance correlation. No remote ingestion test has
been performed and no live exporter is configured.
