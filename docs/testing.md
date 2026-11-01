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
  - `--framebriar-shake-ui-testing`: `FramebriarShakeUITests` and `FramebriarShakeDiagnosticsUITests`. The diagnostics tests add `--framebriar-shake-unenrolled` (feedback not enrolled) and `--framebriar-shake-companion-layout` (Companion-like split view with navigation and a composer).

### Writing UI tests for hosted runners

GitHub's macOS runners can take 15–20 s per element lookup and 90 s per launch, and sometimes drop a tap or long-press. Fixture-mode UI tests subclass `ReliableUITestCase` (`Annex/AnnexUITests/UITestSupport.swift`):

- `launchApp(_:)` launches in portrait with `--ui-testing-fast` (UIKit animations off, DEBUG only) and relaunches after a launch or terminate timeout.
- `waitAndTap(_:until:)` and `waitAndTap(_:untilGone:)` tap again only if the expected change didn't happen. `longPressUntilMenu(_:shows:)` does the same for context menus.
- `scrollTo`, `scrollUntilExists` and `expandFold` stop as soon as the target is there. Don't write `for _ in 0..<n where !condition { swipe }`: `where` doesn't end the loop, so the slow lookup in `condition` still runs on every remaining iteration.
- Each step fails with a message 30 s before the test's execution time allowance. A test the allowance kills restarts the runner and isn't retried.

Don't retry a tap whose repeat changes the result, such as adding an attachment or toggling a switch.

The live and provider tests listed below skip unless you enable them.

## Live E2E against a real desktop (nightly)

