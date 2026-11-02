# Feedback triggers, transport diagnostics and delivery

Draft PR branch: `go-feedback-flow/triggers-and-logs`, based on `6c32b12` (reported build 147).

## Proven locally

1. **An eagerly constructed discarded runtime replaces the active sink.** SwiftUI can evaluate `CompanionAppRoot.init` again while retaining its original State. The old initializer constructs another `CompanionRuntime` as `State(initialValue:)`, which constructs another feedback bridge and replaces the shared record sink. Its new `Client` starts paused and never gets the retained runtime's foreground pump. The local ring still has transport spans and incident references; the retained model can still send its marker and the retained bridge can drain ping summaries. The fake-transport regression reproduces connection failure, WebSocket failure, backoff and foreground records remaining local while only the marker goes out. Runtime creation now occurs lazily within the retained State lifetime. Token-based record observers keep telemetry and DEBUG `[live-connect]` independent; owner-specific capture leases mean old cleanup cannot disable a newer owner.
2. **Some incident references could never match exported spans.** `snapshotIncident` previously selected every local operation. The mapper turns foreground/background/navigation/settings into unparented logs and omits appLaunch. Their local span IDs are therefore inappropriate incident references. The incident now selects only operations that export spans, verified exhaustively against the mapper and with a fake transport. Unfinished spans are not in the local export ring. Snapshot can expire/end an operation older than ten minutes; only eligible completed records inside the incident window are referenced.
3. **Submission and telemetry have different delivery schedules.** The pinned SDK commits reports locally and immediately flushes a telemetry marker. Go previously waited for its next 15-second foreground report tick, and paused even on transient `.inactive`. Go now wakes delivery when the committed queue count increases and keeps the pump/client resumed through inactive. True background still pauses it. Timestamp tests cover immediate attempt, background retention, foreground retry, 60-second server backoff, and no extra sends after acknowledgement. This does not add a report background-delivery API or override SDK backoff.
4. **Screenshot status and lifecycle races.** Unknown `canSubmit` now resolves local status rather than silently ignoring a screenshot (or routing the menu to enrollment). The original bounded capture is retained across an inactive screenshot editor. Deactivation cancels the offer timer; the full eight seconds start/restart only after the original scene is foreground-active. Scene disconnect releases the capture. Presentation is anchored to the source window. The offer stays at the top, away from the bottom screenshot thumbnail. Policy tests cover unknown status, inactive/active transitions, interruption, dismissal, preferences and secure input; preview UI tests exercise the actual prompt and attachment.

## Historical reports: limits of attribution

The orphan-sink reproduction is consistent with Framebriar's reported evidence for `35858bdd` (retained summaries and marker after span/action/lifecycle traffic stopped), but this PR does not claim direct historical proof.

For `1939bcff-6d4d-4623-a64e-d22eeb2e2e99`, Framebriar reports eight **span references in two traces**, no matching exported span, and only a submission marker parented to the first reference. The original operation types are unavailable. Unparented-log mapping can explain some cases; it is not demonstrated to explain all eight. No cause is attributed to this report. Its approximately 4.5-minute marker-to-server-receipt gap is also not attributed: the old foreground cadence alone accounts for at most a normal 15-second polling delay, whereas suspension, cancellation and access/report backoff can extend it.

A separate pinned-SDK test confirms already-sent ring entries are not resent/tagged by `feedbackSubmitted`. Their session/trace correlation survives the earlier export; **this is not the cause of either reported missing-span case**.

## Diagnostics v1 provider: implemented locally, sending OFF

`AnnexFeedbackDiagnostics` synchronously freezes a memory-only `AnnexTelemetry.snapshot()`. It never consumes the ring and never depends on OTLP delivery. It produces chronological completed-operation entries in the last five minutes, preserving the newest 200 and trimming older entries until the entire encoded object is at most 64 KiB. Each entry has a UTC completion timestamp, a closed level, `ns=annex`, the closed operation as `event` and `attrs.operation`, optional mapped failure, numeric timings/counts and validated lowercase correlation IDs. No prompts, responses, names, paths, addresses, URLs, error strings or raw retained data are accepted.

