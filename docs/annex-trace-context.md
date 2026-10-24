# Annex distributed tracing handshake v1

Local immutable resources: phone service.name=clubhouse-go, desktop existing service.name=clubhouse. service.instance.id = lowercase UUIDv4 per app-process lifetime, fresh on restart, stable across reconnect/capture toggles. No hostname/hardware/user identifiers. Peer metadata never replaces local resource identity. Local capture off does not initiate telemetry handshake or send propagation headers.

GET /api/v1/mobile/capabilities optional:
telemetry: { version: 1, handshakePath: '/api/v1/mobile/telemetry/handshake' }
Old host without field: normal connection, no handshake; local diagnostics mark distributed support unavailable. No fallback guess or unauthenticated probing.

POST exact advertised allowed path (same pinned TLS + bearer/mTLS auth, W3C traceparent header):
{version:1, service:{name:'clubhouse-go',instanceId:'<phone process UUID>'}, connectionAttemptId:'<fresh UUID each reconnect>'}
Response 200:
{version:1, service:{name:'clubhouse',instanceId:'<host process UUID>'}, peer:{name:'clubhouse-go',instanceId:'<exact request phone UUID>'}, connectionAttemptId:'<exact request attempt UUID>', connectionId:'<new server UUID>'}
Limit handshake response 4KiB; strict UUIDs and fixed service-name enums. Telemetry IDs are correlation only, NEVER auth. Server must bind connectionId to already authenticated pairing peer + phone instance + attempt, not allow arbitrary lookup/hijack by UUID. Connection metadata is ephemeral/bounded and cleared on Annex restart/revoke. Subsequent API/WS upgrade carries x-clubhouse-connection-id. Validate peer binding; do not reject legitimate old clients for missing header. Server control/auth semantics remain authoritative regardless tracing support.

Host restart: new service instance; next handshake fresh connection. Multiple phones/hosts: each process identity distinct, each transport connection binding independent. Reconnect gets new attempt/connection UUID and root trace; chat operations never parent to the connection-long span. Per-operation traceparent does not affect command idempotency digest/key. Replay preserves original turn traceContext; client dedups session/seq and never counts history as live streaming.

ALIGNED WITH DESKTOP: outer WebSocket envelope tc is the W3C traceparent STRING, especially for chat:event wrapping turn_started. Supersedes prior inner traceContext proposal. HTTP response traceparent accepted only if validated and trace ID matches the outgoing request. Represents per-turn host span, related to originating authenticated command when known. New unrelated turn = fresh trace. No baggage. Mobile checks strict lowercase v00 parent/nonzero IDs; malformed context ignored. tracestate bounded512B/32members, vendor values dropped until explicit vendor allowlist. Local capture samples bounded spans; current implementation uses always-on local sampler only while capture mode enabled. Host retains its own consent/export/sampling choices.

Backend proof still needed: actual exported OTel resource service.name/service.instance.id and span traceId/spanId/parentSpanId retained by shared destination. Framebriar current service sanitization appears to whitelist resource fields and may DROP service.instance.id: investigating src/telemetry.mjs trustedResource/sanitizeSignal. This is a real potential end-to-end gap, not solved by payload IDs.

Reference: https://www.w3.org/TR/trace-context/

Shared fixture: `Tests/ClubhouseTransportTests/Fixtures/telemetry-handshake-v1.json`.
