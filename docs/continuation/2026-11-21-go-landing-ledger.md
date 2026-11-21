# Go landing ledger

Observed 2026-11-21 around 04:34 UTC. All ten PRs open. Zero new merges, zero currently eligible for reviewed-green landing. Main remains cadce0a4575227a5ad24a6956f819f42913446d8. Snapshot data may change after publication.

## Landing order and authority

Prioritize #612 and #606 independently, with #607 in parallel. #612 has compiled and released; #606 packages have passed. If all jobs obtain runners promptly and pass the first time, allow roughly one build/UI cycle (about 45–90 minutes from admission of the outstanding critical jobs). Queue delay, limited concurrent lanes, failures or retries can extend that by hours. This is a planning estimate, not a promised merge time. Recheck the PR head, original target outcomes and aggregate at landing.

Main ruleset 13081209 enforces PR/squash, linear history, non-fast-forward and deletion protections. Zero required approving GitHub reviews and no required-status-check rule were returned for main. Each PR currently has zero GitHub review entries. Independent source reviews are recorded separately. Assignment requires reviewed green; Navi explicitly reconfirmed no red-merge exception for #607. A technically possible squash does not supply the missing acceptance. No additional user decision is needed for these independent normal runs.

The prior shared CI topology repeatedly exhausted job limits before target tests. Feature proof was sometimes obtained while aggregate remained red. Some sequenced work cost time: #606's current-main/permission head started CI, then its evidence-backed Footer revision superseded that run after planning, before a Mac runner was assigned. Feature routing and reuse of reviewed common fixes on independent heads are already underway. No old cancelled or retry-only result is promoted to first-pass acceptance.

## PR #606

Head `5165f16003d397429dd0468fa3592bcbb628e357` on base `main`. Independent 80f31961 and 6b5527f4 reviews. The three Send contrast tests passed first on 9df. Original Footer dark line 187 failed after a drag whose start fell in the editor in nearby geometry. This head corrects its target and carries the reviewed permission-menu test. Verify the three Send methods, Footer gesture and permissions on this head.

[Run 44863839254](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44863839254), attempt 1, created 2026-11-21T03:59:30Z. Completed run elapsed or current run age 35 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.2 | yes |
| Release build | queued | 34.2 | no |
| Build for testing | queued | 34.2 | no |
| Swift packages | success | 4.9 | yes |

## PR #607

Head `ebeef76baa9018392b1afcfc1fc18f0421db7e85` on base `main`. Independent 85907fe1 current-main carry. Six original candidate tests passed once, while five baseline tests failed at the predicted assertions. Prior aggregate transport/permission failures reproduced on main, and #613 fixed the old grant test. The new head still needs normal green CI.

[Run 44861410801](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44861410801), attempt 1, created 2026-11-21T03:29:49Z. Completed run elapsed or current run age 64 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.2 | yes |
| Release build | queued | 64.0 | no |
| Build for testing | queued | 64.0 | no |
| Swift packages | queued | 64.0 | no |

## PR #612

Head `778657aceac306fb0dea2a96bd60dc4afdfc6818` on base `main`. Independent 6fbf97e6. Seven iPhone cases passed first on the previous head. The former iPad failure at line 318 selected an inactive dismiss region before any tap. Current test binds the active popover and has compiled on hosted CI. Verify an actual outside cancellation, then separate explicit Send, and seven iPhone outcomes.

[Run 44862191194](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44862191194), attempt 1, created 2026-11-21T03:38:48Z. Completed run elapsed or current run age 55 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Release build | success | 7.5 | yes |
| Build for testing | success | 4.0 | yes |
| Swift packages | queued | 55.1 | no |
| iPad hosted tests + UI smoke | queued | 6.1 | no |
| UI tests (search, permissions) | queued | 6.1 | no |
| UI tests (reading, grants) + unit tests | queued | 6.1 | no |
| UI tests (preview, project pages) | queued | 6.1 | no |
| UI tests (dispatcher, terminal) | queued | 6.1 | no |
| UI tests (composer, sheets) | queued | 6.1 | no |
| UI tests (other) | queued | 6.1 | no |
| UI tests (feedback, needs you) | queued | 6.1 | no |
| UI tests (unicode, home) | queued | 6.1 | no |

## PR #615

Head `0258e49cf24b0c91707acae671bdd52ce872cc38` on base `main`. Six link tests never started on the original catch-all. Actual failed methods include PermissionMenu landscape 74 (all three attempts), largest-text 37, SettingsDraft offscreen desktop-name predicate, and Reading prepend 386 (113 vs 209.67 with tolerance 4). Permission failure also seen on main; Settings/Reading were independently observed elsewhere. Existing plan uses the common CI repair for routing, then rebases and executes six links and archive control. A focused routing carry is being evaluated separately.