`scripts/e2e-live.sh` tests Clubhouse Go end to end against a real Clubhouse desktop. Nothing here calls a model or spends tokens. It needs Node (the repo's `.nvmrc`), Xcode with an iOS simulator, and network access to clone `Agent-Clubhouse/Clubhouse`.

```sh
scripts/e2e-live.sh                                   # desktop main, iPhone 17 Pro
scripts/e2e-live.sh --desktop-ref my-branch           # any desktop branch, tag or commit
scripts/e2e-live.sh --only CompanionLiveE2ETests/test6ProjectAndAgentTerminals
scripts/e2e-live.sh --skip-desktop-build              # reuse .desktop as it is
scripts/e2e-live.sh --simulator 'iPhone 17'           # another model (a new device of it)
```

What the script does:

1. **Builds both apps.** It clones the desktop into `.desktop/`, which git ignores, checks out the ref and runs `npm ci` and `electron-forge package`. It skips either step when the lockfile or the commit hasn't changed since the last run. Clubhouse Go builds for testing at the same time.
2. **Launches the desktop as an isolated fixture.** It copies `scripts/e2e-live/desktop-fixture.spec.ts` into the desktop's `e2e/` folder and runs it with the desktop's own Playwright and launch primitive. You get:
   - a disposable profile (`CLUBHOUSE_USER_DATA`), with auto-update off;
   - loopback-only, ephemeral Annex (`CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`, `CLUBHOUSE_ANNEX_EPHEMERAL=1`): no Bonjour, and identity, TLS and peers held in memory;
   - every provider CLI pinned through the desktop's unpackaged-only `CLUBHOUSE_TEST_CLI_BINARIES` seam. Claude Code is the desktop's scripted `src/main/chat/claude/__fixtures__/fake-claude.mjs`, running in chat mode on the stream-json transport. Codex and Copilot point at paths that don't exist, so a real CLI on the machine is never reached.
   - one git project under `/tmp`, `Phone Fixture`, with two sleeping chat agents: Echo, which works in the project folder, and Builder, which has its own worktree;
   - the experimental Dispatcher flag and New layout, with Dispatcher initially off so the earlier idle-project tests keep their order constraints;
   - a separate session-paired mTLS observer that checks real Dispatcher events, follow-up snapshots and replay. It pins the fixture certificate before pairing. A wrapper around the unchanged fake CLI stores only that isolated child's MCP bridge credentials in 0600 files inside the private temporary fixture folder, so tests can call real Dispatcher tools without a model. Credentials never reach the phone runner or wire evidence. Desktop stdout/stderr are redacted before entering the artifact directory, other logs are scrubbed at teardown, and the entire temporary folder is deleted.

   Before any build or launch, the script removes every inherited `CLUBHOUSE_*` environment variable, including the agent credentials present when an installed Clubhouse starts the script. The fixture refuses inherited Clubhouse variables. Its fake wrapper records credentials only for fixture-created agent IDs; every MCP RPC verifies that ID, excludes the original inherited port, and checks that the listener belongs to the fixture desktop PID. Fallback teardown also checks that `desktop.pid` runs an executable under `.desktop/` before signaling it.

   It never touches your own Clubhouse instance or its profile.
3. **Mints the pairing.** Once Annex's TLS listener is up, the fixture reads `annex.getStatus()` and writes `{host, port, hostID, certificatePin, pin, name}` (mode 0600) to a temporary folder.
4. **Runs `CompanionLiveE2ETests`** on a new simulator of the chosen model, which the script creates for this run and deletes afterwards. On a dev Mac other builds and agents boot, drive and shut down the usual simulators, and sharing one crashed runs and relaunched the app mid-test. Pass `--shared-simulator` to use the existing device instead. The script uninstalls the app and runner first, because a stale runner has run old tests. The invitation reaches the runner as `TEST_RUNNER_CLUBHOUSE_COMPANION_TEST_INVITATION`, and each test passes it to the app in its launch environment. Each launch then pairs for that session only, through the DEBUG bootstrap. Failed tests are retried once. If the simulator itself crashes ("server died", a failed launch), xcodebuild aborts the whole run, so the script reboots the simulator and runs the suite once more. `scripts/verify-xcresult.py` requires a nonempty passing result. xcodebuild prints the launch environment when a launch fails, so the script redacts the invitation from its log.
5. **Tears everything down**, even on failure or Ctrl-C: the desktop and its Playwright runner (only the processes the script started), the profile, the invitation, and the simulator (`--keep-simulator` keeps it).

Results land in `build/e2e-live/` (set `E2E_OUT_DIR` to change it):

- `LiveE2E.xcresult`, which holds screenshots of each step;
- `xcodebuild-build.log` and `xcodebuild-test.log` (plus `xcodebuild-test-retry.log` after a simulator crash);
- `desktop-fixture.log`, `desktop-stdout.log`, `desktop-stderr.log`, the desktop's npm and build logs;
- `desktop-sha.txt`, the desktop commit that was tested;
- `dispatcher-wire.json`, redacted Dispatcher events, snapshots, replay and MCP-delivered message evidence.
- `desktop-annex.json`, a closed projection of this fixture profile's Annex pairing/REST outcomes and WebSocket admission/close timestamps; raw metadata is excluded. Phone `[live-connect]` records in the xcresult console contain only timestamps, operation names, durations, failure categories and diagnostic event names. These help locate an initial-connection stall without recording invitations, certificates, identities or tokens. Both paths use the artifact redaction step (`python3 scripts/e2e-live/test_redact_logs.py` checks it).

Other environment variables: `DESKTOP_REF`, `DESKTOP_REPO`, `DESKTOP_DIR`, `E2E_SIMULATOR`, `E2E_DERIVED_DATA`, and `E2E_SKIP_DESKTOP_CHECKOUT=1`, which builds `DESKTOP_DIR` as it is checked out.

### What one run covers

The fake CLI's scripted turns:

| You send | The CLI replies |
|---|---|
| `hello` | Streams "Hello". |
| `tool` | Asks to run `ls`, offering an "allow and don't ask again" rule. It replies `allowed:<input>:<rules>` or `denied:<message>`. |
| `ask` | Asks "Which DB?". |
| `crash` | Exits at once with code 3. |
| A message with images | `echo:<text>\|…\|images:<n>:<types>` |

The tests share the desktop and run in order. Each one copes with what an earlier attempt left behind, such as a waiting approval, an inactive project or an awake agent.

| Test | Covers |
|---|---|
| `test0ProjectPinAndIdleSync` | Pin, then Mark inactive and Mark active, each kept by the desktop across a fresh pairing. It runs first, while every agent sleeps, because Home never folds a project with an awake agent. |
| `test1PairingCatalogAndReconnect` | Pairing from the invitation; the project and agents from the desktop's catalog; the desktop's status words (Sleeping, Done); waking an agent; Home → background → foreground reconnect, then a fresh approval round trip |
| `test2ChatStreamApprovalsAndQuestion` | A streamed reply; Deny; Allow (no rule added); "Allow and don't ask again", whose rule reaches the CLI; a structured question and its answer |
| `test3ImageUploadReachesTheCLI` | Picking an image, uploading it to the desktop, and the CLI receiving it as an `image/png` block |
| `test4ModelAndLevelSwitch` | The composer's model menu (switching to Haiku) and level menu (switching to Plan, then back to Ask first) |
| `test5CreateDurableAgentAndSettings` | New agent creates a durable agent on the desktop; the desktop's agent settings rename it and change its colour; Home shows the new name |
| `test6ProjectAndAgentTerminals` | The project-root shell (spawn, echo, its directory, a resize on rotation, close) and Builder's worktree shell (its folder and branch) |
| `test7FinishedQuickAgent` | A quick agent started from the phone finishes, is listed under "Finished, waiting on you", and Dismiss removes it on the desktop |
| `test8AgentThatSleptWhileAwayReadsSleepingAfterForeground` | Echo is awake (Done); the phone goes to the background; the desktop puts Echo to sleep (the test writes `sleep-request` to the fixture folder, `TEST_RUNNER_CLUBHOUSE_E2E_FIXTURE_DIR`); back in the foreground, Home reads Sleeping without opening the chat (the reconnect catch-up) |
| `test9aDispatcherPhoneSwitchDesktopChangesAndReplay` | Phone Settings turns Dispatcher on/off; the pinned row; desktop changes while connected and backgrounded; phone catch-up; a real paired observer verifies `dispatcher:changed`, follow-up snapshots and `mobile:replay` |
| `test9bDispatcherChatSettingsSleepWakeAndResume` | Dispatcher chat send/stream, its editable and locked settings, desktop stop, phone wake/resume after reconnect |
| `test9cAgentDispatcherSwitchesAndRealMCPDelivery` | Echo's Orchestrate and Connect switches; the actual Dispatcher wire; authenticated MCP `wake_agent`, `send_message`, `sleep_agent`; phone wake/sleep state and sender caption/text; structured `routed` data when sent; raw `mcpEnabled: false`, 409 `mcp_off`, `dispatcher_off` and `dispatcher_flag_off` |
| `test9dDispatcherSettingsSaveAndLockedFieldsRefuse` | Phone model/runtime/auto-sleep/Free Agent Mode saves persisted on desktop, plus 409 `dispatcher_locked` for identity, persona, Clubhouse mode and orchestration writes |
| `test9eDispatcherInspectsARealHelper` | Echo creates a genuine helper through `start_helper`; Dispatcher inspects it through `inspect_helper`; the helper's real settings show Connect to Dispatcher off |

Dispatcher checks run last and support `--only` and retries. Phone gestures cover the UI; the private fixture action channel performs desktop changes, direct MCP calls and HTTP-only refusal checks. The observer's replay check proves the desktop retains the event, while the phone assertion proves foreground catch-up; it does not claim to distinguish replay from a fresh connection snapshot on the phone. The fake CLI does not decide to use tools: the fixture authenticates to the real MCP bridge as its own fake child and invokes them directly.

**Dispatcher gaps:** `dispatcher_layout_off` needs a separate Classic-layout desktop launch (layout is fixed at startup); MCP-off disabled-switch UX and structured `routed` rendering await the separate phone changes. The live test checks delivered `routed` wire fields when present, without claiming a structured-rendering test. Physical-device background suspension is separate from the simulator's Home/foreground check.

**Not covered: helper requests.** The fixture would need an orchestrator agent with orchestration turned on and an ask-first helper policy, whose CLI calls `start_helper` over the desktop's Clubhouse MCP bridge. The scripted fake doesn't speak MCP. `CompanionPreviewSmokeTests/testNeedsYouAnswersHelperRequestsWithTheDesktopRules` covers the phone side against the preview desktop.

`--companion-sample-images` replaces the photo picker in this suite, as in preview mode. In DEBUG builds it is honoured when a test invitation is present.

### Nightly workflow

`.github/workflows/e2e-nightly.yml` runs the script on `macos-26` every night at 08:17 UTC. To run it on demand, use **Actions → Live E2E (nightly) → Run workflow**, which takes a `desktop_ref` input (default `main`):

```sh
gh workflow run e2e-nightly.yml --ref <branch> -f desktop_ref=main
```

It never runs on pull requests, which keeps CI minutes down: a run takes about 45 runner minutes, mostly building the desktop (`npm ci` about 6, `electron-forge package` about 23) and the suite itself (about 12). Each run uploads `live-e2e-<run id>` (the xcresult and logs) for 14 days.

When a nightly run, or a run on `main`, fails, the workflow opens an issue titled "Nightly live E2E failing", or comments on the open one. Close the issue once the suite is green again.

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
