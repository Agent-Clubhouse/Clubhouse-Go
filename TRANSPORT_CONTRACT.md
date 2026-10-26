# Clubhouse Go transport

Checkpoint interface for the native UI and integration workers. Implements the additive desktop `docs/mobile-control-v1.md` contract. Existing Annex/Satellite wire messages are unchanged.

## App composition

`AnnexTransportRegistry` owns host-scoped actors. `all()` returns registrations containing `host`, `alias`, and `transport: any AnnexTransporting`. UI uses these interfaces without reading credentials:

```swift
let registry = AnnexTransportRegistry(pairings: KeychainAnnexPairingStore())
let restored = try await registry.restoreSaved() // no automatic connection
let host = try TrustedAnnexHost(
    endpoint: AnnexEndpoint(host: enteredHost, port: enteredPort, route: .manual),
    verifiedHostID: desktopEd25519Fingerprint,
    verifiedCertificatePin: AnnexCertificatePin(sha256: desktopTLSFingerprint)
)
// Invoke only after the user confirms both desktop fingerprints and chooses Pair.
// alias: this device's own name, shown on the desktop. label: what this device calls the desktop (defaults to its reported alias).
let registration = try await registry.pair(host: host, pin: pin, alias: "My iPhone", label: "Studio Mac", persistence: .persistent)
let events = await registration.transport.events()
try await registration.transport.connect()
```

For isolated integration, use `AnnexTransportRegistry()` and the default `.sessionOnly` pairing. This sends `pairingMode: "session"` to the desktop and verifies its response echo, so the desktop also keeps the peer in memory. Persistent mode is explicit on both sides. It uses in-memory credentials and RSA private keys, the same pinned TLS/mTLS transport, no Keychain/system-trust mutation. Read the isolated server's **public certificate** directly to compute the full leaf DER SHA-256; verify the Ed25519 fingerprint from its public key. Never use trust-all delegates or HTTP `/pair`.

Persistence is opt-in. Complete saved pairing (verified host, alias, RSA private key/certificate, Ed25519 private key, token) is encoded in one atomic generic-password Keychain item with `WhenUnlockedThisDeviceOnly`, no sync or access groups. No tests call Keychain stores. Saved material validates key/certificate/identity consistency before restoration; legacy credentials are never silently migrated. `remove(hostID:)` forgets local material and disconnects; persistent desktop revocation remains a desktop action. `revokeSessionAndRemove(hostID:)` explicitly revokes the current session-only pairing online through the advertised fixed same-origin DELETE route before removing local material. A failed or uncertain remote response retains local credentials; `pairingRevocationOutcomeUnknown` means the reply was lost or invalid, not that revocation failed. The protocol method `revokeSessionPairing()` has an unsupported default for alternate transports. Offline local removal alone does not revoke desktop memory; it lasts until desktop disconnect or Annex stop. A concurrent restoration cannot resurrect a removed host. Session-only mode always keeps its token in a separate memory store even when a caller injects a durable credential store. Replacing a saved pairing with session-only mode removes the older local durable record; it does not revoke older credentials held by the desktop.

## Protocol surface

- `events() async -> AsyncThrowingStream<AnnexTransportEvent, Error>`: one bounded stream per subscriber. Overflow finishes with `queueOverflow`; consumer must resubscribe and resnapshot. Unknown envelopes remain available.
- `connect() async throws`, `disconnect() async`: one host connection, cancellable exponential backoff with jitter. Identity/trust/authorization failures stop reconnecting. Read host identity and capabilities before WSS.
- `read(AnnexReadRoute) async throws -> AnnexJSON`: `.identity`, `.status`, `.projects`, `.agents(projectID:)`, `.capabilities`, `.chat(agentID:)`, `.chatSessions(agentID:)`, `.chatHistory(agentID:sessionID:beforeSeq:limit:)`, `.sessions(agentID:)`, `.transcript(agentID:sessionID:offset:limit:)`. `AnnexJSON.decode(T.self)` supports typed presentation mapping.
- `execute(AnnexCommand) async throws -> AnnexCommandReceipt`: exact v1 command fields. Chat commands require **session ID**, while host namespacing belongs to the owning transport. Types send/interrupt/removeQueued/permission/question/start/stop/spawn match desktop. `removeQueued(agentID:sessionID:messageIDs:)` encodes `chat.queue.remove` with the exact offered runtime message IDs; removed IDs in the receipt are authoritative. Approval `optionID` must come from the offered pending request, never synthesize allow/deny.