[Run 44622082206](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44622082206), attempt 1, created 2026-11-19T21:46:12Z. Completed run elapsed or current run age 210 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Release build | success | 8.2 | yes |
| Build for testing | success | 4.0 | yes |
| Swift packages | success | 7.7 | yes |
| UI tests (other) | cancelled | 57.2 | yes |
| UI tests (preview, project pages) | success | 53.2 | yes |
| UI tests (unicode, home) | success | 38.8 | yes |
| UI tests (feedback, needs you) | cancelled | 56.3 | yes |
| UI tests (search, permissions) | failure | 31.2 | yes |
| UI tests (dispatcher, terminal) | cancelled | 57.2 | yes |
| UI tests (composer, sheets) | success | 32.2 | yes |
| iPad hosted tests + UI smoke | success | 22.6 | yes |
| UI tests (reading, grants) + unit tests | failure | 54.5 | yes |
| CI result | failure | 0.1 | yes |

## PR #616

Head `7e781fedd4a7036beca5bd3468024c852d77d6aa` on base `main`. Independent f97a5466. Seven provider cases plus archive routed without changing their bodies. On 434 six provider first passes, LostStart interrupted and archive zero starts. Current package failure is snapshotFailureKeepsCommandsUsableDuringGraceThenRecoversThroughBackoff at 493/590, two issues, also observed on earlier #622; no new provider behavior implicated by this job. Eight first UI outcomes and package repair still needed; integration with common base remains separate.

[Run 44863554272](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44863554272), attempt 1, created 2026-11-21T03:55:44Z. Completed run elapsed or current run age 38 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Build for testing | success | 4.0 | yes |
| Swift packages | failure | 4.1 | yes |
| Release build | in_progress | 2.0 | yes |
| iPad hosted tests + UI smoke | queued | 3.0 | no |
| UI tests (unicode, home) | queued | 3.0 | no |
| UI tests (feedback, needs you) | queued | 3.0 | no |
| UI tests (search, permissions) | queued | 3.0 | no |
| UI tests (dispatcher, terminal) | queued | 3.0 | no |
| UI tests (reading, grants) + unit tests | queued | 3.0 | no |
| UI tests (preview, project pages) | queued | 3.0 | no |
| UI tests (composer, sheets) | queued | 3.0 | no |
| UI tests (other) | queued | 3.0 | no |

## PR #617

Head `47e230577d3d51219b01f075aadf2c3a1d64e1c4` on base `go-feedback-review/mobile-tappable-links`. Depends on #615. Exact preview dismissal and path resolution first passed (123.098s, 96.398s). Dispatcher grant navigation 179 and PermissionMenu 74/37 failed. Other job cancelled with zero link starts and separate menu/keyboard/Footer failures. Repeated permission behavior predates this feature. Keep first outcomes, carry relevant reviewed fixes and validate the resulting stack.

[Run 44853082221](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44853082221), attempt 1, created 2026-11-21T01:56:37Z. Completed run elapsed or current run age 135 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Release build | success | 7.8 | yes |
| Build for testing | success | 3.9 | yes |
| Swift packages | success | 3.8 | yes |
| iPad hosted tests + UI smoke | success | 21.6 | yes |
| UI tests (dispatcher, terminal) | failure | 44.2 | yes |
| UI tests (search, permissions) | failure | 26.6 | yes |
| UI tests (other) | cancelled | 57.6 | yes |
| UI tests (reading, grants) + unit tests | success | 45.9 | yes |
| UI tests (feedback, needs you) | success | 52.0 | yes |
| UI tests (composer, sheets) | success | 37.9 | yes |
| UI tests (unicode, home) | success | 39.9 | yes |
| UI tests (preview, project pages) | success | 51.0 | yes |
| CI result | failure | 0.1 | yes |

## PR #619

Head `0e3cf23de154b4a7a00544d70ec9e7dcd88cbafd` on base `main`. Base main, but composes #615/#617. Original-file export/cancel passed first in 178.387s, path resolution 104.003s, dismissal 114.335s. Cancelled catch-all had zero link starts and actual Header visual 327 and Footer 187 failures. Other cancelled lanes include Dispatcher copy 325, sender reveal 654, GrantRequest 179, PinnedDecision 76. Several signatures recur across heads; new failures remain unattributed until compared with matching originals. Preserve passing feature evidence and repair actual stack coverage.

