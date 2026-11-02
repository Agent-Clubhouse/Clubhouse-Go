# Long Dispatcher chat: test plan and evidence

Compare build 147 (`6c32b12`) and main (`ec99721`) with the same release-mode package workload: 1,000 and 5,000 routed deliveries, every twentieth delivery a long folded Markdown part, followed by 200 text chunks. Time projector application, full store replacement and timeline construction independently. Timings are observations on this Mac, not phone frame-time claims. Keep deterministic assertions on output parity and amount of processed work.

Regression plan: streamed/final text matches history; replay and session changes; queued burst boundaries and transitions; earlier-page window identity; Copy message and expansion state remain tied to original message IDs. Run package coverage and ratchet, app Debug and Release builds, app unit tests, preview and Dispatcher UI tests, and the long-reply scroll test on a newly created private simulator. Never run the live E2E script or touch the host app, shared simulators or physical phone.

Known limits: a package seam measures model work, not SwiftUI body executions, scrolling, typing, image decoding or physical-device memory pressure. Payload bytes are logical UTF-8 lengths, not heap allocation measurements (Swift strings and arrays may share storage). Network timings from the reported phone session do not measure main-thread/render cost.

## Retention audit (source facts, not heap measurements)

| Source | Lifetime / bound before this change |
| --- | --- |
| `CompanionChatProjector.items` | Full loaded session plus every live item; no item/byte cap. Session change clears it. |
| `CompanionConversation.items` | Full loaded live history, independent of the display window. Replacement may initially share Swift array storage; mutations can copy it. |
| `commandIDsByMessage` | One entry per phone receipt; history refresh carries it, session change previously did not clear it. |
| `queuedContentParts` (#209) | Raw submission blocks for rebuilding coalesced queued messages; some delivered transitions retained them until session reset. |
| Live service `buffers` | Events arriving during a history read, per target; removed after success/failure. No explicit capacity during the read. |
| Live service subscribers | `AsyncStream` uses default unbounded buffering; full timeline values can accumulate if the consumer falls behind. |
| Transport `eventCapacity` | Default 256 events, `bufferingOldest`; overflow is recovery/error work, not unlimited replay retention. Terminal stream is separately 4,096. |
| Snapshot | Read-local JSON plus the projection; no permanent raw chat snapshot cache. Project/agent catalog snapshots are per host. |
| Archive | Reader retains every loaded page in `eventsBySequence`, rebuilds a projection for every page; transcript holds accumulated items. Pagination does not evict old pages. |
| Markdown / slices | NSCache count limits 256 / 400; no byte-cost limit. Growing streamed text produces a new full-text key each time. |
| `iconCatalog` | Latest per-host project/agent icon JSON, replaced by snapshots, removed on host removal. No per-event icon history; decoded/per-agent Data and equality costs are separate. The icon-cache helper owns that fix. |

The assistant chunk constructor has `source == nil`, so `updateDisplay` takes the early `.you(text)` branch: routing regexes are **not** run for ordinary assistant text chunks. Routed MCP user deliveries do use routing/marker regexes. Long routed parts are folded by default, but an expanded part renders its whole rich text. There is no evidence yet that any one of these explains the physical phone's lag.

## First release measurements (before fixes)

These runs had concurrent compilation on the shared Mac; timing differences between revisions are not a statistically controlled comparison. Both expose the same expensive paths.

| Revision | Rows | Seed ms | 200 projector applies ms | 200 full store merges ms | 200 timeline preparations ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| build 147 / `6c32b12` | 1,000 | 82 | 229 | 992 | 2,941 |
| build 147 / `6c32b12` | 5,000 | 10,770 | 1,046 | 4,097 | 2,851 |
| main / `ec99721` | 1,000 | 301 | 282 | 1,174 | 2,255 |
| main / `ec99721` | 5,000 | 7,276 | 1,243 | 4,074 | 1,858 |

Both retain 5,001 rows after the 5,000-row stream workload and display pagination. The logical raw/routed UTF-8 payload is 1,244,042 bytes. This is not heap memory and does not count strings as independently allocated when they share storage.

## Proven fixes and remaining hypotheses

Projector lookup/upsert now indexes item IDs (rebuilding the index after queue removals). Same-session assistant chunks/finals publish one changed row instead of the entire history; the store mutates assistant rows without scanning optimistic user sends or copying an intermediate array. Replays do not publish redundant updates. Unchanged agent metadata does not emit another host catalog per chunk. Queue/interactions/session transitions keep full reconciliation, preserving queue semantics.

Entry preparation walks newest rows first and stops at the display window, keeping whole replies at the boundary. Completed message bodies use value equality; callbacks remain outside equality and are tied to the same transcript expansion identity, message identity and capability flags. Sender resolution remains its own environment subscriber, so live identity changes still propagate. Copy continues to use the full original message text, and message/part IDs and expansion ownership are unchanged. This is independent of hidden-tab work in #211.

This does **not** cap live or archive history. A hard tail cap needs an older-page retrieval path that also carries active approvals, queued joins, optimistic receipts, page boundaries and scroll/deep-link anchors. Silently dropping old rows would break current behaviour. The bounded-history follow-up should keep a recent in-memory tail plus active state, and fetch older event pages on upward scroll, preserving a viewport anchor before eviction. Current data proves avoidable update work; it does not yet establish memory pressure as the phone's cause.