Read `.capabilities` and require `controlAvailable == true` before enabling commands. Commands carry its epoch and a stable `commandID`. Receipts `.completed`, `.rejected`, `.failed` distinguish dispatch acknowledgement, rejection and possible partial effects. Transport errors after dispatch become `commandOutcomeUnknown(commandID:)`, including cancellation: never label a lost reply as safely not sent. No automatic command retries or offline mutation queue. Repeated local IDs return the prior receipt or the same uncertainty, and changed content rejects. Bounded command ledger rejects capacity exhaustion instead of silently evicting uncertainty. Entries expire with the server retention horizon (at most one hour); command objects carry their creation time and are rejected as unknown if reused after that horizon. Reconcile before creating any new command after unknown outcomes. Disconnect invalidates pending reads and pre-dispatch work, so a late capability response cannot restore command authority. A definitive receipt received after disconnect still resolves a dispatched command; cancelling an already dispatched command cannot establish that it did not execute.

## Events and replay

AnnexEnvelope retains `{type,payload,seq?,replayed?}` and top-level replay controls (`oldestAvailable`, `lastSeq`, `fromSeq`, `toSeq`, `count`, `epoch`). Integers retain Int64 precision. The existing desktop uses top-level controls, not nested payloads.

On each connection the authoritative Annex snapshot is delivered, its global sequence seeds the cursor, and `mobile:replay` requests frames since that boundary (legacy `replay` only when mobile capability endpoint is absent). Every reconnect emits `.resyncRequired(.reconnected)`: UI must refresh current chat history and pending interactions, because Annex snapshots do not contain a full chat timeline. Gaps/epoch changes trigger explicit resync and reconnect. Same-socket catalog refresh snapshots remain supported: equal sequence boundaries are delivered, older boundaries are ignored, and an ahead boundary emits resync and requests replay from the previous cursor so chat deltas are not skipped. Missing or negative snapshot sequence boundaries fail closed. Stable rich chat identity is `(hostID,agentID,sessionID,event.seq)`, distinct from global Annex seq. UI must buffer/deduplicate events while applying async history, and must not drop live events racing a snapshot.

## Trust and address handling

LAN, Bonjour and Tailscale are endpoint routes, not different authorities. All use HTTPS/WSS, exact approved leaf SHA-256 and client certificate. Explicit `AnnexDiscovery.start()/stop()/states()` browses `_clubhouse-annex._tcp.` with bounded service resolution; metadata is a hint only. `AnnexTrustProbe.inspect(endpoint:)` captures a candidate certificate pin then cancels TLS without sending an HTTP request, PIN, token, or client certificate. UI must compare it with the desktop; inspection never grants trust. A remembered host that stops answering at its saved address may be looked for with `AnnexRediscovery`: a bounded foreground browse whose candidates are probed and accepted only when they serve exactly the pin approved at pairing. `AnnexTransportRegistry.relocate` then changes the route only, never the host ID, credential, client identity or pin. Manual host supports IPv4, DNS/MagicDNS, IPv6 and scoped IPv6. Path components/query values are encoded independently. No token in a URL, redirects, shared cookies/cache, arbitrary self-signed trust, automatic certificate rotation, VPN/system permission changes, or deployed gateway. `AnnexTransporting` is the seam for a future gateway adapter.

## Validation

Root Swift package builds/tests Transport only, independent of UI/simulator. Existing synchronized Xcode groups can compile the files directly; value/protocol types explicitly opt out of MainActor default isolation, networking and storage remain actors. Integration may add the UI's CompanionDomain target when both branches are combined.

Run using the same scratch directory to avoid duplicate builds:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/clubhouse-transport-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/clubhouse-transport-module-cache swift test --scratch-path /tmp/clubhouse-transport-build --disable-sandbox
```

macOS executor sandbox blocks Security.framework RSA generation; tests require approved execution outside that sandbox, but generate keys only in memory and do not modify Keychain. No simulator or user desktop instance is launched by transport tests.
