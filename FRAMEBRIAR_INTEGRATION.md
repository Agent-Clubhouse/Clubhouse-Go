# Framebriar integration handoff

This local branch adds native feedback to the current Companion interface, based on `codex/mobile-integration-validation` at `0fce51f5735958f8da5588d2fc9fa6231c16ad0c`. The mobile owner's source checkout is untouched. The integration is not merged, pushed, published, or released.

## What changed

- `Vendor/Framebriar`: pinned, independent local Swift Package with `Framebriar` core and optional `FramebriarUI`; see its README for wire/storage/privacy details.
- `Companion/Views/CompanionFeedback.swift`: composition adapter and Settings rows. It has no reference to prompts, agent history, transport credentials, trust registry, or logs.
- `Companion/Views/CompanionAppRoot.swift`: owns one feedback model for the app lifetime, drives foreground-only delivery, and shows expiry/access/offline notices outside Settings. Settings exposes invitation redemption, enrollment clear, queue count/capacity, retry/clear, and explicit feedback review.
- `Annex.xcodeproj`: links the two local package products. Signing and network configuration are unchanged.
- `FramebriarIntegrationTests`: checks that the default unconfigured build creates no feedback client.

The legacy interface is intentionally unchanged. The default Companion interface is the current mobile owner's integration target. Existing `--companion-preview` and nonpersistent test runtime do not start feedback.

## Live configuration remains gated

No live app scope was inferred or registered. **`FramebriarGameID` is absent**, so this checkout cannot enroll or upload. It displays “Feedback is not configured for this build or local storage is unavailable.” Do not add an invitation, access token, refresh token, owner/master token or connection string to the repository or build configuration.

After explicit owner approval for live enrollment:

1. Confirm the registered Framebriar game ID and invitation scope for Clubhouse Go. Do not assume the desktop's scope or a bundle ID is the correct mobile ID.
2. Supply the approved non-secret game ID as the app Info.plist key `FramebriarGameID`; optionally supply a real lowercase source revision in `FramebriarBuildSHA` (7–40 hex characters), or omit it. The fixed default intake endpoint is from the existing service; no network exposure or credentials settings need modification.
3. Build normally. The user opens Desktops & settings → Invitation & enrollment and enters an owner-issued v2 invitation. The secure field is cleared immediately. No enrollment occurs automatically.
4. Open Send feedback, type notes and optionally choose an image with the system photo picker, inspect the rendered image and sanitized text, then Submit reviewed feedback. The SDK never screenshots the app. Submission confirms a protected local save; only a matching service receipt confirms delivery.
5. Verify approved live delivery separately. This change does not enable the issuer, register an app, issue invitations, alter networking, sign for a physical device, provision a device or produce a TestFlight/release artifact.

Runtime initialization fails closed on storage/Keychain errors. A protected-data lock may require recreating the runtime after device unlock/app relaunch; it never falls back to plaintext or empties the queue. Default file storage is single-client/process only; do not also initialize it from an extension or the legacy UI. No cross-platform migration is attempted.

## Validation commands

```sh
swift test --package-path Vendor/Framebriar
swift test
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/clubhouse-framebriar-build CODE_SIGNING_ALLOWED=NO build
```

The SDK has 26 passing deterministic tests; tests use synthetic credentials and inject network/storage/clock. Existing transport tests use their own 127.0.0.1 TLS fixture; a restrictive process sandbox may prevent that fixture or ephemeral identities from working. Do not “fix” these tests by changing transport trust or credentials.

The default unsigned simulator build passed. Existing transport/domain package tests passed (84). Full application unit run: 531 passed, 7 failed in existing Keychain/mTLS tests, 1 skipped; the new feedback configuration test passed. The untouched `0fce51f` baseline reproduced the exact same seven failures (4 passed / 7 failed / 1 skipped in the three selected suites), confirming they are not introduced by this integration. The exact failure list and baseline comparison are recorded in the parent workspace's `DELIVERY.md` and result bundles. No full-success app-test claim is made. Photo picker/accessibility flows, actual device Keychain/file protection and live enrollment remain acceptance gates.

## Land without disturbing mobile work

The integration depends on the owner's unmerged Go #105 → #106 → #107 chain. Rebase/cherry-pick this branch onto the owner's final integrated head after those changes settle; resolve any Settings/composition conflicts with the owner's architecture. Do not merge the historical checkpoint into current main blindly.

GitHub writes previously returned HTTP 403 “Resource not accessible by integration.” This task made no GitHub write attempts and used no alternate route. Keep these commits local until authorized connector write access is restored. Do not publish the Swift package or release artifacts.
