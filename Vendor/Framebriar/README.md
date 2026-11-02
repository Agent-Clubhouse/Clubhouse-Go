# Framebriar for iOS

Native Swift 6.2 package, iOS 17+ (core also builds on macOS 14+). `Framebriar` contains the client, protocol, transport and storage; `FramebriarUI` is an optional SwiftUI enrollment form and iOS feedback composer. There are no third-party dependencies. Telemetry is optional: `Telemetry` sends enrolled-user traces, logs and metrics (see [Telemetry](#telemetry)).

This adapter follows the existing service and the optional incident v1 contract merged in PR #11: `src/access.mjs`, `src/access-http.mjs`, `src/protocol.mjs`, `src/service.mjs`, and the browser's `playtest-access.mjs` / `submit-feedback.mjs`. It does not introduce server endpoints. Source changes here do not deploy or enable the issuer.

## Add the package

In Xcode, add this `adapters/swift` directory as a local Swift Package and link `Framebriar`; link `FramebriarUI` only if using its views. For an app in a separate repository, vendor this directory with its manifest, Sources, Tests and README, and record the source commit. A Git remote package URL requires a manifest at the repository root; this monorepo subdirectory is not a remotely published package. Do not publish a new package or tag as part of integration.

## App-lifetime setup

Use the actual **server-approved game ID** for the mobile product. Do not infer enrollment scope from the bundle identifier or reuse a desktop invitation without owner confirmation. `buildSHA` is a real 7–40 lowercase hexadecimal source revision, or `nil`, never an app version. Storage scope is endpoint + game, stable across build upgrades.

```swift
import Framebriar
import FramebriarUI

// Application composition, once for the app's lifetime. Obtain approvedGameID from
// reviewed non-secret build configuration. Never put an invitation in build settings.
let config = try Configuration(gameID: approvedGameID, buildSHA: sourceRevision)
let directory = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask,
    appropriateFor: nil, create: true
).appendingPathComponent("Framebriar", isDirectory: true)
let client = try Client(
    configuration: config,
    enrollmentStore: KeychainEnrollmentStore(service: "MyApp.Framebriar"),
    feedbackStore: FileFeedbackStore(directory: directory)
)
let feedback = FeedbackModel(client: client) // MainActor
```

The client starts paused and makes **no network requests during initialization**. Have one foreground task call `setActive(true)` and `tick()` every 15 seconds; cancel that task and call `setActive(false)` on inactivity/background. Core-only integrations call `resume()`, `refreshAccess()` and `flush()`. Repeated calls respect stored report backoff. Do not install background upload tasks. A Settings sheet disappearing is not a disconnect and must not destroy the app-lifetime client.

```swift
NavigationLink("Invitation & enrollment") { EnrollmentView(model: feedback) }
if feedback.status?.canSubmit == true {
    NavigationLink("Send feedback") { FeedbackView(model: feedback) }
}
```

Render expired/access-required/offline notices outside Settings, including after startup. The Clubhouse Go companion integration demonstrates this. The sample intentionally leaves live scope unconfigured pending owner approval; no invitation redemption or upload was used for validation.

## Explicit submission without SwiftUI

1. Obtain the user's notes and, optionally, an image to attach: one they chose, or a screen capture taken on an explicit user gesture (the optional shake shortcut below). Do not take a screenshot in the background, on errors, or on a timer. A capture stays on the device until the user reviews and sends it.
2. Create a `ReviewedFeedback`. Show the user its sanitized `notes` and exact `screenshotPNG`. Redaction is conservative and cannot detect every secret; the user must check their text and image. The optional UI decodes and re-encodes selected images to PNG to remove metadata. A custom host must sanitize metadata before constructing the object.
3. On the user's Send tap call `enqueue(reviewed)`. It returns only after the atomic local write succeeds. Retain the **same object and UUID** on a failed or uncertain save. Do not claim delivery when it is only saved locally.
4. Call `deliver(reviewed.id)` for an immediate `FeedbackDeliveryOutcome`, and let foreground `flush()` deliver the rest. `status().lastReceivedID` is set only after a matching server receipt and successful local removal. It is an in-memory latest receipt, not a persistent delivery history.

```swift
let reviewed = try ReviewedFeedback(configuration: config,
    notes: userNotes, reviewedScreenshotPNG: userReviewedPNG)
// Display reviewed.notes and reviewed.screenshotPNG, then on an explicit Send:
let reportID = try await client.enqueue(reviewed)
let outcome = await client.deliver(reportID) // .sent only on a service receipt
```

Without optional incident references or [report diagnostics](#report-diagnostics), each report contains only the sanitized notes, optional PNG, configured game/build, fixed `scene=user-feedback`, `platform=ios`, `input=touch`, current timestamp, a random report ID and the per-run session ID `FramebriarSession.id` (shared with telemetry). `seed` is null and `breadcrumbs` is empty. No background capture, prompts, conversations, agent output, free-text logs, owner tokens, transport credentials, email addresses or device identifiers are collected. The SDK has no owner/master-token API.

## Enrollment and transport

- `connect(invitation:)` is an explicit user action, `POST /v1/access/redeem`, `{v:1, scopeVersion:2, invitation, gameId, buildSha, attemptId}`. Clear the password field immediately. A lost reply is not automatically retried; manually retrying the same invitation in the same client within 14 minutes reuses its attempt ID. The invitation/attempt exist only in memory. Process termination loses this recovery context; do not promise recovery of a spent invitation after a crash.
- `POST /v1/access/refresh` uses only `{v:1, scopeVersion:2, refreshToken}`. Access tokens are refreshed inside the final five minutes of their one-hour life, and never persisted. Refresh credentials and the original family deadline cannot rotate/extend during refresh. Issuer-selected deadlines up to its current 365-day maximum are accepted (default 30 days).
- Credentials are in a device-only, non-synchronizing Keychain record, accessible while unlocked. Invitations, access tokens and upload tickets are never queued or written to disk. Keychain errors fail closed; there is no plaintext fallback.
- `POST /v1/reports` sends the service's v1 report schema with a short-lived Bearer token. Text-only reports complete with `ready` or `processed`. Image reports may return `pending` with a five-minute ticket; the SDK uses `PUT /v1/reports/{id}/media` with Bearer + `x-upload-ticket`. A retry starts with the same report POST, obtaining a new ticket or a finalized receipt.
- The ephemeral URLSession disables cookies, credential storage and caches, refuses redirects, uses normal platform TLS validation, has 45-second request / 60-second resource timeouts, and bounds response bodies to 4 KiB. Error bodies are not surfaced or logged. Do not inject a transport that redirects credentials or logs requests.

## Queue and lifecycle behavior

Ten reports, 32 MiB total media, 8 MiB per PNG, 16 KiB per report metadata and 64 KiB per report for diagnostics. Full queues reject the new submission without evicting another report. Notes are limited to 2,000 UTF-16 code units. The atomic JSON file includes bounded base64 image data and is held in a private, backup-excluded directory with complete iOS file protection. Do not place it in a shared container. No migration from browser/Godot/desktop stores is attempted.

The host must own one Client per endpoint/game scope. Store implementations are synchronous atomic operations; do not share these default stores across clients, processes or app extensions. Inject `HTTPTransport`, `EnrollmentStore`, `FeedbackStore`, and a clock for deterministic tests. Storage corruption or locked storage throws without resetting data. When device unlock restores storage, retry initialization; never replace a failed store with an empty one.

Reports do not age out locally. Transient errors retain the report, increment a saturated attempt counter, and use exponential backoff capped at five minutes, respecting `Retry-After` up to one day (quota minimum one minute). There is no busy-loop or unbounded request burst: at most ten reports per pass; service/network/access outages stop that pass. Permanent rejection/conflict retains and marks the report blocked. `clearQueuedFeedback()` is an explicit destructive local action; it does not delete server data or enrollment. No automatic maximum-age deletion or silent eviction occurs.

Reports saved under another enrollment are held; see "Reports and enrollment changes". Expiry/revocation retains reports and local capture eligibility for previously enrolled users. A user who never enrolled cannot submit. Service pauses (`503`) preserve credentials and reports. `pause()` prevents follow-up requests and invalidates in-flight completions; already transmitted bytes cannot be recalled. `disconnect()` forgets enrollment first, retains the queue (held from the next enrollment), then attempts `/v1/access/disconnect`; its Boolean result distinguishes confirmed revocation from local-only forgetting. The UI discloses this distinction. Explicitly clearing enrollment removes capture eligibility until re-enrollment.

Idempotency is bounded by the server's retention window. Retry the same immutable report ID/hash/metadata, including after an explicit release under a replacement enrollment; do not promise exactly-once delivery after the server has deleted its seven-day context. Server media/context retention and the local age-unlimited bounded queue are different policies.

## Reports and enrollment changes

A report never delivers under a different enrollment than it was saved under. The full contract, including what happens on a downgrade, is in [docs/general-feedback-v2.md](../../docs/general-feedback-v2.md#reports-and-enrollment-changes). **TestFlight users can downgrade**, and the Swift limit there matters: once an older build saves its queue, reports that were held stay blocked after you upgrade again and can't be released, only cleared.

`FeedbackView` handles a changed enrollment: it keeps the note and image, recaptures, updates the Included summary, shows a notice, and waits for a new Send. `EnrollmentView` shows the held count with Send and Clear actions. For a custom screen, `FeedbackModel` does everything those do:

```swift
let status = model.status                // heldForEnrollment, heldBytes, releaseToken
// Keep status?.releaseToken from what the user saw when they confirm. A fresh one defeats the check.
let result = await model.releaseHeldReports(releaseToken: confirmedToken)  // released, remaining, failed, code
let cleared = await model.clearHeldReports()                               // works unenrolled
```

- `FeedbackModel.save` throws `FramebriarError.enrollmentChanged` (`.code == "enrollment-changed"`), and `send` returns `.needsAttention(.enrollmentChanged)`. Nothing was saved and that draft can't send again. Call `openDraft()` for a new ID and new captures, then wait for a new Send.
- `.needsAttention(.heldForEnrollment)`: saved under a previous enrollment and not sent.
- `result.code` is `"stale-release"`, `"not-enrolled"` or nil. `released` doesn't mean delivered.
- `Client.enqueue(_:)` without a ref is deprecated. It binds to the enrollment at the call, for a report with no open draft, as does the deprecated `FeedbackModel.submit`. Use `enqueue(_:enrollmentRef:)` with `FeedbackDraft.enrollmentRef`.

`AttentionReason` gained two cases and stays a plain enum, so an exhaustive `switch` surfaces them at compile time.

**Testing your host.** `Client` takes an in-memory `EnrollmentStore` and `FeedbackStore` and a fake `HTTPTransport`, as in `Tests/FramebriarTests/HeldReportsTests.swift`. Enqueue, then connect again to get a held report. Pass an old token for `stale-release`, disconnect for `not-enrolled`, and make the store's `save` throw after one call for a partial release. Shapes are in `Tests/FramebriarTests/Fixtures/held-reports-v1.json`.

## Validation

```sh
swift test --package-path adapters/swift
node --test tests/swift-wire-contract.test.mjs tests/swift-telemetry-contract.test.mjs
npm run check && npm test
python3 scripts/native-pin.py --check
```

The Swift tests use synthetic credentials, injected clocks and in-memory transports; they do not contact the service. A shared fixture checks the Swift report against the actual JS service normalizer. Tests cover report diagnostics (all states, allowlist, trimming, the shared fixture, frozen wire bytes across retries and relaunch), the composer's summary and result states, the shake screenshot policy (secure-field suppression, pixel/byte caps and downscaling, composer pre-fill validation), text/image flows, same-UUID recovery, invite attempt reuse, early renewal/fixed deadlines, rejection, pause/disconnect races, expiry, storage failure, item/byte bounds, redaction, corrupt local files and durable backoff. Full live enrollment, issuer state, real-device Keychain/protection behavior, physical-device UI, provisioning and release remain separate approval/validation gates.

## The composer

`FeedbackView` is one screen: notes, the image with Replace and Remove, a pinned summary of what will be sent, one switch for diagnostics, and **Send** in the top bar. There is no review step: the Send tap is the consent. Shake and screenshot triggers only open it. While Send is unavailable, a line at the top says why.

The summary is built from the values that go on the wire, for example `Included: note · screenshot · recent diagnostics (12 events)`. Every statement the composer makes about content or delivery lives in [`FeedbackDisclosure.swift`](Sources/FramebriarUI/FeedbackDisclosure.swift), so that's the one file to review.

After Send:

1. The report is committed locally first (`FeedbackModel.save`). If that fails, the composer stays open with the draft and says why, and sending again keeps the same report ID.
2. One delivery attempt for that report runs at once (`FeedbackModel.deliver`). **Done** is available from here, and closing doesn't cancel the attempt.
3. The screen shows the outcome:

| `FeedbackDeliveryOutcome` | Shown as | Report |
|---|---|---|
| `.sent` | Sent | Service receipt confirmed, removed from the queue |
| `.saved(.offline)`, `.saved(.paused)` | Saved, will send when online / later | Kept. Sends when the app is open and online |
| `.saved(.serviceBusy)`, `.saved(.waitingForService)` | Saved, will send later | Kept and retried, while the app is open |
| `.needsAttention(.accessRequired)` | Needs attention | Kept. Needs a new invitation |
| `.needsAttention(.rejected)` | Needs attention | Kept and marked blocked until cleared |
| `.needsAttention(.heldForEnrollment)` | Needs attention | Saved under a previous enrollment and not sent. Kept until the user sends or clears it from the enrollment screen |
| `.needsAttention(.enrollmentChanged)` | Needs attention | Not saved. The composer keeps the note and image, recaptures, and waits for a new Send |
| `.needsAttention(.storageFull)`, `(.storageUnavailable)` and other not-saved reasons | An error in the composer | Not saved. The draft is still open |

There is no background delivery in this release. A saved report waits for the host's foreground `tick()`.

A custom composer can use the same parts: `model.openDraft()` once when it opens, `draft.summary(...)`, then `model.save(...)` and `model.deliver(...)`, or `model.send(...)` for both.

## Report diagnostics

A report can carry its own bounded recent diagnostics (`report.diagnostics`, v1, `docs/feedback-diagnostics-v1.md` in the service change). Unlike the telemetry excerpt, they travel with the report through the offline queue.

**Don't ship this SDK to users before that service change is deployed.** The deployed service drops the unknown field and still acknowledges the report, so diagnostics are silently lost while the composer says they were included. It also refuses a body over 16 KiB with a 413, which the queue treats as permanent, so a large excerpt blocks its report. Nothing makes a report depend on the field: it can be omitted, and existing `ReviewedFeedback` callers send no field at all.

```swift
let feedback = FeedbackModel(client: client, telemetry: telemetry, diagnosticsProvider: {
    FeedbackDiagnostics(windowStart: start, windowEnd: end, entries: records.map {
        .init(at: $0.date, level: .warn, ns: "transport", event: "connect.failed",
              attrs: ["failure": "timeout", "attempt": 2, "closeCode": 1006, "connectionId": .string(id)])
    }, dropped: alreadyDropped)
})
```

The provider runs on the main actor, once, when a composer opens. It must be synchronous and do no I/O. The result is frozen and stored with the queued report, so every retry, including after a relaunch, sends the same bytes. The switch only chooses whether the frozen capture goes out; it never runs the provider again. A reentrant `openDraft()` while the provider runs (say a provider that synchronously notifies something that opens feedback) gets an empty `unavailable` draft and doesn't call the provider again.

| State | When | Entries |
|---|---|---|
| `attached` | The provider or ring had entries | Yes |
| `none` | `empty`: the provider returned nil or nothing was recorded. `no-provider`: no provider and no `Telemetry` | No |
| `left_out` | The user switched diagnostics off. Also removes `incident`, the flat `traceId`/`spanId` and `delivery`. Notes, image, app, build and session remain | No |
| `unavailable` | `provider-failed`: the provider threw. `invalid`: unusable output | No |

Enrollment isn't one of these states: a report filed while the app's connection is down still attaches its failure entries. Nothing here ever blocks Send.

With no provider, the `Telemetry` ring is used, including events already exported (the report's copy is independent). OTel names map where there's an obvious match (`http.response.status_code` to `statusCode`, `error.type` and `app.error.class` to `failure`), and everything else goes through the allowlist. Hosts can read the same thing with `telemetry.diagnosticsSnapshot()`.

**Limits**, enforced before sending: 64 KiB serialized in total, 500 entries (oldest trimmed first and counted in `dropped`), tokens `^[A-Za-z0-9_.:+-]{1,64}$` with no free-text field. A well-formed token that looks like a secret (`ghp_…`, `token:abc`) becomes `redacted`.

**Attribute allowlist.** Anything else is dropped and counted in `droppedAttrs`, as is any value failing its rule. Mirrored from the service's `DIAGNOSTICS_CONTRACT` and checked against its shared fixture.

| Keys | Rule |
|---|---|
| `attempt`, `backoffMs`, `snapshotBytes`, `webSocketMessageLimitBytes`, `transportFrameLimitBytes`, `durationMs`, `count`, `bytes`, `responseBytes`, `requestBytes`, `connectMs`, `tlsMs`, `firstByteMs` | Number ≥ 0 |
| `statusCode` / `closeCode` / `exitCode` | Integer 100–599 / 1000–4999 / 0–255 |
| `failure` | `timeout`, `tls`, `dns`, `refused`, `closed`, `oversize`, `overflow`, `busy`, `storage`, `auth`, `protocol`, `cancelled`, `server`, `offline`, `unknown`. Anything else becomes `unknown` |
| `link` | `mtls`, `bearer`, `unknown`. Anything else becomes `unknown` |
| `operation` | Token |
| `fromState`, `toState`, `reason`, `provider`, `driver` | `^[a-z0-9][a-z0-9_.-]{0,31}$` |
| `connectionId`, `attemptId` | UUID, lowercased |
| `traceId` / `spanId` | 32 hex or a UUID / 16 hex, lowercased |
| `peerRef`, `agentRef` | Exactly `^[0-9a-f]{16}$`. Uppercase is dropped |

`delivery` is stamped by the SDK from the client's state at capture: `queued`, and `lastResult` (`ok`, `none` for no attempt in this process, or a `failure` value).

## Optional shake shortcut

Settings → Send feedback is always available to eligible enrolled users. To also use the shake gesture, install one of these once at the scene root. Either opens the composer and never submits. By default (`captureScreen: true`) the screen that was showing is captured and attached for review.

```swift
@AppStorage("feedback.shakeEnabled") private var shakeEnabled = true
@AppStorage("feedback.shakeCapturesScreen") private var shakeCapturesScreen = true
// In Settings:
Toggle("Shake to open feedback", isOn: $shakeEnabled)
Toggle("Attach a screenshot when you shake", isOn: $shakeCapturesScreen)

// Simplest: the SDK presents the composer over whatever is showing, sheets included.
content.shakeToOpenFeedback(model: feedback, enabled: shakeEnabled,
                            isPresenting: pairingOrRestoring, captureScreen: shakeCapturesScreen)

// Or route to your own presenter:
content.onFeedbackShake(model: feedback, enabled: shakeEnabled, isPresenting: pairingOrRestoring,
                        captureScreen: shakeCapturesScreen, onNotEnrolled: { explainEnrollment() }) { event in
    myPresenter.presentComposer(from: event.window, screenshot: event.screenshotPNG)
}
```

Use `event.window` and `event.screenshotPNG` as given: the capture came from that window, before anything opened. The default presenter uses a `UIHostingController`, because a SwiftUI sheet on the root can't open over another sheet; SwiftUI environment values from your root don't reach it, so a themed host should use the callback.

**Guards.** A shake does nothing unless all of these hold: the host's `enabled` is on and `isPresenting` is off; the user can file feedback (`canSubmit`, including previously enrolled users saving locally; otherwise `onNotEnrolled` runs if you gave one); the window is the key window of a foreground-active scene; no `FeedbackView` for this model is open; the top view controller isn't an alert or mid-transition; and no text input is active. Repeated motion is debounced for two seconds, and presentation boundaries restart that delay. `isPresenting` now means "suppress shakes right now". Don't pass ordinary sheets in it, or shake stays off over them.

**While typing, a shake is ignored**, in plain and secure fields alike. Focus and the draft are never touched, and iOS's own Shake to Undo alert behaves as usual. The menu entry is the route to feedback while typing.

**How it works, and what it adds at runtime.** There's no first responder to claim or lose. On first use, the SDK adds one method to `UIWindow` through the Objective-C runtime: `motionEnded(_:with:)`, once, thread-safely. It reports shakes, then calls whatever implementation `UIWindow` already resolved to, exactly once, so the responder chain and existing overrides carry on. It touches nothing else, doesn't touch `UIApplication`, and collects no motion samples. No `UIWindow` subclass is needed. UIKit sends motion events to the first responder and up the responder chain, which passes through the window. With nothing first responder, the injected event still reached the key window on the simulator (including under SwiftUI and over sheets); Apple's documentation doesn't describe that case.

**Caveats:**
- A `UIWindow` subclass that overrides `motionEnded` without calling `super` hides the event from the SDK. So does a responder lower in the chain that handles the motion without calling `super`. A non-key subclass like an overlay's passthrough window is unaffected.
- **All of this is verified with simulator-injected motion only** (see [Harness/README.md](Harness/README.md)), on iOS 18.2 and 26.0, including an iPad with two scenes. The simulator's shake notification doesn't exercise a device's sensors.
- **Whether turning off Settings → Accessibility → Touch → Shake to Undo suppresses shakes on a real device is unproven.** With `UIAccessibility.isShakeToUndoEnabled` false in a simulator, the injected event still arrived, but that can't speak for hardware, and no developer documentation we found settles it. Keep a menu entry for feedback either way.

The core package does not depend on motion APIs; this is entirely optional `FramebriarUI` behavior. The SDK does not enable a preference by itself: the host supplies `enabled`. Notes start empty every time.

### Shake screenshot

On an accepted shake, and before anything is presented, the SDK renders that window with `UIGraphicsImageRenderer` and `drawHierarchy(in:afterScreenUpdates: false)`, so the composer itself is never in the image. `ShakeScreenshot` encodes it as a metadata-free PNG within the report limits (8 MiB, at most 20 MP and 8192 px per side), downscaling if needed; if it cannot fit, no image is attached.

- The capture happens **on the device** and is held only in memory by the composer. It is not written to the queue or sent anywhere until the user taps **Send**.
- `FeedbackView(model:initialScreenshotPNG:)` shows it attached for review, with **Remove** and **Replace screenshot**. Cancelling the composer discards it.
- No capture is taken while a secure text field is first responder. (Shakes are ignored during text input anyway; this is a second check.)
- Pass `captureScreen: false` to open an empty composer instead. Hosts should expose this as a setting, e.g. "Attach a screenshot when you shake", and pass `false` for scenes that should never be captured.
- Screen pixels can contain private text, and redaction is not image OCR: the user must review the image before sending.

## Migrating from the Review step (Clubhouse Go)

Source-compatible: `FeedbackView(model:initialScreenshotPNG:)`, `ReviewedFeedback.init` (`diagnostics:` is a new defaulted parameter), `FeedbackModel(client:telemetry:incidentProvider:)`, `shakeToOpenFeedback(...)` and `Client.enqueue` all still compile. `FeedbackModel.submit` still works and is deprecated: use `save` and `deliver`.

**Order: deploy the service first.** See [Report diagnostics](#report-diagnostics).

1. **Provider.** Pass `diagnosticsProvider:` (above), mapping your diagnostic records. Keep it memory-only. Without it you get the `Telemetry` ring.
2. **Shake.**
   - Take `showSettings` and other ordinary sheets out of `isPresenting`, or shake stays off over them. Keep flags for flows that shouldn't be interrupted, like pairing and restore.
   - To use your own presenter, switch to `onFeedbackShake(...)` and present from `event.window` with `event.screenshotPNG`.
   - Replace `EnrollmentShakeReceiver` with `onNotEnrolled:`.
   - **Shake is ignored while typing.** Say so in your help copy; the menu entry is the route then.
   - Check for `motionEnded` overrides in your responders that don't call `super`.
3. **Wording.** "Review feedback" and "Submit reviewed feedback" are gone, so update copy that mentions them, such as Settings help text and `FRAMEBRIAR_INTEGRATION.md`. Remove "Include incident trace references" from anything describing the form: the one switch covers diagnostics and incident references. Your own disclosure mentioning reports should say they can include recent diagnostics.
4. **UI tests.**
   - Removed: buttons `Review feedback`, `Submit reviewed feedback`, `Remove attachment`, `Choose screenshot to review`.
   - Kept: `framebriar-attachment`, `framebriar-captured-screen-note`.
   - New: `framebriar-send`, `framebriar-send-reason`, `framebriar-included`, `framebriar-diagnostics-switch`, `framebriar-remove-attachment`, `framebriar-notes`, `framebriar-result-title`, `framebriar-result-detail`, `framebriar-done`, `framebriar-error`.
   - A fixture that calls `motionEnded` on the first responder gets nothing when there is no first responder. Post the Darwin notification `com.apple.UIKit.SimulatorShake` instead, as `Harness/UITests` does, which on the simulator goes through UIKit's real delivery.
5. **Queues** from older builds still load: a report with no field sends no field.

## Independent incident correlation (v1)

The optional `FeedbackIncident` value follows `docs/incident-correlation-v1.md`. It holds only bounded trace/span references, opaque process/socket IDs and an optional logical tracing-destination UUID. It never configures or exports telemetry. The service may use a different backend from the phone and host.

Pass a synchronous main-actor provider to `FeedbackModel(client:incidentProvider:)`. `FeedbackView` calls the provider once when the composer first appears, lists incident references in its summary, removes them with the diagnostics switch, and persists the snapshot with `ReviewedFeedback.incident`. Hosts using a custom composer snapshot once at open (`model.openDraft()` does this), then pass `incident:` to `ReviewedFeedback` on Send. Do not refresh this value while composing, retrying or restoring the queue. A provider may return `nil`; old calls without a provider remain valid.

```swift
let model = FeedbackModel(client: client, incidentProvider: {
    // Construct from validated process/socket IDs and already recorded local spans.
    // No addresses, payloads, private text, automatic captures, or new tracing here.
    localIncidentSnapshot()
})
```

`FeedbackIncident` is immutable, Codable and Sendable. Its throwing initializer and `validate()` check v1 IDs/times/bounds; decoded queue data is validated again by the client. Existing queues decode without an incident. The report's legacy flat trace/span fields mirror the first incident trace, and are absent when no trace was recorded.

`Client` holds incident-bearing feedback until the current redeem/refresh response advertises numeric `feedbackCorrelationVersion: 1`. `ClientStatus.correlationWaiting` exposes that hold. Capability is not persisted and is cleared on pause, token failure, disconnect and restart; ordinary reports continue to work against older services. A refresh can remove support and must hold reports again. No incident is stripped to force delivery. Queue retention remains until delivered or explicitly cleared.

The service change must be separately deployed before incident feedback can upload. Merging SDK source or changing a vendor pin does not deploy the service or enable telemetry. There is no published Swift release; pin the entire `adapters/swift` directory to an immutable upstream commit and verify file hashes. Hosted CI tests the core/optional UI package on macOS and compiles the optional iOS UI without signing.

## Telemetry

`Telemetry` is an optional, enrollment-gated emitter for traces (spans with events), logs and delta metrics (counters, gauges and exponential histograms). It has no dependencies and keeps everything in memory only: nothing is written to disk or retried after a relaunch.

**One `Telemetry` per `Client` per process.** A `Client` starts paused, and a paused `Client`'s `Telemetry` gets no token, so it holds records in memory until the client resumes (bounded at 1 MiB, oldest dropped). A second instance bound to a client nobody resumes looks like lost telemetry. To check:
- `Telemetry.liveInstanceCount` counts instances alive in the process that haven't been disposed. Assert on it in tests. The SDK enforces nothing and logs nothing.
- `stats().blockedReason` says why records aren't leaving: `none`, `noToken` (`no-token`, including a paused client), `backoff`, `forbidden` or `disabled` (not enrolled, or disposed).
- `stats().lastSuccessAt` is the last 2xx from the gateway in this process.

**Transport.** Standard OTLP/HTTP JSON goes to the enrollment route `POST {endpoint}/v1/otlp/v1/{traces,logs,metrics}` with `Authorization: Bearer <access token>`, as one request per signal present in a batch. The gateway (`src/telemetry.mjs`) also accepts the browser/Node `/v1/telemetry` envelope. This route was chosen because on it the gateway:
- reads `service.version` as a semver such as `1.4.0+57`, whereas the envelope route only takes a commit SHA and otherwise stamps `unknown`;
- reads the resource `session.id`;
- matches desktop Clubhouse (`framebriar.source = otlp-enrollment`);
- needs no server change or deploy.

`tests/swift-telemetry-contract.test.mjs` replays the Swift output through the real handler and checks that nothing is dropped.

**Access.** `Client.telemetryToken(refresh:)` supplies the current one-hour access token. It returns nil when not enrolled, paused, expired or revoked, and never persists or logs the token. `Client.enrollmentSignal` is a credential-free, thread-safe enrollment view. The emitter:
- records nothing while not enrolled (every call is a no-op);
- forgets its queue, metric series and excerpt ring the moment enrollment is cleared (`disconnect()`), revoked (refresh 401/403) or expires;
- stops on a 403 until the user enrolls again.

**Batching and status handling:**
- **Flush triggers:** every 60 s, at 200 items or 64 KiB, on `flush()`, and when the app enters the background or terminates.
- **Bounds:** each batch is at most 248 KiB. The memory queue is 1 MiB and drops the oldest items first. Each item is at most 32 KiB.
- **Responses:**
  - 2xx: done.
  - 400 / other 4xx: drop the batch.
  - 401: refresh once and retry. If no token is available (paused/offline), keep the batch.
  - 403: stop and clear.
  - 413: split the batch in half, or drop a single item.
  - 429: honour `Retry-After` (default 60 s, at most 1 h).
  - 408 / 5xx / network: exponential backoff from 5 s up to 10 min, with jitter.
- **No session byte cap:** volume is bounded by the gateway's per-player and per-app quotas.

**Background flush.** On `UIApplication.didEnterBackgroundNotification` / `willTerminateNotification`, the emitter starts a `beginBackgroundTask` and drains up to four batches. The host usually pauses `Client` at the same moment, so this flush reuses the last access token obtained in this process (memory only). If that token is rejected, the data stays queued for the next foreground. Pass `observeAppLifecycle: false` and call `flushForBackground()` yourself if you prefer.

**Correlation** ([docs/correlation.md](../../docs/correlation.md)):
- **One session ID:** `FramebriarSession.id` (a random lowercase UUID per process) is both the report `sessionId` and the resource `session.id`.
- **Submit marker:** `feedbackSubmitted(reportID:trace:includeDiagnostics:)` runs after `Client.enqueue` commits. It emits the `feedback.submitted` log with `feedback.report.id` and the incident's first trace/span. With consent, it also re-sends the last 5 minutes of spans and logs not already delivered (at most 200 each), tagged `feedback.excerpt=true`, then flushes.
- **FeedbackModel:** `FeedbackModel(client:telemetry:incidentProvider:diagnosticsProvider:)` does this for you after the delivery attempt. The composer's one diagnostics switch controls this excerpt too.
- **Excerpt-only mode:** `mode: .excerptOnly` sends nothing until a report is submitted, and metrics are off.

**Incident buffers.** A host that already records spans locally (Clubhouse Go's incident ring) exports them with `record(RecordedSpan)`, which keeps the span's events, status, kind and parent. `recentTraces()` returns up to eight recent trace references from the SDK's own ring for a `FeedbackIncident` snapshot.

```swift
let telemetry = try Telemetry(client: client, configuration: config,
    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
    commonAttributes: ["app.telemetry.schema_version": 1, "app.platform": "ios"])
let feedback = FeedbackModel(client: client, telemetry: telemetry, incidentProvider: { ... })

telemetry.log(.info, "app.session.start")
try await telemetry.withSpan("app.flow", attributes: ["app.flow.name": .enumeration(Flow.pair)]) { span in
    span.addEvent("found", ["discovered_count": 2])
    try await pair()                     // nested spans and logs are parented automatically
}
telemetry.counter("app.reconnects", unit: "{reconnect}").add(1, ["error.type": .enumeration(failure)])
telemetry.histogram("app.first_token.duration", unit: "ms").record(ms)
telemetry.recordError(class: "decode_failed", error)  // type name only, never the message
```

**Attributes.** Attributes are typed (`TelemetryValue`: string, int, double, bool; prefer `.enumeration(_:)` for strings). Bounds: 32 per item, keys up to 128 characters, strings up to 1 KiB. Keys that look secret (token, auth, password, email, ...) and `framebriar.*` keys are dropped. Token timings and counts (`firstTokenMs`, `tokens.count`) are kept. Strings are scrubbed for URLs, emails, credentials and home-directory paths. Follow the `app.*` conventions in [docs/app-telemetry-v1.md](../../docs/app-telemetry-v1.md), and never pass prompts, file paths, repo/host names or user text.

**MetricKit (iOS).** `MetricKitDiagnostics(telemetry:).start()` forwards crash, hang, CPU-exception and disk-write-exception diagnostics as `app.error` logs. They carry closed classes plus numbers only (Mach exception type/code, signal, durations), with no call stacks or termination strings. iOS delivers them on a later launch, and they are discarded if not enrolled at that point.

### Clubhouse Go integration recipe

1. **Construct once** in `CompanionAppRoot`, next to the existing `Client`/`FeedbackModel` (`CompanionFeedback.swift`), using the same `Configuration` (`clubhouse-annex`). Pass `appVersion`/`appBuild` from Info.plist, and `commonAttributes` with `app.telemetry.schema_version` and `app.platform`. Hand it to `FeedbackModel(client:telemetry:incidentProvider:)`. Skip it entirely when `persistsDrafts` is false (test mode).
2. **Lifecycle:** keep the existing 15 s foreground `tick()`. Background flush is automatic. Log `app.session.start` once at launch, and `app.lifecycle` (`foreground`/`background`) from `scenePhase`, instead of the current zero-work spans.
3. **Crashes and hangs:** start `MetricKitDiagnostics` at launch.
4. **Key flows first:**
   - `app.flow` spans for `pair`, `connect`/`reconnect`, `restore` and `chat_turn`, with `app.outcome`.
   - Export the `AnnexTelemetry` ring's completed spans through `record(_:)` so their events (`firstToken`, `gap`, `overflow`) are kept. Map `AnnexDiagnosticFailure` to `error.type`, `statusCode` to `http.response.status_code`, and namespace the rest as `annex.*`.
   - Don't export successful `ping` spans; count them instead.
5. **Errors:** `recordError(class:)` with `AnnexDiagnosticFailure` raw values.
6. **Settings copy:** the SDK `EnrollmentView` shows the required disclosure when `telemetry` is set. If the app has its own enrollment text, add "Connecting also shares performance and diagnostic data with the developer."
7. **Owner side (not code):** the registry entry must not have telemetry off (`admin games set clubhouse-annex --telemetry on` if it does), with Mason's go-ahead. Until then the gateway answers 403, and the emitter stops quietly until the next enrollment.

### Privacy manifest (PrivacyInfo.xcprivacy)

Apps that turn on `Telemetry` must declare, under `NSPrivacyCollectedDataTypes`:
- `NSPrivacyCollectedDataTypePerformanceData` and `NSPrivacyCollectedDataTypeCrashData` (crash data only if using MetricKit);
- `NSPrivacyCollectedDataTypeOtherDiagnosticData`, which also covers incident references on feedback.

For each one:
- **Purpose:** `NSPrivacyCollectedDataTypePurposeAppFunctionality` (and Analytics if used for product decisions).
- **Linked:** `NSPrivacyCollectedDataTypeLinked = false`. The server stamps a pseudonymous per-enrollment player ID, and no account is involved.
- **Tracking:** `NSPrivacyCollectedDataTypeTracking = false`.

The SDK itself uses no required-reason APIs. The App Store privacy label should match.
