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

Framebriar v0.7.0's Swift `Telemetry` (vendored from tag `v0.7.0`, commit
`f57b75fe5d38d7e2c3d221d246c9e01445da41dc`) sends OTLP/HTTP JSON traces, logs and delta metrics to
`{framebriar}/v1/otlp/v1/{traces,logs,metrics}` with the enrollment's access token. It follows the
"Clubhouse Go integration recipe" in `Vendor/Framebriar/README.md`.

- **Gate:** only while the user is enrolled (has redeemed an invitation). Before enrollment no developer
  telemetry is captured or sent; separately enabled local Connection diagnostics is independent.
  Clearing enrollment, revocation or expiry stops developer telemetry and forgets its in-memory queue;
  a 403 stops it until the next enrollment. Memory only: nothing is written to disk. Settings states
  next to Developer feedback that enrolling also sends usage and diagnostic telemetry to the developer.
- **Capture:** `AnnexTelemetry` captures while enrolled (`setEnrolledCapture`), independent of the
  Connection diagnostics mode. Each completed record is forwarded as it ends (`observeRecords`) through
  `AnnexAppTelemetry`, which maps it onto Framebriar's `app.*` conventions (`docs/app-telemetry-v1.md`
  in framebriar). Spans keep their trace/span/parent IDs and their events with event times, so
  feedback incident references select completed operations that export spans. Lifecycle/navigation
  operations exported only as unparented logs are excluded from incident references. Runtime creation
  is lazy within the retained SwiftUI State lifetime; observer tokens and owner-specific enrollment
  capture leases prevent a discarded or older bridge from replacing or clearing another observer.
  DEBUG connection tracing uses an independent observer.
- **One session ID:** the diagnostics `service.instance.id` is adopted as `FramebriarSession.id`, so the
  feedback report `sessionId`, the telemetry resource `session.id` and the incident `phoneInstanceId`
  are the same random UUID per process.
- **Resource:** `service.name=clubhouse-annex` (gateway-stamped), `service.version=<version>+<build>`,
  `session.id`. Every log and span carries `app.telemetry.schema_version=1` and `app.platform=ios`,
  plus `app.build.sha` when the build supplies a commit.
- **Flush:** every 60 s or 200 items while running, and on entering the background (the SDK's lifecycle
  observer, up to four batches in a background task). The ping summary is handed over at most once a
  minute and when the scene enters the background.

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
| Submitted feedback | `feedback.submitted` log with `feedback.report.id` and the incident's first trace; with the composer's "Include recent app diagnostics" on, eligible local/queued spans and logs from the last five minutes are tagged `feedback.excerpt=true`; already-sent records retain their original session/trace joins |

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

The vendored Framebriar SDK (tag `v0.7.0`, commit `f57b75fe5d38d7e2c3d221d246c9e01445da41dc`) includes
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

## Local chat performance summaries

Open conversations aggregate `projectorApply`, `storeApply`, `timelineBuild`, `markdownParse`,
`conversationBody`, `messageBody`, and `mainActorDelay` into the existing bounded routine-summary
map. Each kind exports at most one `app.performance.summary` per flush interval, with numeric
`count`, `durationMs` (sum), `mean_ms`, `max_ms`, `over_threshold`, `messageCount` (maximum), and
`textBytes` (maximum, where applicable). There is no per-chunk span or retained message content.
Collection uses the existing diagnostics/enrollment gate and clear/opt-out generation fence.

Body timing measures synchronous SwiftUI view construction, not layout or GPU rendering. A 250 ms
probe while an open conversation is active records excess main-actor scheduling delay; delays of
100 ms or more count as over threshold. This can reveal a stall but is not a frame-rate/hitch metric
and must not be interpreted as a measured display frame. Counts and sizes distinguish a long
history, large rows, repeated body passes, and reconnect fan-out without exporting agent/session IDs.

## Report delivery and local diagnostics preparation

A successful submission commits the reviewed report to the SDK's durable local queue. Go wakes its
foreground delivery pump when that queue grows, in addition to the periodic 15-second tick. Transient
inactive scenes keep the feedback client resumed; true background pauses it. A report committed just
before actual suspension can wait for foreground. The telemetry marker has its own immediate flush,
so its timestamp does not prove report delivery. SDK report and access backoffs remain independent.

`AnnexFeedbackDiagnostics` prepares a synchronous, immutable, memory-only diagnostics-v1 value from
`AnnexTelemetry.snapshot()`, independently of OTLP export. **It is not connected to report submission.**
It retains the newest 200 completed operations in a five-minute completion-time window and caps the
entire encoded value at 64 KiB, trimming oldest entries. The provider reports ring/trim losses in
`dropped` and omitted fields in `droppedAttrs`. `lines` counts entries; `bytes` is the UTF-8 size of
compact JSON for the entries array. An opt-out value derives from the same frozen snapshot without
recapture. Disabled/empty/missing/invalid providers have explicit state and closed reason values;
disconnection alone does not discard failure or backoff entries.

