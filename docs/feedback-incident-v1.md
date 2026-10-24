# Feedback incident correlation v1 — mobile proposal, 2026-10-24

Owner split: mobile implements vendored SDK/review/snapshot/queue. Framebriar service owner implements normalization/storage and capability echo. No deployment or live upload.

Optional report field `incident` (existing report `v:1` unchanged):
```
{
  "version": 1,
  "id": "UUIDv4 lowercase; distinct from report ID",
  "capturedAt": "ISO8601 UTC",
  "windowStart": "ISO8601 UTC",
  "windowEnd": "ISO8601 UTC",
  "availability": "recorded | unavailable | collection_off",
  "phoneInstanceId": "UUIDv4 lowercase",
  "hostInstanceIds": ["UUIDv4 lowercase"],
  "connectionIds": ["UUIDv4 lowercase"],
  "traces": [{"traceId":"32 lowercase hex nonzero", "spanId":"16 lowercase hex nonzero"}],
  "backendRef": "optional UUIDv4 lowercase; logical local destination reference only"
}
```
Bounds: JSON <=4096 bytes; max8 trace references, max4 host IDs/max4 connection IDs, no unknown keys retained. Times valid ISO8601; start <= end == capturedAt; window <=300 seconds. All UUIDs strict v4. `recorded` requires >=1 trace; other availability values require empty traces. These are recent LOCAL recorded span references, not a guarantee of remote ingestion or sampling. BackendRef is not URL, credential or authenticated identity. Phone/host process IDs and socket connection IDs come only from validated resource/hello-ack. Never infer host instance from address. Report's legacy flat `traceId` / `spanId` mirror first incident reference, if any. Upload request IDs/trace are never substituted for incident references.

Snapshot at feedback screen creation, immutable throughout review and offline retries. User can remove optional correlation before review; SDK persists exactly reviewed incident in queued report. No automatic screenshot/log/content capture.

Capability negotiation required to avoid silently dropped unknown fields: redeem/refresh response optional numeric `feedbackCorrelationVersion:1`. Mobile retains incident-bearing queued reports without sending until current session advertises v1; ordinary reports unaffected. No persistent capability assumptions across refreshed access. Service must add this response field only when normalizer and storage support incident v1. Please confirm/update this shared file if different exact keys are needed before publishing.

## Service agreement — task-4, 2026-10-24

Accepted: service PR https://github.com/masra91/framebriar/pull/11 is being aligned to this `incident` / `version` schema. This supersedes the preliminary `/tmp/framebriar-incident-correlation-schema.md` contract and its first CI run. The service will advertise numeric `feedbackCorrelationVersion: 1` in successful redeem and refresh responses (including retryable redeem replies).

Wire details for deterministic validation: all listed fields except `backendRef` are required when `incident` is present. UTC timestamps accept seconds with optional 1–3 fractional digits (`YYYY-MM-DDTHH:mm:ss[.SSS]Z`), reject impossible dates, and preserve the original string. Window equality/order uses instants, not text. Incident ID must differ from the report ID. When traces are nonempty, the existing top-level traceId/spanId pair must match the first reference; when traces are empty the flat pair must be absent. No trace is synthesized by the service. Unknown keys are dropped. Null/absent incident remains a legacy report; null backendRef is normalized to absence. No other key changes requested.

The capability gate is essential: hold incident-bearing reports for a current supporting session, preserving the reviewed bytes. Do not strip metadata or change report identity to force delivery. Service storage preserves the incident through process/abandonment and deletes it at existing seven-day context expiry. No backend connection or OTLP ingestion changes.

Service implementation is now commit `4cfb097` in PR #11. Shared service-validated full report fixture: `/Users/masonallen/Documents/Codex/2026-10-23/task-4/framebriar-correlation/tests/fixtures/incident-report-v1.json`. No SDK changes were made by the service owner. Hosted CI rerun is pending on this coordinated schema.
