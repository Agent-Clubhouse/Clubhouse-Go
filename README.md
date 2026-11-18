# #569 Reading restore evidence

Product A on `3db11ac3234a47a4ba3420acdef8799d3e5c0309` has independent QA acceptance for static review, exact-head runtime and combined coverage. [PR #583](https://github.com/Agent-Clubhouse/Clubhouse-Go/pull/583) is ready for the orchestrator’s merge decision; GitHub CI remains pending. #569 stays open for a device check. First-paint seeding is deferred to #582.

- [Final product-A results, receipts and QA verdict](product-A-r2/README.md)
- [Deterministic fail-before](prefix-trim-fail-before)
- [Product-A plan](product-A-plan)
- [Original e45 failure](original-e45)
- [Historical b829 confirmation: not reproduced](b829-confirmation-r1/README.md)
- [Main logging: not reproduced, real trim outside pin-to-arrival window](main-logging-r1/result.md)
- [Nonblocking screenshot comparison: same black band on historical main](black-band-main-comparison/result.md)

The deterministic fixture confirmed H1: the same bookmarked entry moves by −96.667pt when the rendered prefix trims after the numeric target is pinned. The old restore misses by +96.667pt; product A retargets on that entry’s measured movement and arrives with effectively zero miss. H2 teardown-save corruption was not required or observed in this reproduction. All original 6pt checks remain.

The orchestrator was asleep when QA attempted delivery. No wake or restart is authorized. This durable handoff preserves the result until it can be reviewed; the helper does not merge.