Entries use fixed namespace/operation/level values, mapped closed failure classes, non-negative
allowlisted numbers, valid HTTP status codes, and validated lowercase connection/attempt/trace/span
IDs. Available numeric fields are duration, attempt, backoff, byte counts, connect/TLS/first-byte
milliseconds and HTTP status. Unknown fields are omitted and counted. Failure mapping preserves
`overflow`, `busy` and `storage`; trust/identity/authentication/forbidden collapse to `auth`,
invalid-input/malformed/unsupported/conflict/rejected collapse to `protocol`, and uncertain outcomes
become `unknown`. Go currently combines cannot-connect and disconnected into `connection`, mapped to
`closed`; it cannot reliably distinguish `refused`. Host/phone process identity stays in incident and
resource metadata. No prompts, content, names, paths, addresses, URLs or error descriptions are added.
SDK blocked/delivery status cannot be inferred from this local ring and is not fabricated. The
optional `peerRef`/`agentRef`, `exitCode`, `link`, state/reason/provider/driver fields are not emitted by
this adapter. Future adoption must use per-run keyed 16-lowercase-hex refs, integer exit codes 0–255,
`link` values `mtls`/`bearer`/`unknown` and closed client enum tokens matching
`^[a-z0-9][a-z0-9_.-]{0,31}$` (custom names become `custom`), never raw names.
`operation` remains the attempted verb; reached states belong in `fromState`/`toState`. Timestamps are
ISO 8601 UTC with `Z`. If the SDK supplies `delivery`, `queued` is an integer report count captured at
open, and `lastResult` is `ok`, `none` (no attempt this process), or a closed failure value.

