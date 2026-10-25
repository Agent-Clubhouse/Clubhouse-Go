# Framebriar integration handoff

The Companion interface uses the complete native SDK from `masra91/framebriar` commit `25c05f76e8ae05e5ff4b13d2caaf71a7abcfd17e`, subdirectory `adapters/swift`. All 16 upstream files are vendored unchanged; `Vendor/Framebriar/SOURCE.json` records their SHA-256 hashes. There are no local SDK patches. The package remains local because the upstream repository root is not a Swift package.

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
2. Open Send feedback, type notes and optionally choose an image with the system photo picker, review the image and optional incident references, then Submit reviewed feedback. The SDK never screenshots the app. Submission confirms a protected local save; only a matching service receipt confirms delivery.
3. Incident-bearing reports remain queued until a current access response advertises `feedbackCorrelationVersion: 1`; an older service cannot cause their metadata to be dropped or sent without that capability. Ordinary reports retain their existing delivery behavior.

Live enrollment/delivery and any service deployment remain separate validation. This consumer update does not issue invitations, register an app, modify credentials or deploy the service. `FramebriarBuildSHA` is optional and remains omitted.

Runtime initialization fails closed on storage/Keychain errors. A protected-data lock may require recreating the runtime after device unlock/app relaunch; it never falls back to plaintext or empties the queue. Default file storage is single-client/process only; do not also initialize it from an extension. No cross-platform migration is attempted.

## Validation

```sh
swift test --package-path Vendor/Framebriar
swift test
```

The SDK tests use synthetic credentials and inject network/storage/clock. `FramebriarIntegrationTests` (app unit tests) and `FramebriarShakeUITests` (app UI tests) run in CI with the rest of the app suites; see `docs/testing.md`. Photo picker/accessibility flows, actual device Keychain/file protection and live enrollment remain device acceptance gates.

## Shake shortcut follow-up

The initial implementation used only Settings → Send feedback. The optional shortcut now opens that same blank composer on a recognized shake; it does not send, capture a screenshot, attach content, enroll, or start telemetry. The user still chooses any screenshot, can remove it, reviews the exact notes/image, and explicitly taps Submit reviewed feedback.

`CompanionFeedback.shakePreferenceKey` is a local `AppStorage` preference, default on for eligible enrolled users. The Settings toggle “Shake to open feedback” disables the shortcut; Settings → Send feedback remains available. The root `shakeToOpenFeedback` modifier is eligible only for an active scene and `canSubmit == true`. Host flags and UIKit presentation checks suppress sheets/alerts/pickers, active text input is not displaced, and repeated motion/presentation boundaries are debounced for two seconds.

The follow-up touches only three lines in CompanionAppRoot (preference and modifier), the Settings preference/toggle, and the optional SDK UI. A separate DEBUG-only fixture has in-memory storage and a transport that always throws without opening a socket. The three-line selection branch in AnnexApp is only for `--framebriar-shake-ui-testing`; it never restores a paired desktop. `FramebriarShakeUITests` injects UIKit `motionEnded(.motionShake)` into the first responder and drives the actual composer/Settings presentation. Physical sensor detection remains a device acceptance check.

For the mobile owner's `codex/mobile-phone-workflow` branch: apply the follow-up commit after initial integration `5a4414a`, preserving the owner's LAN/wake/media changes. The new preview/test files are independent. The tiny AnnexApp DEBUG fixture insertion can be adapted around any new debug preview selection without changing normal app composition. No production scope was configured by either original commit; the current registered mobile configuration is described above.

Shake validation: all 30 SDK tests and all 30 exact-vendor tests passed. The targeted iOS 26 simulator UI test passed after exercising repeated motion, empty composer/no auto-submit, Settings access while disabled, presentation suppression, and responder restoration after dismissal. It verifies zero queued reports and zero network calls. Result: `../build/Framebriar-ShakeUITests-Final.xcresult`. The initial run caught a responder restoration issue; a bounded dismissal handoff fixed it. No physical motion sensor or live feedback was used.

## Shake while unenrolled

Field report: “shake for feedback doesn't work.” Root cause: the SDK receiver is eligible only when `canSubmit == true`. While the user was unenrolled, nothing held first responder, so UIKit delivered the shake to no handler and nothing happened. Meanwhile the Settings toggle showed On. `FramebriarShakeDiagnosticsUITests` reports which responder receives the shake: `none` while unenrolled. It also shows the enrolled shortcut working in a Companion-like split view across push, pop and keyboard dismissal. The shortcut is suppressed only while the composer TextField is first responder, which is intentional.

The fix is app-only and Vendor/Framebriar is unchanged. `shakeToExplainFeedbackEnrollment` installs an app-owned receiver that is eligible only while status is loaded and unenrolled, so it is never eligible at the same time as the SDK receiver. A shake shows “Feedback enrollment required” with Set up feedback (opens `EnrollmentView`), Turn off shake, and Not now. It never enrolls, captures or sends anything. Settings also states the requirement next to the toggle. Detecting a physical shake remains a device acceptance check.
