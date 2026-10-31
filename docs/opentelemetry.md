# OpenTelemetry diagnostics and independent export

Clubhouse Go uses the official OpenTelemetry Swift Core **2.6.0** API and trace SDK,
with explicit instrumentation and a synchronous bounded memory exporter. It does
not use automatic URLSession instrumentation, device/resource detection or global
SDK registration. Capture is **off by default**. Settings → Connection diagnostics
offers Off / This session / Always, review, clear and explicit sharing of a sanitized JSON snapshot.
Remote export to the user's own collector is disabled by default and configured separately through an existing HTTPS
OTLP/HTTP JSON collector. Framebriar feedback enrollment does not authorize export to that collector.
Feedback can optionally include reviewed incident trace references; it does not contain spans.

Separately, **enrolling in developer feedback turns on Framebriar telemetry** to the developer
(see [Framebriar telemetry](#framebriar-telemetry-enrolled-users)). While enrolled, the same closed-enum
spans are captured even with Connection diagnostics Off, and are exported to Framebriar.

## Coverage

| Area | Recorded data |
|---|---|
| App and navigation | launch, foreground/background, conversation selection, settings |
| Discovery/manual entry | browse lifetime, result count, resolve/failure, explicit address inspection |
| Trust and access | inspection, pairing, restore, revoke/forget, categorized trust/auth failures |
| Annex connection | identity/capability requests, connection/reconnect through valid snapshot, backoff attempts/delay; pings are counted (count, slow, failed, mean/max ms), and only failed pings or pongs slower than 1 s are spans |
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
app's existing process memory and are not attributes. No regular-expression
redaction of raw retained data.

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
consume the buffer. No background export or disk spool exists. A separately consented foreground exporter
retains one batch of at most 64 spans/256 KiB, retries at most three times with bounded
backoff, and keeps 512 dedup IDs. Disable, clear, mode/destination change or background
cancels the request and fences late results. Bytes already transmitted cannot be recalled. The SDK exporter independently rejects non-allowlisted data.
The diagnostic JSON is a review format, **not OTLP wire data**. These are traces
and trace-derived numeric measurements, not an OTel metrics/logs pipeline.

## Collector enablement (not enabled here)

`AnnexOTLPJSON` converts the SDK exporter's sanitized records to standard OTLP/HTTP
JSON, preserving trace/span/parent IDs and per-process `service.name` / `service.instance.id`.
`AnnexOTLPHTTP` uses ephemeral URLSession, normal TLS, no cookies/credential storage,
no redirects, 10-second request/15-second resource limits and a 64-KiB bounded response.
Only OTLP-retryable 429/502/503/504 responses are retried, with jitter and bounded
Retry-After handling; delays over five minutes drop the batch rather than retry early.
Collector failures are categorized without retaining response/error strings. Partial-success
rejects are dropped, never retried. Export requests are not recursively instrumented.

In Settings → Connection diagnostics → Tracing destination, enter a **complete HTTPS
OTLP/HTTP JSON `/v1/traces` route**, save it, then separately confirm export. Changing
the destination requires fresh consent. Only future records after the foreground export
session begins are eligible; pre-consent/background backlog is excluded. Collection must
also be on. The destination URL is stored locally in settings, never in telemetry. A random
logical backend UUID can be included in reviewed feedback so operators can map it to their
collector without exposing URLs or secrets. No destination has been configured here.

**App Insights route:** mobile → existing HTTPS OTLP/HTTP JSON receiver → OpenTelemetry
Collector contrib `azuremonitor` exporter → the selected App Insights instance. Desktop can
export to that same instance independently. This is a real mobile HTTP exporter, not an
App Insights connection string parser; do not paste a connection string into the endpoint.
The upstream Azure exporter is beta and maps OTel `service.name` to cloud role and
`service.instance.id` to role instance; verify the deployed collector's version/mapping and
sampling with the acceptance checklist below. This app sends no authentication header;
a private collector requiring auth needs an approved auth adapter before use. Do not expose
an unauthenticated public receiver to make this work. No resources or credentials were created.

Existing desktop exporters under `src/main/telemetry/destinations/` are outbound clients,
not an Annex ingest endpoint. Do not send OTLP to the pairing port or reuse pairing/feedback
credentials. Don't point this collector at Framebriar's `/v1/otlp` route: it sends no token, and
Framebriar telemetry has its own enrolled path (above).

Before claiming end-to-end backend validation: configure an approved collector on both ends;
perform one benign operation; verify matching trace ID with distinct mobile/host span IDs,
parent links, `cloud_RoleName`/`cloud_RoleInstance`; reconnect and confirm new socket/attempt
IDs with stable process IDs; restart and confirm new process identity; verify two simultaneous
phones are distinct; inspect one reviewed feedback report's incident references against that
backend. No live ingestion proof is claimed by this PR or its fixtures.

Official references:
- https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/azuremonitorexporter
- https://opentelemetry.io/docs/specs/otlp/
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
change that instance; app restart does. An optional authenticated WebSocket hello/ack
verifies echoed phone/attempt IDs and records a distinct host process instance plus
a host-issued connection UUID. These are correlation metadata, never authentication.
If collection was off when an existing connection opened, reconnect that desktop
after enabling collection to negotiate its peer identity. Normal per-request tracing
starts immediately; no hidden reconnect disrupts an active chat.
Each connection attempt and operation has an independent trace; metadata is bounded.
See the handshake fixture and [wire contract](annex-trace-context.md).

**Instance ID on Framebriar:** Framebriar's gateway keeps only `service.*`, `session.id`,
`deployment.environment.name`, `telemetry.sdk.*`, `os.type` and `host.arch` from client resources, so it
would drop `service.instance.id`. Framebriar telemetry therefore carries the same UUID as `session.id`
(see above). No live ingestion test has been performed.

## Framebriar telemetry (enrolled users)

Framebriar v0.5.0's Swift `Telemetry` (vendored from tag `v0.5.0`, commit
`4905102899ee20db0c436716f4783f6ba9827c5d`) sends OTLP/HTTP JSON traces, logs and delta metrics to
`{framebriar}/v1/otlp/v1/{traces,logs,metrics}` with the enrollment's access token. It follows the
"Clubhouse Go integration recipe" in `Vendor/Framebriar/README.md`.

- **Gate:** only while the user is enrolled (has redeemed an invitation). Before enrollment nothing is
  captured or sent. Clearing enrollment, revocation or expiry stops it and forgets the in-memory queue;
  a 403 stops it until the next enrollment. Memory only: nothing is written to disk. Settings states
  next to Developer feedback that enrolling also sends usage and diagnostic telemetry to the developer.
- **Capture:** `AnnexTelemetry` captures while enrolled (`setEnrolledCapture`), independent of the
  Connection diagnostics mode. Each completed record is forwarded as it ends (`setRecordSink`) through
  `AnnexAppTelemetry`, which maps it onto Framebriar's `app.*` conventions (`docs/app-telemetry-v1.md`
  in framebriar). Spans keep their trace/span/parent IDs and their events with event times, so
  feedback incident references point at exported spans.
