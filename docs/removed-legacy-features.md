# Removed legacy features

The pre-Companion interface (reachable only with `--legacy-interface`, `--ui-testing` or `--test-server`) was deleted after the Companion redesign (#112). This file lists what went with it, so anything worth having can be rebuilt on the Companion and `ClubhouseTransport`. The old code can be recovered from git, at the parent of the commit that removed it (`git log --diff-filter=D -- Annex/Annex/Views`).

The legacy app talked to Annex through its own client (`Networking/`), which duplicated the current transport. Rebuilt features should add commands or reads to `ClubhouseTransport` (see `TRANSPORT_CONTRACT.md`) and should not revive the old client.

## Features with no Companion equivalent

- **Canvas**: `Views/CanvasTabView.swift`, `Views/CanvasLayout.swift`. Rendered the desktop's canvases (agent/plugin nodes at server-sent positions) with pan, zoom and recentering.
- **File browser and file viewer**: `Views/FileBrowserView.swift`, `Views/FileContentView.swift`. Browsed a project's file tree (`getFileTree`) and showed files with a small syntax highlighter (`getFileContent`). The Companion only previews files that an agent links in chat.
- **Git log and diffs**: `Views/GitLogView.swift`. Listed recent commits, a commit's changed files and the diff for each file (`getGitLog`, `getGitShowCommit`, `getGitDiff`). The project page's Changes view (#158) now shows the project root's uncommitted files and their diffs, read-only, through `AnnexReadRoute.gitStatus` and `.gitDiff`. Commit history is still missing.
- **Live agent terminal**: `Views/LiveTerminalView.swift`, `Terminal/ANSITerminal.swift`, `Terminal/PTYInputSubmit.swift`. Streamed an agent's PTY buffer through an ANSI/VT parser and sent keystrokes back over the WebSocket (`pty:input`, resize). Rebuilt for the Companion (#182): a running `pty` agent's chat shows its own terminal (`pty:attach`), through `CompanionTerminalScreen` and `CompanionTerminalSession`.
- **Remote shell**: `Views/RemoteShellView.swift`. Spawned an interactive shell at the project root over the mTLS WebSocket. Rebuilt for the Companion (#182): Terminal on the project page and project menu opens the project root, and on an agent's menus its worktree, when the desktop advertises the `terminal` capability.
- **Plugin views**: `Views/HomePluginView.swift`, `Views/TerminalPluginView.swift`, `Views/ClubhousePluginVisibility.swift`. Mobile versions of the desktop's Home plugin (project overview) and Terminal plugin (agents grouped by status, with terminal and wake actions), plus the rules for which app plugins to show.
- **Dashboard**: `Views/DashboardView.swift`, `Views/DashboardActivitySection.swift`. Stats across all instances (agent counts by status, connection bar) and recent hook activity.
- **Activity feed**: `Views/ActivityFeedView.swift`. A filterable feed of hook events (tool use, notifications, permissions) for each agent.
- **Swipe-card agent view**: `Views/SwipeableAgentView.swift`, `Views/AllAgentsView.swift`. A full-screen card interface for swiping between agents, with list and grid modes.
- **Multi-instance spawn**: `Views/MultiInstanceSpawnSheet.swift`. Spawned the same quick agent on several desktops at once.
- **Create durable agent**: `Views/CreateDurableAgentSheet.swift`. Created a durable agent with a name, color and model. The Companion can only spawn quick agents and wake existing durable agents.
- **Delete agent**: `deleteAgent` in `Networking/AnnexAPIClient.swift`, used from the agent detail views.
- **Quick agent spawned under a parent**: `spawnQuickAgentUnder` and `Views/SpawnQuickAgentSheet.swift`. Spawned a quick agent under a durable agent (`POST /api/v1/agents/{id}/agents/quick`) instead of directly under a project.
- **Session summaries**: `Views/SessionDetailView.swift`. Showed the server-generated session summary card (cost, duration, files changed) next to the transcript (`getSessionSummary`). The Companion archive shows transcripts only.
- **Agent and project icons**: `Networking/IconCache.swift`. Fetched and cached the custom agent and project icons from the desktop. The Companion uses initials and colors.
- **In-app log viewer**: `Views/LogViewerView.swift`, `Networking/AppLog.swift`. A filterable, shareable buffer of app log lines. The Companion has Diagnostics and OpenTelemetry instead (`docs/opentelemetry.md`).
- **Cold-launch cache**: `Networking/LocalCache.swift`. Restored the last snapshot and activity from disk before the socket reconnected.
- **Onboarding**: `Views/WelcomeView.swift`, `Views/PairingPlaceholderView.swift`. First-launch welcome screens and the "no desktops yet" pairing page. The Companion goes straight to its root view and pairing sheet.

## Replaced by the Companion

These features went too, but the Companion already covers them.

- Project and agent lists (`ProjectsTabView`, `ProjectListView`, `AgentListView`, row views): replaced by the Companion root.
- Agent and quick-agent detail and messaging (`AgentDetailView`, `QuickAgentDetailView`, `SendMessageSheet`): replaced by the Companion conversation.
- Permission prompts and swipe-to-approve review (`PermissionRequestSheet`, `PermissionReview/*`): replaced by the Companion approval and question cards.
- Wake (`WakeAgentSheet`): replaced by Wake agent in the conversation.
- Session history (`SessionListView`, `SessionDetailView` transcript): replaced by the Companion archive.
- Instances and settings (`InstancesView`, `AnnexesTabView`, `SettingsView`): replaced by Desktops & settings.
- Bonjour discovery, PIN/v2 pairing, Ed25519 and RSA mTLS identity, Keychain storage, WebSocket replay and the outbound queue (`Networking/*`): replaced by `ClubhouseTransport`.
- Theme from the desktop (`Models/Theme.swift`): replaced by `CompanionTheme`.

## Test and debug tooling removed

- `--legacy-interface`, `--ui-testing`, `--test-server host:main:pairing`, `--test-pin` and `--reset-onboarding` launch arguments, `MockData/MockData.swift` and `AnnexUITests/MockAnnexServer.swift`, which was an `NWListener` server that faked the v1 HTTP API.
- The legacy unit tests in `AnnexTests` (API client, WebSocket parsing, replay, outbound queue, multi-instance Keychain/mTLS, canvas, dashboard, swipe cards and similar) and UI tests (`AnnexUITests.swift`, `IntegrationTests.swift`). The equivalent transport coverage is in `Tests/ClubhouseTransportTests`.
- `Annex/debug_permission.sh` and `Annex/debug_ws_monitor.py`, which used the v1 plaintext HTTP `/pair` route that the desktop no longer serves.
- The v1-era specs `ANNEX_CLIENT_SPEC.md`, `ANNEX_SERVER_REQUESTS.md` and `CONTRACT_IMPROVEMENTS.md`. `TRANSPORT_CONTRACT.md` is the current contract.

## Companion gaps noticed during the sweep

- Upgraded installs keep the legacy client's Keychain material: its RSA key and certificate (`kSecClassKey`/`kSecClassCertificate`) and its tokens under `com.Agent-Clubhouse.Go`. `CompanionInstallReset` clears these generic-password services only on a fresh install, and never clears the legacy key or certificate items. Nothing reads them anymore, so a one-time cleanup on upgrade would be tidy.
- The legacy `hasCompletedOnboarding` UserDefaults key and the `LocalCache` files in Caches are orphaned on upgraded installs. They are harmless, and the system may purge the cache files.
- Headless agents still have no terminal to show; the Companion lists them but can't message them (`runsInTerminal`). Terminal (`pty`) agents show their own terminal since #182.