General report diagnostics must remain off. The local provider is not connected. **This v0.7.0
integration is blocked from release:** its SDK composer always adds a diagnostics state and falls
back to the telemetry ring without a provider; including diagnostics also asks for a report-specific
telemetry excerpt. The Go flag alone cannot enforce omission through this SDK composer. Framebriar
is preparing a tagged OFF policy and independent marker-only delivery. Do not merge or ship this
integration until that tag is adopted and the real composer/draft wire tests prove no provider call,
no `diagnostics` key and no duplicate excerpt. No vendor patch or replacement composer is used.
See [TestFlight release gates](testflight.md#report-diagnostics-release-gate).

## Feedback SDK adoption checklist

The SDK is refreshed unchanged from the user-approved identity-binding v0.7.0 tag
`f57b75fe5d38d7e2c3d221d246c9e01445da41dc`. Identity, held reports and shake integration use its
public API, not the earlier sketch. Diagnostics OFF support is still a release blocker above. No
production report or physical-device/host-app installation is authorized here. Draft store/privacy
changes are [not effective](testflight.md#draft-app-privacy-update--not-effective).

### Go's presentation boundaries

Settings, menu and screenshot composer routes use `CompanionFeedbackComposer`; Settings and both
enrollment explainers use `CompanionFeedbackEnrollment`. `CompanionEnrollmentSheet` retains its Done
action and the SDK enrollment form, including **Clear queued feedback**. The separate Saved feedback
section also exposes that confirmed destructive action without requiring enrollment. Clearing local
reports does not delete server copies. The SDK still owns draft capture/review/submission; these
wrappers neither recreate a draft nor invent an SDK recovery status.

| Surface | Current integration | Remaining gate |
|---|---|---|
| Developer feedback | Enrollment uses the tagged SDK disclosure and removes Go's temporary enrollment inset. Settings retains Go's detailed automatic-telemetry/manual-content wording. | Check disclosure against the pending tagged OFF policy. |
| Saved feedback | SDK-held count, Send confirmation with frozen displayed token/count, held-only Clear and separate Clear queued feedback. SDK message exposes partial release counts; blocked reports are distinct. | Real-device review. |
| Composer | SDK single-screen notes/image editor, Included summary, top-bar Send and delivery/attention status. Bound save uses the draft's enrollmentRef; enrollmentChanged keeps only text/image, opens a new capture/ID/refs and requires another Send. | Tagged OFF support and wire proof before release. |
| Scoped test | No action or provider wiring. | Wait for Framebriar's tagged per-draft OFF/ON API, then add an explicitly requested labeled one-report path. |

Held reports' **Clear** must work while unenrolled and clear held reports only; **Clear queued
feedback** remains the separate all-saved-reports action. Held **Send** opens a confirmation naming
the current connection and report count: “Queue N held reports for the current connection?” Freeze
the SDK's opaque confirmation token with the displayed count/connection. Do not refresh it at action
time. A stale token requires a new status and a new confirmation; it is not automatic approval of a
changed report set or connection. Successful release means **queued for delivery**, never **Sent**.

Distinguish an enrollment change before saving from a saved-but-held report. An unsaved draft remains
open with its text/image and a clear “Connection changed; review again” action. Reopening creates a
new report ID, capture and enrollment/correlation references; carry only user text and image, update
Included and require another Send tap. Do not transfer old diagnostics or incident references. A
saved-held report goes through the separate held-report confirmation, not a second submission.
**Going back to an older SDK is unsafe.** The tagged [rollback contract](https://github.com/masra91/framebriar/blob/f57b75fe5d38d7e2c3d221d246c9e01445da41dc/docs/general-feedback-v2.md#rollback-to-an-older-sdk)
shows that a bound report may send under a later enrollment on the older SDK. Already-held reports
are fenced as blocked, but an older Swift writer re-encodes away the ref/held marker: after upgrading
they can only be cleared, not released. Before a planned downgrade, let bound reports deliver and
explicitly release or clear held reports; do not silently clear the queue or merely revert the pin.

Legacy queue entries have no enrollment ref. The tagged migration binds them to whichever enrollment
exists at first load, even if they were originally captured under another one; that attribution limit
cannot be recovered from the old bytes. If first loaded unenrolled they are persisted as unbound and
stay held after re-enrollment. Do not imply all pre-adoption reports have a proven original binding.

### Adoption checks

- [x] Obtain exact tag/commit/API from the orchestrator; refresh the complete SDK with the verified
  vendoring script, run its tests and hash verification, and leave no direct vendor edits.
- [ ] Match SDK disclosure and Included summary to Go's automatic telemetry, optional diagnostics,
  notes/image and incident fields. A single diagnostics off switch removes entries, incident and flat
  trace/span fields while retaining user text/image. Absence, capture off, unavailable and disconnected
  states must be honest; an empty report must not silently imply useful logs were attached.
- [ ] Keep general diagnostics emission off. After tagged adoption, the scoped test requires an explicit
  request and a non-empty visible test label, and authorizes only one draft/report ID with its captured
  enrollment. Freeze once at open, review the included content, then require an intentional Send. Once
  saved, the one-report permission travels with that immutable queued report through retries/holds;
  the current settings/access state must not erase its entries. Cancel or enrollment change invalidates
  an unsaved draft's scope; reopening needs a newly labeled test draft. Keep the label in reviewed
  report content, not in transport attributes. The toggle derives omission from the frozen value without recapture; retries retain the same value.
- [ ] Fake-wire tests: ordinary reports have no `diagnostics` field; only the labeled test report has it;
  cancel sends nothing; a second ordinary report emits none; retries preserve the captured body. Do not
  pass a missing provider if the SDK interprets that as permission to fall back to its telemetry ring.
- [ ] Inject connection failure/backoff, freeze diagnostics, then disconnect/change access before saving
  and retrying. The gate/pump must preserve those reviewed entries even when the desktop is offline;
  enrollment binding may hold delivery but must not rewrite captured diagnostics to empty/not-connected.
  Entries attached to a report must not also be emitted as a report-specific telemetry excerpt.
  Ordinary consented telemetry remains separate; confirm both pipelines explicitly with fake transports.
- [ ] Fake enrollment-race tests: change enrollment between open/review/save and while confirming a held
  release; preserve unsaved text/image, distinguish saved-held status, reject stale confirmation tokens,
  prove no automatic rebind/resubmit, prove held-only Clear works unenrolled, and preserve permanently
  blocked reports. Check persistence/restart and describe downgrade compatibility from actual evidence.
- [x] Replace both old shake receivers with the tagged callback in one change; Go presents through its
  existing single-presenter guard using the callback's screenshot/window. Prove one event → one composer,
  and typing/secure-field suppression, scenes/windows, sheets, tab changes and Settings presentation.
  Remove Settings from the suppression flag only with the tagged topmost-presentation support. Preserve
  screenshot foreground-active timing and active-scene fallback. Real shake and Full-Screen Previews
  remain physical-device checks, not claims from synthetic events.
- [x] Record the SDK's [iPad harness-limit outcome](testflight.md#sdk-ipad-timeout-assessment): the exact
  v0.6.0 sequence took 11m00s against a ten-minute limit, with 32 pass / 0 skip on a new 26.0 iPad simulator.
  No app hang is established or fixed; one run cannot exclude an intermittent stall.
- [ ] Investigate the separate one-off secure-keyboard issue from evidence. Check portrait/landscape,
  full/split view, keyboard, image picker, confirmation cancel/confirm, and repeated open/close without backgrounding or duplicate sends.
- [ ] Recheck lazy runtime ownership, sink/capture leases and foreground/inactive/background delivery;
  mock timestamps/backoff must show no duplicate send. Run packages/coverage, vendor tests/hashes,
  Debug/Release and authorized app/preview tests; record actual OS/compiler and any skipped checks.
- [ ] Before a candidate is installed, obtain the user's approval for any store/privacy declaration
  changes. Report the candidate commit/build and gaps to the orchestrator. The user chooses any install
  and submits their own labeled phone test report; Framebriar reads its body from Azure. Until that
  happens, real device, Azure readback and URLSession delivery remain unproven. No automatic live send.

## Icon cache

`iconCache` uses only the fixed events `iconHit`, `iconMiss`, `iconFailure` and
`iconEviction`, with numeric `cacheBytes`. The enrolled telemetry bridge emits the
`app.icons` counter by these closed outcomes and `app.icons.cache.bytes` observations.
`iconFetch` records bounded `responseBytes` and `durationMs`, mapped to
`app.icons.fetch.duration`. No host, kind/id key, token, filename, URL, MIME string or
exception text is recorded. Existing capture and enrollment gates apply unchanged.