- **One session ID:** the diagnostics `service.instance.id` is adopted as `FramebriarSession.id`, so the
  feedback report `sessionId`, the telemetry resource `session.id` and the incident `phoneInstanceId`
  are the same random UUID per process.
- **Resource:** `service.name=clubhouse-annex` (gateway-stamped), `service.version=<version>+<build>`,
  `session.id`. Every log and span carries `app.telemetry.schema_version=1` and `app.platform=ios`.
- **Flush:** every 60 s or 200 items while running, and on entering the background (the SDK's lifecycle
  observer, up to four batches in a background task). The ping summary is handed over at most once a
  minute and when the scene leaves the foreground.

| Local record | Telemetry |
|---|---|
| `pairing`, `connection`, `reconnect`, `restore`, `send`/`steer`/`queued`, `spawn`/`createAgent` | `app.flow` span with `app.flow.name` (`pair`, `connect`, `reconnect`, `restore`, `chat_turn`, `spawn_agent`), `app.flow.id`, `app.outcome`, `app.duration.ms`, `annex.operation` |
| Other operations (`http`, `tls`, `stream`, reads, …) | span named by the operation |
| Commands (send, interrupt, permission, …) | also an `app.action` log with `app.action.name` and `app.action.result` (`accepted`, `rejected`, `outcome_unknown`) |
| `foreground`, `background` | `app.lifecycle` log (`app.lifecycle.state`), not a span |
| `navigation`, `settings` | `app.action` log |
| Any failure except cancellation | `error.type` on the span and an `app.error` log with `app.error.class` (the `AnnexDiagnosticFailure` value) |
| `statusCode`; other numbers | `http.response.status_code`; `annex.<name>` |
| Counted pings | `app.performance.summary` log (`app.performance.kind=ping`, `count`, `mean_ms`, `max_ms`, `over_threshold`) and `app.pings` counter by `app.outcome` |
| Connection, reconnect, first text delta | `app.connect.duration` and `app.first_token.duration` histograms (ms), `app.reconnects` counter |
| Launch / enrollment | `app.session.start` log |
| MetricKit (next launch) | `app.error` logs with `app.error.class` `crash`, `hang`, `cpu_exception`, `disk_write_exception`: numbers only, no call stacks |
| Submitted feedback | `feedback.submitted` log with `feedback.report.id` and the incident's first trace; with the composer's "Include recent app diagnostics" on, the last five minutes of spans and logs are re-sent tagged `feedback.excerpt=true` |

The same privacy rules apply: only enum raw values, numbers and random UUIDs. No prompts, agent output,
project/agent/session names, paths, hosts, URLs or error messages. Metric labels come only from small
closed sets. The SDK also scrubs strings and drops secret-looking keys. `AppTelemetryTests` checks that
every string leaving through the mapping is a fixed name, enum value or UUID; `CompanionTelemetryTests`
checks the gate, the session ID and the feedback marker against a mock service.

While enrolled, capture also negotiates trace context with paired desktops as Connection diagnostics
does (random W3C trace IDs only). The user's own collector export is unchanged: it still requires
Connection diagnostics on, a destination and its own consent, and it never receives Framebriar data.

Owner side, not code: the Framebriar registry entry for `clubhouse-annex` must have telemetry on;
until then the gateway answers 403 and the emitter stops quietly until the next enrollment.

## Feedback correlation out

The vendored Framebriar SDK (tag `v0.5.0`, commit `4905102899ee20db0c436716f4783f6ba9827c5d`) includes
the upstream `FeedbackIncident` schema. On opening
feedback (including shake), the app snapshots at most eight recent local trace/span references,
phone process identity, up to four authenticated host and socket IDs, a five-minute time window,
and optional logical backend UUID. Availability distinguishes recorded/unavailable/collection_off;
remote availability is always unverified. The user can remove this metadata before review.
The reviewed object is immutable in the existing offline queue; retry/upload never substitutes
its own request trace. Legacy flat traceId/spanId mirror the first incident reference.

Service redeem/refresh must advertise `feedbackCorrelationVersion:1`; otherwise incident-bearing
reports remain queued without sending or dropping metadata. Ordinary reports remain compatible.
The service owner owns normalization/storage and capability advertisement; no deployment is
included. See [incident contract](feedback-incident-v1.md). Vendor SOURCE.json records the exact upstream commit and file hashes; there are no local SDK patches.