The immutable Codable value survives a local encode/decode round trip. `leavingOut()` derives the omitted version without recapture; callers must retain the original when toggling back on. `state`, closed `reason`, `windowStart`, `windowEnd`, `lines`, `bytes`, `dropped`, `droppedAttrs`, and `entries` follow the proposed contract. `bytes` is UTF-8 compact JSON of the entries array. `dropped` combines local-ring loss with entry/byte trimming; out-of-window records are ordinary expiry, not newly dropped entries. A disabled source is `none/collection_off`; an empty source is `none/empty`; missing and invalid providers are explicit. A disconnected phone can still have attached failure/backoff entries; connectivity is not an availability gate.

The local provider does **not** add `report.diagnostics`, change the outbox, or call the service. `CompanionFeedback.reportDiagnosticsSendingEnabled` is false and a fake outgoing-report test asserts the field is absent even when local entries exist. The pinned SDK has no diagnostics field. The deployed service's 16-KiB request cap strips unknown small fields or permanently rejects oversized requests, so bypassing this gate would lose data or block reports.

Release sequence is mandatory: **Framebriar confirms deployed API support (256-KiB report limit) → tags the compatible SDK → Go adopts/verifies that tag and updates UI/disclosure as needed → separately enables report diagnostics.** No live report was sent for this work.

### Failure mapping

| Go failure | diagnostics v1 failure |
|---|---|
| none | omitted |
| cancelled, abandoned | cancelled |
| timeout, tls, dns, offline, server, overflow, busy, storage, unknown | same value |
| connection | closed (Go currently combines cannot-connect and disconnected; cannot reliably label refused) |
| tooLarge | oversize |
| trust, identity, authentication, forbidden | auth |
| invalidInput, malformed, unsupported, conflict, rejected | protocol |
| outcomeUnknown | unknown |

The last three collapsed groups lose detail. No arbitrary subclass/error descriptions are added to compensate. Numeric fields available in Go and retained are `durationMs`, `attempt`, `backoffMs`, `bytes`, `requestBytes`, `responseBytes`, `connectMs`, `tlsMs`, `firstByteMs`, and valid HTTP `statusCode`. Unknown/disallowed measurements and identifiers are omitted and counted in `droppedAttrs`. The current record schema does not supply `snapshotBytes`, transport/message limits or `closeCode`; those are omitted. DNS/first-token/gap timings and chunks are outside the frozen allowlist and are counted as dropped attrs. Host process identity remains in incident metadata, since diagnostics v1 attrs have no host/phone process field. SDK delivery/blocked status is not derivable from the local ring and is not fabricated; it needs the promised typed SDK stats API.

## Correlation fields and a fake report

| Field | Meaning / join |
|---|---|
| report `gameId` | Registered app scope (`clubhouse-annex` in production); fixtures use `phone-ui-fixture` |
| report `buildSha` | Archived commit from `FramebriarBuildSHA`; absent for unconfigured local builds |
| telemetry `service.version` | App version + build number; Go additionally sends `app.build.sha` when configured |
| report `capturedAt`, incident `capturedAt/windowStart/windowEnd` | Submit-object time and frozen five-minute incident capture window, UTC |
| future diagnostics `entry.at` | Completed-operation timestamp, UTC; local provider only until release gate opens |
| report `sessionId`, incident `phoneInstanceId`, telemetry resource `session.id` | Same random per-process phone UUID; adopted from `AnnexTelemetry.instanceID` |
| local collector `service.name/service.instance.id` | `clubhouse-go` / same phone UUID; independent consented collector |
| incident `hostInstanceIds` / span `peer.service.instance.id` | Authenticated desktop process IDs from hello/ack; absent unless negotiated |
| incident `connectionIds`, span `annex.connection.id`, future entry `connectionId` | Host-issued socket UUID |
| span `annex.connection.attempt.id`, future entry `attemptId` | Phone attempt UUID, including failed/retrying attempts |
| incident `traces[].traceId/spanId`, flat `traceId/spanId`, telemetry span IDs | Exact exportable local span references, not guessed request IDs; the marker parents to the first reference |

