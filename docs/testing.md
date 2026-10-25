# Testing Clubhouse Go

The app links the local `ClubhouseTransport` Swift package, so the transport isn't compiled a second time under the app's default MainActor isolation. When you add a transport source file, add its synchronized-group membership exception in `Annex/Annex.xcodeproj/project.pbxproj` too, so it matches the package sources.

## Deterministic tests

These run in CI (`.github/workflows/ci.yml`) and need no physical device or signing identity.

```sh
swift test                                   # ClubhouseTransportTests, CompanionDomainTests
swift test --package-path Vendor/Framebriar  # vendored Framebriar SDK
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,name=<iPhone simulator>' \
  -derivedDataPath /tmp/clubhouse-go-dd CODE_SIGNING_ALLOWED=NO test
```

- `ClubhouseGoTests` holds `FramebriarIntegrationTests` and `DiagnosticPrivacyTests`.
- `ClubhouseGoUITests` launches the app in DEBUG fixture modes that never restore or contact a real paired desktop:
  - `--companion-preview`: `CompanionPreviewSmokeTests`
  - `--diagnostics-ui-testing`: `DiagnosticSettingsTests`
  - `--framebriar-shake-ui-testing`: `FramebriarShakeUITests`
  - plain launch: `AnnexUITestsLaunchTests`

The live and provider tests listed below skip unless you enable them.

## Live integration (opt-in)

`CompanionLiveSmokeTests` runs only when `TEST_RUNNER_CLUBHOUSE_RUN_LIVE_SMOKE=1` is set on `xcodebuild`. Run it only against an isolated desktop fixture that you own:

- The desktop runs with `CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`, `CLUBHOUSE_ANNEX_EPHEMERAL=1` and a dedicated `CLUBHOUSE_USER_DATA`. That gives loopback-only sockets, no Bonjour advertisement, and identity, TLS and peer state held only in memory.
- The app receives an in-memory `SIMCTL_CHILD_CLUBHOUSE_COMPANION_TEST_INVITATION` JSON value `{host, port, hostID, certificatePin, pin, name?}`. Read the certificate pin and Ed25519 identity from the process you own. Never bypass certificate checks or install system trust. Keep PINs and credentials out of logs and test bundles.
- The expected fixture agent is `durable_sprint_fixture`, backed by the desktop repository's scripted `fake-claude.mjs` through the real `ChatAgentRuntime`. Each run needs a fresh runtime session.
- Build for testing, install the rebuilt app and the XCTest runner explicitly, then use `test-without-building` with the exact arm64 `.xctestrun`. Incremental installs have run stale tests, and a stale multi-architecture `.xctestrun` has selected zero tests. Zero tests is not evidence.

The same flag enables `CompanionPhoneWorkflowTests`, which covers wake, image and file preview, and feedback settings.

- `TEST_RUNNER_CLUBHOUSE_RUN_QUEUE_SMOKE=1` adds a client-queue assertion. It requires fixture capabilities `steer: false, queue: client`.
- `TEST_RUNNER_CLUBHOUSE_RUN_MANUAL_SMOKE=1` drives manual pairing (inspect, compare fingerprints, pair). Launch the app for it with `CLUBHOUSE_COMPANION_MANUAL_TEST=1`.

## Provider tests (opt-in)

`CompanionProviderSmokeTests` (`TEST_RUNNER_CLUBHOUSE_RUN_PROVIDER_SMOKE=1`) and `CompanionAdditionalProviderTests` (`TEST_RUNNER_CLUBHOUSE_RUN_ADDITIONAL_PROVIDER_SMOKE=1`) drive real providers through the same isolated profile. They need existing provider authentication and an invitation supplied outside the test bundle. Run one method per fresh fixture launch.

- Codex: the desktop uses `new CodexChatDriver({ ephemeralThread: true })` with a fresh project and session, `level: plan`, no resume ID and a no-tools instruction. Disable configured MCP servers for that child process only.
- Wake tests: also set `TEST_RUNNER_CLUBHOUSE_PROVIDER_STARTS_ASLEEP=1` and start the fixture asleep.
- Copilot active-generation control: set `TEST_RUNNER_CLUBHOUSE_PROVIDER_CLIENT_QUEUE=1`.
- Permission tests: set `TEST_RUNNER_CLUBHOUSE_PROVIDER_INTERACTIONS=1` and use a constrained interaction fixture.

Provider semantics to keep in mind when you read the results:

- **Claude SDK**: a direction sent during generation uses native `priority: next` and applies at the next tool boundary. A text-only turn can finish before it takes effect, so check runtime turn IDs and delivery events rather than the response marker alone.
- **Copilot ACP**: it advertises `steer: false`, `queue: client`, `interrupt: true`, `questions: false` and `planApproval: false`. Denying a tool cancels the operation and need not produce another response.
- **Image and file previews**: these follow the paired desktop's experimental rich-content policy. Phone uploads and arbitrary remote image fetches aren't implemented.

## Physical iPhone

Physical-device checks aren't automated. These still need to be done by hand: multicast discovery, device signing and Keychain, real media codecs, shake sensor detection, and LAN/Tailscale reachability.

1. Use an unlocked iPhone on iOS 26+ with Developer Mode on and development signing set up for the owner's team. Open `Annex/Annex.xcodeproj`, scheme `ClubhouseGo`.
2. Nearby discovery needs a desktop that is broadcasting and the iOS Local Network permission. Tailscale doesn't relay Bonjour, so enter its address and port manually.
3. For an isolated manual-address test, the desktop supports `CLUBHOUSE_ANNEX_BIND_ADDRESS=<one local IPv4>` with `CLUBHOUSE_ANNEX_EPHEMERAL=1` and a dedicated `CLUBHOUSE_USER_DATA`. That profile doesn't advertise. Don't combine it with `CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`. Get approval before starting a reachable listener.
4. Scan the QR code in desktop Settings → Annex, or pair manually by comparing both fingerprints and entering the PIN. Turn Remember off for an isolated test, and end the session pairing afterward.