[Run 44853095840](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44853095840), attempt 1, created 2026-11-21T01:56:47Z. Completed run elapsed or current run age 157 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Release build | success | 6.7 | yes |
| Build for testing | success | 5.0 | yes |
| Swift packages | success | 5.6 | yes |
| iPad hosted tests + UI smoke | success | 22.7 | yes |
| UI tests (dispatcher, terminal) | cancelled | 57.4 | yes |
| UI tests (preview, project pages) | success | 49.6 | yes |
| UI tests (feedback, needs you) | cancelled | 56.2 | yes |
| UI tests (composer, sheets) | success | 36.0 | yes |
| UI tests (other) | cancelled | 57.2 | yes |
| UI tests (unicode, home) | success | 29.7 | yes |
| UI tests (search, permissions) | in_progress | 7.0 | yes |
| UI tests (reading, grants) + unit tests | in_progress | 6.2 | yes |

## PR #620

Head `8d5ac476093cdbb0d8c42b63a91202e735b2a98a` on base `main`. Independent four-file union review 4ce4f623. Packages passed. SpringBoard/HeaderReflow revised, Avatar adds diagnostics only. e334 had transport timeout, ReadingOpening 58, Back/Launch/menu failures, draft prefixes, feedback capture and avatar first red. No current-head UI outcome inferred from predecessor. Transport bound and Reading device decisions apply only to their own cases. Typing change held. Continue current UI checks.

[Run 44863779955](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44863779955), attempt 1, created 2026-11-21T03:58:42Z. Completed run elapsed or current run age 35 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Release build | success | 6.8 | yes |
| Swift packages | success | 4.5 | yes |
| Build for testing | success | 3.4 | yes |
| iPad hosted | queued | 6.3 | no |
| iPad UI smoke | queued | 6.3 | no |
| UI tests (dispatcher, settings) | queued | 6.3 | no |
| UI tests (grants, projects) + unit tests | in_progress | 1.1 | yes |
| UI tests (composer, keyboard) | queued | 6.3 | no |
| UI tests (unicode, reading) | queued | 6.3 | no |
| UI tests (feedback diagnostics) | queued | 6.3 | no |
| UI tests (footer, desktop scope) | queued | 6.3 | no |
| UI tests (header, catalog) | queued | 6.3 | no |
| UI tests (opening, terminal) | queued | 6.3 | no |
| UI tests (activity, permissions) | queued | 6.3 | no |
| UI tests (other) | queued | 6.3 | no |
| UI tests (preview) | queued | 6.3 | no |
| UI tests (decisions, linked home) | queued | 6.3 | no |
| UI tests (chips, lifecycle) | queued | 6.3 | no |
| UI tests (launch, native menus) | queued | 6.3 | no |
| UI tests (home, settings) | queued | 6.3 | no |

## PR #621

Head `44232736ded1e7ad4c56667cd90dba503d3013c6` on base `go-feedback-review/integrate-ci-links`. Based on #620 integration branch. Exact original local Home baseline 1P1F vs candidate 3P0F; reviewed originals 3a1bd589. No PR workflow on temporary base. After accepted common landing retarget/rebase main and run the three hosted feature methods; do not merge into dependency branch.

No checks attached to this PR head.

## PR #622

Head `7119bd5ff848db24e279c61947af352f881d4cc3` on base `main`. Independent 7119 routing review, 36 CI checks. Previous head 11 target package methods first pass and zero recovery UI starts. New package failure comprises four named tests, six printed issue events, seven reported by aggregate. Both transport grace cases have explicit Issue plus ScheduledConditionTimeout. Rediscovery exceeded 20s by 0.667s; pinned-WebSocket ping telemetry assertion failed. Three failing test files byte-identical to current main. Transport overlaps demonstrated historical failures; equivalent baseline runtime occurrence for the last two is unverified. Test workload and production composition can differ. Fixture-only deterministic fast-ping attribution in progress. Verify two recovery UI first outcomes independently.

[Run 44861492593](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44861492593), attempt 1, created 2026-11-21T03:30:42Z. Completed run elapsed or current run age 63 minutes.

| Job | State | Minutes | Runner assigned |
|---|---|---:|---|
| Plan | success | 0.1 | yes |
| Swift packages | failure | 3.7 | yes |
| Build for testing | success | 4.1 | yes |
| Release build | in_progress | 3.0 | yes |
| iPad hosted tests + UI smoke | queued | 7.0 | no |
| UI tests (other) | queued | 7.0 | no |
| UI tests (unicode, home) | queued | 7.0 | no |
| UI tests (composer, sheets) | queued | 7.0 | no |
| UI tests (dispatcher, terminal) | queued | 7.0 | no |
| UI tests (preview, project pages) | queued | 7.0 | no |
| UI tests (search, permissions) | queued | 7.0 | no |
| UI tests (feedback, needs you) | queued | 7.0 | no |
| UI tests (reading, grants) + unit tests | queued | 7.0 | no |

Job minutes use the job API start to completion or observation. For queued jobs they measure time since the queue record, not CPU time. Some completed jobs include setup and cleanup. Method evidence and limits above come from original job logs and independent review receipts.
