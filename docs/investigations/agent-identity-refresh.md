# Agent identity during refresh and reconnect

## Regression and test plan

Use `CompanionIdentityRefreshTests` with the live-service harness to reproduce transient identity loss before changing the service. Observe every host publication, not only the final result. Load a 2,001-message Dispatcher conversation, suspend, then resume through `prepareResume` re-registration (the route relocation path). Assert identity and chat survive, a default cached lookup does not reread history, and the UI's explicitly forced resync still does.

Exercise failed capabilities and catalog reads; snapshots missing projects, agents, individual project agent lists, quick agents or Dispatcher; malformed REST catalogs; snapshots before capabilities arrive; explicit empty authoritative catalogs; Dispatcher off and flag off; replacement Dispatcher identities, and forgotten hosts. Navigation tests distinguish initial loading, synchronization and offline connection states from confirmed absence. Complete snapshots and completed REST catalogs must still remove missing agents and projects.

Use real `AnnexTransport` with fake HTTP/WebSocket I/O to count foreground sockets and reads for both ordinary reconnect and route replacement. Pause a live-service capability read to reproduce reconnect's `resyncRequired`/`connected` race, and separately let REST finish before `connected` arrives. Both signals must share one catalog synchronization. Keep catalog-change follow-up refreshes intact.

## Findings

All primary identity-loss paths existed in build 147 (`6c32b12`) and remained on main (`eedf651`, including #208/#209):

- `CompanionLiveService.register` reconstructed the host, retaining projects but dropping Dispatcher, capability flags and other host metadata. `prepareResume` route switching and rediscovery both re-register. Ordinary reconnect without re-registration retained identity.
- `CompanionStore.apply(.hosts)` interpreted any missing Dispatcher `liveAgent` as shutdown and cleared the conversation, pending commands and history generation.
- `applyCatalog` converted absent projects/agent maps into empty arrays and replaced all projects. Partial snapshots could therefore blank Home/Agents and the active agent destination. Explicit empty complete catalogs are legitimate deletions and must remain so.
- `refresh` swallowed a failed capabilities read with `try?`, then replaced cached service capabilities with nil and reconstructed Dispatcher as absent. The transport's own capability cache is separate: clearing that cache alone did not delete service identity.
- A catalog read that actually throws already retained prior identity. Malformed successful payloads previously decoded as empty; those now fail without declaring deletion.
- Missing quick-agent/Dispatcher fields and incomplete/malformed Dispatcher agent entries are unknown. An explicit empty quick-agent map or `dispatcher: null` is authoritative. Explicit `enabled: false` or `flagOn: false` objects also shut it down. Latest desktops send the Dispatcher field, null while off.
- Every socket snapshot emits `connected`. After automatic reconnect, `resyncRequired` followed by `connected` could schedule two catalog passes. This also happened if the first REST pass had already completed. Repeated connected snapshots now keep the current synchronization; actual catalog-change events still coalesce a follow-up.

## Measurements

These are deterministic fake-I/O counts, not device latency measurements. No real desktop or phone was contacted.

| Scenario | Before | After |
| --- | --- | --- |
| Default cached lookup of 2,001-message Dispatcher chat after resume/relocation | 1 full history read; loaded chat discarded | 0 reads; all 2,001 rows retained |
| Actual conversation-view navigation after reconnect | Forced history resync | Still one forced history resync; cached rows stay visible |
| Reconnect resync plus first-snapshot connected | 2 complete catalog passes | 1 complete catalog pass |
| 13-project desktop, duplicate reconnect signals (inferred from pass count) | 26 per-project agent reads | 13 per-project agent reads |

The actual conversation view uses `load(force: conversation.requiresResync)` on navigation and forces resync when the connection becomes operable. Consequently, **there is no demonstrated reduction in actual UI foreground history reads**: the required full history synchronization remains. The default-load count isolates eviction's effect; it must not be interpreted as eliminating the UI's required reconnect read. This fix preserves the rendered transcript and identity while that read runs.

A foreground with 13 projects opens **one new socket**, closes **one old socket**, and does not close the new socket. This holds for both ordinary resume and `prepareResume` with a replacement transport. It makes 17 HTTP reads: one identity verification, two capability reads (transport negotiation and service catalog), one project list and thirteen agent lists. The harness did not reproduce three socket accept/close pairs in one foreground. A socket close method can be invoked more than once during cancellation; the fake counts unique socket closures, matching an idempotent WebSocket close.

## Validation

- Initial identity regression run: 10 tests, 20 issues; failed catalog reads and authoritative deletion controls already passed.
- Duplicate reconnect scheduling tests separately failed with two catalog passes instead of one before the scheduling changes.
- Final package suite: 907 tests pass, with coverage gate passing (Transport 96.38%, Domain 94.07%). One earlier concurrent run hit the existing five-second icon-refresh harness timeout under load; the transcript count fixture now uses 2,001 short messages, avoiding an unrelated parsing benchmark while retaining the same identity/read-count assertions.
- App build/UI results and any rebases are recorded in the draft PR. The preliminary simulator run was deliberately superseded after the final partial-entry guard; final suites use rebuilt binaries.

Scope: live service, store identity cleanup, a loading predicate, and a narrow conversation-destination loading branch. No projector, transcript/timeline or Dispatcher tab changes.
