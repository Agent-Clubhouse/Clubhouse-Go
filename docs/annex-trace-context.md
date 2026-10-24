# Annex distributed tracing handshake v1

Aligned with desktop PR #2437's `docs/fixtures/annex-tracing-v1.json`; the same
fixture is checked in at `Tests/ClubhouseTransportTests/Fixtures/telemetry-handshake-v1.json`.

After existing pinned mTLS authentication and control capability verification,
mobile sends one optional WebSocket message:

```json
{"type":"telemetry:hello","payload":{"version":1,"serviceName":"clubhouse-go","serviceInstanceId":"11111111-1111-4111-8111-111111111111","connectionAttemptId":"22222222-2222-4222-8222-222222222222","traceContext":"w3c-v00"},"tc":"00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"}
```

Host `telemetry:hello:ack` payload contains `version:1`, `serviceName:"clubhouse"`,
`serviceInstanceId`, echoed `peerServiceInstanceId` and `connectionAttemptId`,
socket-lifetime `connectionId`, and `traceContext:"w3c-v00"`. Optional recording
and sampling fields describe host choices; they never change mobile consent.
Mobile accepts only matching current-socket/attempt echoes and canonical UUIDv4
identifiers. Invalid, unsolicited and late acknowledgements are ignored. No REST
handshake or connection-header registration exists. Hello/ack is the optional
capability negotiation; an old host can ignore it. Mobile never delays normal
snapshot/chat for an ack and expires the diagnostic attempt after five seconds.

Local immutable resources: `clubhouse-go` on phone, `clubhouse` on host, each with
random process-lifetime `service.instance.id`. Restart changes it; reconnect and
capture toggles do not. Every reconnect has new attempt/socket UUIDs. Multiple
phones/hosts remain distinct. Peer metadata cannot replace local resource identity
or grant auth; existing mTLS/pairing/revocation rules remain authoritative.

Authenticated HTTP propagates W3C `traceparent`. A response observation uses a
validated host parent only if its trace ID matches the request. WebSocket envelopes
carry optional top-level `tc` as a traceparent string. Per-operation roots are
independent; never parent all chats to the connection trace. A live `turn_started`
can parent a mobile stream to host `tc`. Replayed envelopes retain original `tc`
but do not create new live timing spans. Idempotency bodies/keys are unchanged.

Strict version-00 validation: lowercase hex, exact length, nonzero IDs. No baggage.
Tracestate is bounded to 512 bytes/32 members and syntax checked; opaque vendor
values are discarded until an approved vendor policy exists. Local capture samples
bounded spans only while enabled; host sampling/export choices remain independent.
Reference: https://www.w3.org/TR/trace-context/

Backend gate: matching trace IDs in payloads are not proof of complete ingestion.
Framebriar `src/telemetry.mjs` currently drops `service.instance.id`; preserve a
validated UUIDv4 per resource group and test Azure mapping before claiming shared
backend instance correlation. Destination configuration is independent of feedback.
No remote exporter or credentials have been enabled by this change.
