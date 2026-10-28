# Framebriar integration handoff

The Companion interface uses the complete native SDK from `masra91/framebriar` commit `9a1175e61e0bd5738add9197974c48d3c5caa1e3`, subdirectory `adapters/swift`. This is the head of upstream PR masra91/framebriar#15 (shake screenshot), pinned before that PR merged; re-pin to the merge commit if its SHA differs. All 18 upstream files are vendored unchanged; `Vendor/Framebriar/SOURCE.json` records their SHA-256 hashes. There are no local SDK patches. The package remains local because the upstream repository root is not a Swift package.

## What changed

- `Vendor/Framebriar`: pinned, independent local Swift Package with `Framebriar` core and optional `FramebriarUI`; see its README for wire/storage/privacy details.
- `Companion/Views/CompanionFeedback.swift`: composition adapter and Settings rows. It has no reference to prompts, agent history, transport credentials, trust registry, or logs.
- `Companion/Views/CompanionAppRoot.swift`: owns one feedback model for the app lifetime, drives foreground-only delivery, and shows expiry/access/offline notices outside Settings. Settings exposes invitation redemption, enrollment clear, queue count/capacity, retry/clear, and explicit feedback review.
- `Annex.xcodeproj`: links the two local package products. Signing and network configuration are unchanged.
- `FramebriarIntegrationTests`: checks the registered mobile scope and verifies, using memory stores and mock transport, that foreground activation does not enroll or send requests before explicit enrollment.

`--companion-preview` and nonpersistent test runtime do not start feedback.

## Registered mobile configuration and explicit enrollment

`Annex/Info.plist`, used by both Debug and Release, supplies the non-secret `FramebriarGameID` **`clubhouse-annex`**. The existing Framebriar registry at revision 19 was verified read-only on 2026-10-24: this enabled scope maps to `Agent-Clubhouse/Clubhouse-Go`. Desktop uses the separate `clubhouse` scope. The mobile ID is supported by that registry mapping, not inferred from the similarly named Bonjour service. The SDK's fixed service base is `https://framebriar-masra91-poc.azurewebsites.net/api`.

Configuration enables Invitation & enrollment in Settings; it does not grant access or enroll automatically. Missing configuration or unavailable protected storage still fails closed. Do not add an invitation, access token, refresh token, owner/master token or connection string to the repository or build configuration.

When the user chooses to enroll:

1. Open Desktops & settings → Invitation & enrollment and enter an owner-issued v2 invitation for the mobile scope. The secure field is cleared immediately.
2. Open Send feedback, type notes and optionally choose an image with the system photo picker, review the image and optional incident references, then Submit reviewed feedback. The SDK captures the screen only on a shake (see below), never in the background. Submission confirms a protected local save; only a matching service receipt confirms delivery.
3. Incident-bearing reports remain queued until a current access response advertises `feedbackCorrelationVersion: 1`; an older service cannot cause their metadata to be dropped or sent without that capability. Ordinary reports retain their existing delivery behavior.

Live enrollment/delivery and any service deployment remain separate validation. This consumer update does not issue invitations, register an app, modify credentials or deploy the service. `FramebriarBuildSHA` is optional and remains omitted.

Runtime initialization fails closed on storage/Keychain errors. A protected-data lock may require recreating the runtime after device unlock/app relaunch; it never falls back to plaintext or empties the queue. Default file storage is single-client/process only; do not also initialize it from an extension. No cross-platform migration is attempted.

## Validation

```sh
swift test --package-path Vendor/Framebriar
swift test
```

The SDK tests use synthetic credentials and inject network/storage/clock. `FramebriarIntegrationTests` (app unit tests) `FramebriarShakeUITests` and `FramebriarShakeDiagnosticsUITests` (app UI tests) run in CI with the rest of the app suites; see `docs/testing.md`. Photo picker/accessibility flows, actual device Keychain/file protection and live enrollment remain device acceptance gates.

## Shake shortcut

The optional shortcut opens the same composer as Settings → Send feedback on a recognized shake. It does not send, enroll, or start telemetry. The user reviews the exact notes and image and explicitly taps Submit reviewed feedback.

### Shake screenshot

With “Attach a screenshot when you shake” on (`CompanionFeedback.shakeScreenshotPreferenceKey`, default on), the SDK captures the key window on the device before the composer appears. It uses `drawHierarchy(afterScreenUpdates: false)`, so the composer itself isn't in the image, and encodes a PNG within 8 MiB / 20 MP, downscaled if needed. The screenshot is pre-attached for review:

- The user can tap **Remove attachment** or replace it from Photos.
- It is held in memory only; Cancel discards it.
- It is saved and sent only if the user taps **Submit reviewed feedback**.
- No capture is taken while a secure text field is first responder.

Turning the toggle off (it is disabled while shake itself is off) opens an empty composer. `CompanionAppRoot` passes the preference as `shakeToOpenFeedback(..., captureScreen:)`. The Settings privacy copy states this. Screens can show private text, such as conversation content, which is why the image is always shown for review and never sent without Submit.

`CompanionFeedback.shakePreferenceKey` is a local `AppStorage` preference, default on for eligible enrolled users. The Settings toggle “Shake to open feedback” disables the shortcut; Settings → Send feedback remains available. The root `shakeToOpenFeedback` modifier is eligible only for an active scene and `canSubmit == true`. Host flags and UIKit presentation checks suppress sheets/alerts/pickers, active text input is not displaced, and repeated motion/presentation boundaries are debounced for two seconds.

The DEBUG-only `--framebriar-shake-ui-testing` fixture (`FramebriarShakePreview`) has in-memory storage and a transport that always throws without opening a socket; it never restores a paired desktop. `--framebriar-shake-unenrolled` starts it unenrolled and `--framebriar-shake-companion-layout` wraps it in a Companion-like split view. `FramebriarShakeUITests` injects UIKit `motionEnded(.motionShake)` into the first responder and drives the actual composer/Settings presentation. It verifies:

- a shake pre-attaches a removable screenshot;
- reviewing and cancelling queues nothing, and only Submit queues a report;
- with the screenshot toggle off, a shake attaches nothing;
- the fixture transport never opens a socket (zero network calls on every path that doesn't submit). Physical sensor detection remains a device acceptance check.

## Shake while unenrolled

Field report: “shake for feedback doesn't work.” Root cause: the SDK receiver is eligible only when `canSubmit == true`. While the user was unenrolled, nothing held first responder, so UIKit delivered the shake to no handler and nothing happened. Meanwhile the Settings toggle showed On. `FramebriarShakeDiagnosticsUITests` reports which responder receives the shake: `none` while unenrolled. It also shows the enrolled shortcut working in a Companion-like split view across push, pop and keyboard dismissal. The shortcut is suppressed only while the composer TextField is first responder, which is intentional.

The fix is app-only and Vendor/Framebriar is unchanged. `shakeToExplainFeedbackEnrollment` installs an app-owned receiver that is eligible only while status is loaded and unenrolled, so it is never eligible at the same time as the SDK receiver. A shake shows “Feedback enrollment required” with Set up feedback (opens `EnrollmentView`), Turn off shake, and Not now. It never enrolls, captures or sends anything. Settings also states the requirement next to the toggle. Detecting a physical shake remains a device acceptance check.
