# Visible Home observation (#528)

Base: main `92b6f1ca`. #551 stopped expensive hidden-tab work, and #558 froze pushed Home children. Visible Home still followed unrelated transcript chunks through two broad observation scopes:

- Home's attention projection called the conversations-derived attention API. A waiting agent registered the entire `conversations` dictionary with the Home owner.
- Root constructed the Dispatcher reply/streaming view inline. Its reads of cached Dispatcher conversations could invalidate Root and reconstruct Home alongside it.

The Dispatcher construction now runs inside a concrete child body, retaining the same Root navigation State and callbacks. Reply checkpoints, unread badges, streaming status, desktop selection and navigation behavior use the same production code.

Home uses a decision-only value projection. Full conversation storage and the existing `attentionItems` API remain live and unchanged for other callers. Both attention APIs share the same pure selection/urgency/ordering logic. Home's projection stores the full approval and question values, including metadata and every resolution, in timeline order. It observes decision changes; plain assistant text, tool and sequence updates never write it.

Projection update boundaries:

| Mutation | Projection handling |
|---|---|
| Accepted history replacement/merge | Filter the final accepted item list |
| Accepted timeline replacement/merge | Filter the final merged item list |
| Approval/question upsert, including local submitting and completion/refusal/uncertainty | Filter the final item list after upsert |
| Removed desktop/durable agent | Remove the same target's projection |
| Plain message/tool/text delta/stream finish/delivery metadata | No decision projection work |
| Reconnect/epoch change | Preserve the same retained conversation decisions; existing connection/authority guards still apply |

An empty projection is not a fabricated request: attention falls back to the same agent-status unreviewed/failure state as the conversations-derived path. No command authority comes from this projection.

The package parity matrix drives both target identities through all three real command outcomes. It checks complete attention output and raw decision values after every event/load/command and during the submitting service callback, including metadata-only replacement, stale sequence rejection, history/timeline clearing, reconnect/epoch and removal. Separate observation controls prove text chunks do not notify Home and actual decisions do. The mounted Root test keeps a real pending approval on Home during 100 Dispatcher chunks, then verifies pixel-visible metadata/question changes and removal.

Validation uses the unchanged r2 two-case live measurement twice on main and twice on the head, with identical overlays and fresh provenance. Counts remain primary; no phone CPU/battery claim. Existing pushed/hidden/Recent/authority methods retain all assertions. Anchor restoration remains outside this work in #567/#568; tab return still starts at the top.
