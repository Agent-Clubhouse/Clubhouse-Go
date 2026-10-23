# Framebriar for iOS

Native Swift 6.2 package, iOS 17+ (core also builds on macOS 14+). `Framebriar` contains the client, protocol, transport and storage; `FramebriarUI` is an optional SwiftUI enrollment form and iOS screenshot review form. There are no third-party dependencies or telemetry hooks.

This adapter follows the existing service at source `e76e08a`: `src/access.mjs`, `src/access-http.mjs`, `src/protocol.mjs`, `src/service.mjs`, and the browser's `playtest-access.mjs` / `submit-feedback.mjs`. It does not introduce server endpoints. Source changes here do not deploy or enable the issuer.

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

1. Obtain the user's notes and, optionally, an image they chose to attach. Do not take a screenshot in the background, on errors, on shake, or when opening feedback.
2. Create a `ReviewedFeedback`. Present its sanitized `notes` and exact `screenshotPNG` for review. Redaction is conservative and cannot detect every secret; the user must check their text and image. The optional UI decodes and re-encodes selected images to PNG to remove metadata. A custom host must sanitize metadata before constructing the review object.
3. On the user's Submit tap call `enqueue(reviewed)`. It returns only after the atomic local write succeeds. Retain the **same object and UUID** on a failed or uncertain save. Do not claim delivery when it is only saved locally.
4. Foreground `flush()` delivers later. `status().lastReceivedID` is set only after a matching server receipt and successful local removal. It is an in-memory latest receipt, not a persistent delivery history.

```swift
let reviewed = try ReviewedFeedback(configuration: config,
    notes: userNotes, reviewedScreenshotPNG: userReviewedPNG)
// Display reviewed.notes and reviewed.screenshotPNG, then on explicit confirmation:
let reportID = try await client.enqueue(reviewed)
```

Each report contains only the sanitized notes, optional PNG, configured game/build, fixed `scene=user-feedback`, `platform=ios`, `input=touch`, current timestamp and random report/session identifiers. `seed` is null and `breadcrumbs` is empty. No automatic capture, prompts, conversations, agent output, logs, telemetry, owner tokens, transport credentials, email addresses or device identifiers are collected. The SDK has no owner/master-token API.

## Enrollment and transport

- `connect(invitation:)` is an explicit user action, `POST /v1/access/redeem`, `{v:1, scopeVersion:2, invitation, gameId, buildSha, attemptId}`. Clear the password field immediately. A lost reply is not automatically retried; manually retrying the same invitation in the same client within 14 minutes reuses its attempt ID. The invitation/attempt exist only in memory. Process termination loses this recovery context; do not promise recovery of a spent invitation after a crash.
- `POST /v1/access/refresh` uses only `{v:1, scopeVersion:2, refreshToken}`. Access tokens are refreshed inside the final five minutes of their one-hour life, and never persisted. Refresh credentials and the original family deadline cannot rotate/extend during refresh. Issuer-selected deadlines up to its current 365-day maximum are accepted (default 30 days).
- Credentials are in a device-only, non-synchronizing Keychain record, accessible while unlocked. Invitations, access tokens and upload tickets are never queued or written to disk. Keychain errors fail closed; there is no plaintext fallback.
- `POST /v1/reports` sends the service's v1 report schema with a short-lived Bearer token. Text-only reports complete with `ready` or `processed`. Image reports may return `pending` with a five-minute ticket; the SDK uses `PUT /v1/reports/{id}/media` with Bearer + `x-upload-ticket`. A retry starts with the same report POST, obtaining a new ticket or a finalized receipt.
- The ephemeral URLSession disables cookies, credential storage and caches, refuses redirects, uses normal platform TLS validation, has 45-second request / 60-second resource timeouts, and bounds response bodies to 4 KiB. Error bodies are not surfaced or logged. Do not inject a transport that redirects credentials or logs requests.

## Queue and lifecycle behavior

Ten reports, 32 MiB total media, 8 MiB per PNG and 16 KiB per report metadata. Full queues reject the new submission without evicting another report. Notes are limited to 2,000 UTF-16 code units. The atomic JSON file includes bounded base64 image data and is held in a private, backup-excluded directory with complete iOS file protection. Do not place it in a shared container. No migration from browser/Godot/desktop stores is attempted.

The host must own one Client per endpoint/game scope. Store implementations are synchronous atomic operations; do not share these default stores across clients, processes or app extensions. Inject `HTTPTransport`, `EnrollmentStore`, `FeedbackStore`, and a clock for deterministic tests. Storage corruption or locked storage throws without resetting data. When device unlock restores storage, retry initialization; never replace a failed store with an empty one.

Reports do not age out locally. Transient errors retain the report, increment a saturated attempt counter, and use exponential backoff capped at five minutes, respecting `Retry-After` up to one day (quota minimum one minute). There is no busy-loop or unbounded request burst: at most ten reports per pass; service/network/access outages stop that pass. Permanent rejection/conflict retains and marks the report blocked. `clearQueuedFeedback()` is an explicit destructive local action; it does not delete server data or enrollment. No automatic maximum-age deletion or silent eviction occurs.

Expiry/revocation retains reports and local capture eligibility for previously enrolled users. A user who never enrolled cannot submit. Service pauses (`503`) preserve credentials and reports. `pause()` prevents follow-up requests and invalidates in-flight completions; already transmitted bytes cannot be recalled. `disconnect()` forgets enrollment first, retains the queue, then attempts `/v1/access/disconnect`; its Boolean result distinguishes confirmed revocation from local-only forgetting. The UI discloses this distinction. Explicitly clearing enrollment removes capture eligibility until re-enrollment.

Idempotency is bounded by the server's retention window. Retry the same immutable report ID/hash/metadata, including after replacement enrollment; do not promise exactly-once delivery after the server has deleted its seven-day context. Server media/context retention and the local age-unlimited bounded queue are different policies.

## Validation

```sh
swift test --package-path adapters/swift
node --test tests/swift-wire-contract.test.mjs
npm run check && npm test
python3 scripts/native-pin.py --check
```

The Swift tests use synthetic credentials, injected clocks and in-memory transports; they do not contact the service. A shared fixture checks the Swift report against the actual JS service normalizer. Tests cover text/image flows, same-UUID recovery, invite attempt reuse, early renewal/fixed deadlines, rejection, pause/disconnect races, expiry, storage failure, item/byte bounds, redaction, corrupt local files and durable backoff. Full live enrollment, issuer state, real-device Keychain/protection behavior, physical-device UI, provisioning and release remain separate approval/validation gates.
