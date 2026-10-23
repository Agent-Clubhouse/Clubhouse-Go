# Simulator integration validation

The app links the local `ClubhouseTransport` Swift package instead of compiling its files again under the application's default MainActor isolation. When adding a transport source file, keep its synchronized-group membership exception in `Annex/Annex.xcodeproj/project.pbxproj` aligned with the package sources.

Validated with Xcode 26.0.1 (17A400), Swift 6.2, iOS 26 simulator SDK/runtime, iPhone 17 Pro and iPad Pro 11-inch (M4). No physical device or Apple signing identity is required for these tests.

## Build and deterministic tests

```sh
swift test
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/clubhouse-go-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<dedicated-simulator-uuid>' \
  -derivedDataPath /tmp/clubhouse-go-derived -parallel-testing-enabled NO \
  -only-testing:ClubhouseGoUITests/CompanionPreviewSmokeTests \
  CODE_SIGNING_ALLOWED=NO test
```

The preview test opens a scoped agent conversation and verifies that a preview send does not claim desktop delivery. It uses explicit `--companion-preview` mode.

## Live integration test prerequisites

`CompanionLiveSmokeTests` is skipped by default. Enable it only against an owned, isolated fixture runtime by setting `TEST_RUNNER_CLUBHOUSE_RUN_LIVE_SMOKE=1` on `xcodebuild`. Terminate only the previous owned test app before starting, to avoid a stale accessibility connection. Build for testing, explicitly install both the rebuilt app and XCTest runner on the dedicated simulator, then use test-without-building; incremental XCTest installs exhibited stale test execution during this sprint. The runner waits for the integration owner to install the freshly built app and launch it with an in-memory `SIMCTL_CHILD_CLUBHOUSE_COMPANION_TEST_INVITATION` JSON environment value containing `host`, `port`, `hostID`, `certificatePin`, `pin`, and optional `name`.

The desktop must enforce loopback-only sockets, no Bonjour advertisement, an isolated user-data profile, and memory-only identity/TLS/peer state (`CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`, `CLUBHOUSE_ANNEX_EPHEMERAL=1`, and `CLUBHOUSE_USER_DATA`). See the companion desktop isolation PR. Obtain the exact public certificate pin and Ed25519 identity from that owned process; never bypass certificate checking or install system trust. Keep PINs and private credentials in memory, outside logs and test bundles.

The live test expects a fixture agent `durable_sprint_fixture` backed by the desktop repository's scripted `fake-claude.mjs` through the real ChatAgentRuntime and ClaudeStreamTransport. A fresh runtime session is needed for each run. This exercises production Annex HTTPS/mTLS, WebSocket streaming, approval and question commands, foreground reconnect, archived transcript reads, and scoped session revocation. It does not invoke a live model provider or prove a deployed gateway/LAN path.

The preexisting unsigned application unit suite has seven Keychain/mTLS failures with OSStatus -34018; the new in-memory transport package tests avoid persistent credential requirements. No Keychain entitlement or trust-setting change was made to hide those baseline failures.

For the optional client-queue assertion, set `TEST_RUNNER_CLUBHOUSE_RUN_QUEUE_SMOKE=1` and configure only the fixture session capabilities as `steer: false, queue: client`. This makes the real runtime hold a follow-up while approval is pending. The test removes that exact pending message before resolving the approval, then continues through reconnect, archive, and revocation. Default Claude capabilities use a native provider queue, whose messages are not advertised as locally removable.


## Real Codex provider check

The opt-in `CompanionProviderSmokeTests/testRealCodexResponseFollowUpAndForegroundReconnect` passed on the rebuilt iPhone application using installed Codex CLI 0.163.0, its existing ChatGPT login, and the default `gpt-6-astra` model. Enable only with `TEST_RUNNER_CLUBHOUSE_RUN_PROVIDER_SMOKE=1` and a separately owned `durable_sprint_provider` runtime. The desktop must use `new CodexChatDriver({ ephemeralThread: true })`, a fresh project/session, `level: plan`, no resume ID, and a no-tools instruction. The driver requests `ephemeral: true`, requires the server to echo it, and rejects resume before spawning. Disable configured MCP servers only for this child process; do not change global config or enroll credentials.

Use the exact current arm64 `.xctestrun` file with `test-without-building` after installing the rebuilt app and runner. A stale multi-architecture configuration selected zero tests during the sprint; zero tests is not provider evidence.

The verified run sent three harmless prompts from mobile through production Annex and CodexChatDriver: initial fixed reply, benign follow-up, and a third fixed reply after home/background → foreground reconnect. The desktop recorded 14 streamed message chunks, three final responses and three completed turns, with zero tool calls. XCTest passed in 28.369 seconds. This is full mobile provider E2E, separate from the scripted approval/queue/archive coverage above. A separate in-flight steering check is recorded below. Actual provider tool execution and physical LAN/Tailscale routing remain outside this check.


## Verified in-flight steering

`CompanionProviderSmokeTests/testRealCodexSteeringDuringActiveGeneration` passed in 18.632 seconds using a fresh confirmed-ephemeral Codex thread. It asks for a harmless 500-line response, waits for output to stream, checks the active-generation control before and immediately after typing a new direction, and sends the change from mobile. Production runtime evidence verifies 118 streamed chunks before the second mobile message was acknowledged with `delivery: steer`; the changed reply and completion share the original turn ID. Exactly one turn started and ended. This is actual in-flight Codex steering, not a subsequent prompt after completion. No tools were called and no product defect was found. Build-for-testing and the exact-arm64 simulator test passed; production code is unchanged from the previously validated ephemeral-driver checkpoint.

The remaining physical-network prerequisite is a physical iPhone with a signed build on a reachable existing network, plus explicit approval for the isolated Annex listener to bind to one selected non-loopback interface. Read-only inspection found this Mac's LAN address 192.168.1.26 and running Tailscale address 100.81.200.13. The existing test profile binds only 127.0.0.1, which a physical phone cannot reach. No listener, firewall, Tailscale enrollment, or trust setting was changed. An existing-tailnet phone could target 100.81.200.13 once that narrowly scoped bind is approved; a same-LAN phone could use 192.168.1.26 instead.
