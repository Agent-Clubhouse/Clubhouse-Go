# Native companion presentation

The companion centers the mobile experience on conversations and agent steering. A host-scoped sidebar groups projects and agents, highlights working agents and requests needing attention, and adapts to a persistent split view on iPad. Each conversation carries its desktop/project context, typed message/tool/approval/question rows, a retained draft, and explicit connection state. Tool output and code are progressively disclosed. Native semantic fonts, selectable text, VoiceOver labels, and keyboard shortcuts are used throughout.

## Boundaries

- `Companion/Domain`: platform-independent presentation values and an Observation store. `CompanionTarget` includes host, project, and agent IDs. `CompanionService` injects history, command dispatch, and events. Domain models do not read credentials or open sockets.
- `Companion/Views`: SwiftUI shell, timeline, composer, spawn sheet, tool details, approval and structured question cards.
- `Companion/Adapters`: protocol mapping and explicit debug preview service. `--companion-preview` never restores real paired sessions and displays a preview banner. Preview commands fail explicitly.
- `Transport`: separate worker owns pinned TLS, credentials, pairing, replay and command transport. Desktop owns additive versioned mobile API.

Acceptance is not completion: an optimistic user message goes from sending to accepted by desktop, and only a server echo makes it confirmed. Definite rejection permits a retry with the original command ID and request. Unknown outcomes do not offer blind retry. Approval choices must be exact one-time options supplied by the provider. Reconnect gaps disable commands until history is refreshed. Drafts remain scoped to the host/project/agent while navigating or disconnecting.

## Validation

`Tests/CompanionDomainTests` runs via Swift Testing on macOS without launching a simulator. Target it as `CompanionDomainTests`, depending on a `CompanionDomain` target at `Annex/Annex/Companion/Domain` when integrating the transport Package.swift. Coverage includes host identity collisions, replay de-duplication, stale history racing live events, uncertain delivery, stable retry IDs, server echo reconciliation, late receipts and expired approval rejection.

Integration owns simulator/GUI validation. Inspect compact iPhone, iPad split view, accessibility Dynamic Type, light/dark appearance, long code/output, disconnected drafts, and pending approvals/questions. Do not treat preview fixtures as end-to-end proof; the live transport must be exercised against the separately launched isolated desktop.

## Live app composition

Normal launch uses `CompanionAppRoot`, `CompanionLiveService`, and the secure `AnnexTransportRegistry`. A paired host is registered only after the user compares the desktop identity and TLS certificate. Nearby discovery supplies hints; Inspect desktop obtains a candidate certificate before the user confirms trust. Manual and Tailscale endpoints use the same flow. Remember this desktop defaults off; enabling it explicitly saves the complete pairing through the transport's Keychain store. The old interface remains an explicit `--legacy-interface` migration/debug route, and ordinary launch never restores its old credentials.

`CompanionChatProjector` handles session-local sequences independently of Annex's global cursor; final messages replace chunks, tool updates preserve prior input and append/replace output correctly, and pending interactions outside the transcript tail remain available. The live adapter reads `controlAvailable` before exposing controls, preserves provider permission option IDs, binds every command to its loaded session and capability epoch, and retains the exact command on a retry. Drivers without steering can expose a queued follow-up instead. Interrupt retains the chat session. Rich events also render plans and subagent progress.

For integration only, a DEBUG app can receive `CLUBHOUSE_COMPANION_TEST_INVITATION` containing JSON `{host, port, hostID, certificatePin, pin, name?}` from the isolated test desktop. This path uses an in-memory registry and explicit session-only pairing. It neither reads saved pairings nor persists a pairing, and sends commands through the real pinned TLS transport. The integration worker owns provisioning that isolated desktop and launching this path.
