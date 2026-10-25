# Native companion presentation

The companion centers the mobile experience on conversations and agent steering. A host-scoped sidebar groups projects and agents, highlights working agents and requests needing attention, and adapts to a persistent split view on iPad. Each conversation carries its desktop/project context, typed message/tool/approval/question rows, a retained draft, and explicit connection state. Tool output and code are progressively disclosed. Native semantic fonts, selectable text, VoiceOver labels, and keyboard shortcuts are used throughout.

## Boundaries

- `Companion/Domain`: platform-independent presentation values and an Observation store. `CompanionTarget` includes host, project, and agent IDs. `CompanionService` injects history, command dispatch, and events. Domain models do not read credentials or open sockets.
- `Companion/Views`: SwiftUI shell, timeline, composer, spawn sheet, tool details, approval and structured question cards.
- `Companion/Adapters`: protocol mapping and explicit debug preview service. `--companion-preview` never restores real paired sessions and displays a preview banner. Preview commands fail explicitly.
- `Transport`: separate worker owns pinned TLS, credentials, pairing, replay and command transport. Desktop owns additive versioned mobile API.

Acceptance is not completion: an optimistic user message goes from sending to accepted by desktop, and only a server echo makes it confirmed. Definite rejection permits a retry with the original command ID and request. Unknown outcomes do not offer blind retry. Approval choices must be exact one-time options supplied by the provider. Reconnect gaps disable commands until history is refreshed. Drafts remain scoped to the host/project/agent while navigating or disconnecting.

## Validation

`swift test --filter Companion` runs the 33 presentation tests on macOS without launching a simulator. The root package's `CompanionDomain` target includes `Domain` and `Adapters`, with `Views` excluded. Coverage includes host identity collisions, replay de-duplication, stale history racing live events, uncertain delivery, stable retry IDs, server echo reconciliation, late receipts, expired approval rejection, serialized foreground/background transitions, paginated archives, uncertain spawning and queue state/removal races.

Integration owns simulator/GUI validation. Inspect compact iPhone, iPad split view, accessibility Dynamic Type, light/dark appearance, long code/output, disconnected drafts, and pending approvals/questions. Do not treat preview fixtures as end-to-end proof; the live transport must be exercised against the separately launched isolated desktop.

## Live app composition

Normal launch uses `CompanionAppRoot`, `CompanionLiveService`, and the secure `AnnexTransportRegistry`. A paired host is registered only after the user compares the desktop identity and TLS certificate. Nearby discovery supplies hints; Inspect desktop obtains a candidate certificate before the user confirms trust. Manual and Tailscale endpoints use the same flow. Remember this desktop defaults off; enabling it explicitly saves the complete pairing through the transport's Keychain store. The pre-Companion interface has been removed (see `removed-legacy-features.md`); its old credentials are never restored.

`CompanionChatProjector` handles session-local sequences independently of Annex's global cursor; final messages replace chunks, tool updates preserve prior input and append/replace output correctly, and pending interactions outside the transcript tail remain available. The live adapter reads `controlAvailable` before exposing controls, preserves provider permission option IDs, binds every command to its loaded session and capability epoch, and retains the exact command on a retry. Drivers without steering can expose a queued follow-up instead. Interrupt retains the chat session. Rich events also render plans and subagent progress.

For integration only, a DEBUG app can receive `CLUBHOUSE_COMPANION_TEST_INVITATION` containing JSON `{host, port, hostID, certificatePin, pin, name?}` from the isolated test desktop. This path uses an in-memory registry and explicit session-only pairing. It neither reads saved pairings nor persists a pairing, and sends commands through the real pinned TLS transport. The integration worker owns provisioning that isolated desktop and launching this path.

Draft persistence is injected: production stores per-host/project/agent draft text locally, while preview and integration modes keep it in memory. Approval/question acknowledgements preserve authoritative stream resolutions, and unrelated timeline updates cannot reopen an already submitted or acknowledged interaction. Capability negotiation gates spawn and each chat operation independently.

First integration evidence: the dedicated iPhone simulator paired over actual pinned HTTPS/mTLS with the production Annex service and sent a chat message through `ChatAgentRuntime` to a local fake-CLI subprocess. It received the user-message echo, streamed response and turn end; integration's XCTest passed. This verifies the real mobile/desktop transport path with a deterministic backend, not an external model-provider session. The coordinator retains logs/screenshots in its evidence directory.

The subsequent live control smoke also passed one-time denial, a structured question answer, background/foreground reconnection, and a second streamed permission request. Lifecycle operations are serialized across the transient inactive phase. Open conversations reconcile on reconnect; failed/in-flight history blocks commands and retains drafts. Session IDs scope transcript cursors so restarted agents cannot inherit old high sequence values.

Desktops & settings exposes explicit online session revocation when advertised. Local forgetting explains that it does not revoke desktop trust. Unknown revocation results preserve local material and direct the user to check desktop state. Pairing describes the controller authority granted and distinguishes session access from remembered access.

Conversation archive lists saved desktop sessions and pages backward through their history. Archive readers reconstruct all loaded events in sequence (including split tool/message chunks), retain data and cursor after failed reads, reject session substitution, and never alter the live command session. Archived approval/question rows are informational. This feature has unit/build validation; simulator visual/interaction coverage is tracked separately by integration.

Queue membership comes from desktop `queue_state` events and snapshot `queuedMessageIds`, with an independent `queueStateSeq` watermark. Older transcript events cannot override newer queue snapshots. Only advertised, client-managed pending IDs show removal controls; provider-managed follow-ups remain submitted. Dispatch/delivery/removal states are distinct. Unknown removal outcomes block additional commands until refresh. An uncertain spawn preserves its exact command and offers an explicit same-ID outcome check, avoiding accidental duplicate agents.