`outgoingReportCarriesBuildSessionAndOnlyExportableIncidentReferences` creates a failed connection with random host/socket/attempt IDs, sends to an in-memory fake transport, and checks `gameId`, `buildSha`, session identity, incident window/host/socket IDs, exact exported trace/span context and attempt ID. `diagnostics` is absent. The independent local-provider fixture shows a WebSocket failure followed by backoff, including `failure=closed`, connection/attempt/trace/span IDs, `attempt=3`, `backoffMs=30000`, and dropped disallowed attrs. No fixture talks to a desktop or feedback service.

Desktop operators join exact trace/parent IDs where W3C context was propagated, then host/phone/socket/attempt IDs and UTC windows. Not every operation is a distributed trace; a failed pre-handshake attempt may have no authenticated host/socket IDs. Trace references never assert successful remote ingestion.

## SDK-owned remaining work

- Tagged window-level shake callback with its secure/editing guards. Keep Go's current SDK shake receiver and enrollment explainer until adoption, then remove both receivers when wiring `onFeedbackShake`/`onNotEnrolled`. Never install both implementations. Reuse the event PNG and source window in Go's presenter; no second capture. Drop `showSettings` from suppression so the composer can present above Settings, while retaining pairing/restoring/error and typing suppression.
- Window motion hook must reject non-key/inactive windows, avoid duplicate delivery across scenes/windows, and chain the original implementation once. Go's `PassthroughWindow` is non-key; it overrides `canBecomeKey`/hit testing, not motion handling. No Go window-level replacement or production swizzle was added.
- Single-screen composer with top-bar Send, included-content summary and saved/queued/delivered status. Its one diagnostics switch must remove entries, incident and flat trace/span fields while preserving notes/image/app/build/session metadata. The current two-step SDK composer remains unchanged in this PR.
- Compatible diagnostics model/provider, frozen local persistence across retries, API capability handling, typed `Stats.blockedReason`, `lastSuccessAt` and live-instance count. Report `storage-failed` means accepted report / failed diagnostic blob; do not confuse it with a failed report.
- A bounded background report-delivery API is optional product work, not needed for these Go fixes. Without one, a report committed immediately before actual suspension waits for foreground. Go does not bypass SDK pause semantics.

## Privacy and validation

Enrollment already enables closed-enum telemetry independently of Connection diagnostics Off. This PR does not add automatic capture before enrollment, enable a separate collector, add content, or expand sent report data; no App Privacy/enrollment disclosure contradiction was found. SDK adoption must keep availability and the combined off switch honest in the composer summary. No UI claims the disabled report blob is attached.

Completed validation:

- `swift test --enable-code-coverage`: 870 passed.
- `scripts/coverage.sh --skip-tests --check`: passed; Transport 96.56%, Domain 94.54%.
- `swift test --package-path Vendor/Framebriar`: 66 passed.
- `scripts/verify-framebriar-vendor.sh`: all 26 files match the pinned source.
- Debug build-for-testing and Release build: passed (existing actor-isolation warnings remain).
- Final app tests: 21 passed, including actual hosting-view recreation, 20 retry/foreground cycles, timestamp/backoff/no-duplicate delivery, unexportable-reference filtering, unfinished-parent capture and the diagnostics-send gate.
- Preview smoke / feedback UI: 26 selected cases passed across runs. The first broad run passed 25/26 UI cases; `testScreenshotToggleOffOpensWithoutAttachment` timed out evaluating an XCTest UI query, then passed its explicit separate retry. All 17 preview smoke and all four screenshot/menu tests passed first time.
- `git diff --check`: passed.

All simulator work used private `simctl create` device `574FB53B-3CA2-493B-B95A-524644CD6768` (iPhone 17 Pro / iOS 26), shut down and deleted after testing. Local logs and xcresults are under ignored `build/feedback-validation/`. No live E2E, production feedback, physical phone, shared simulator, publication, merge, host app restart/update or contact with Framebriar was performed.

Remaining end-to-end proof: authorized physical iPhone shake after navigation/focus/dismissal and with accessibility Shake to Undo settings checked (effect unconfirmed); real screenshots with iOS Full-Screen Previews on/off; multi-window iPad callback delivery; then an explicitly authorized test destination after API/SDK adoption, verifying persisted diagnostic bytes and desktop joins. Simulator notification/motion fixtures do not prove real sensor or system screenshot-editor behavior.
