# Clean visible Home comparison

Head: `48a6f022135c4df68a8b867e330ae16c1fdb5a4b`; baseline: `67b8e5b88b84de190e0234290978615f33362d96`. Same uncredited method, two fresh launches per side. Counts are primary; process CPU is supporting only.

| Run | Case | Stream batches | Main and head owner/content/layout | Main and head headers/scope | Inputs | Main→head dispatcher | Main→head menu |
|---|---|---|---|---|---|---|---|
| 1 | Visible Dispatcher | 0 | 4 | 96 / 328 | =owner | 3→0 | 6→6 |
| 1 | visible-dispatcher | 1–9 | 3 | 72 / 246 | =owner | 3→0 | 6→6 |
| 1 | loaded-outside-scope-agent | 0–9 | 3 | 72 / 246 | =owner | 3→0 | 6→6 |
| 2 | Visible Dispatcher | 0 | 4 | 96 / 328 | =owner | 3→0 | 6→6 |
| 2 | visible-dispatcher | 1–9 | 3 | 72 / 246 | =owner | 3→0 | 6→6 |
| 2 | loaded-outside-scope-agent | 0–9 | 3 | 72 / 246 | =owner | 3→0 | 6→6 |

Every candidate menu batch: modifier=6, native=0, items=0, terminal=0. No totals are normalized. Both runs meet the paired baseline and the approved fixed ceilings.

| Run | Case | Main app CPU (s) | Head app CPU (s) |
|---|---|---:|---:|
| 1 | visible-dispatcher | 0.978397 | 0.990978 |
| 1 | loaded-outside-scope-agent | 0.988756 | 0.950081 |
| 2 | visible-dispatcher | 1.036111 | 0.968449 |
| 2 | loaded-outside-scope-agent | 0.977704 | 0.975606 |

Strict pushed: exact1 PASS; build, compiled deinit and20 policy tests PASS. All owned lifecycles ended Shutdown with0 Booted system-wide and0 swap growth. No retries. Anchor restore is excluded and preserved unproven in #567 / Draft #568.

The cheap Home owner is not frozen: the strict pushed attachment records17→38 (+21)
over100 chunks, and59→62 (+3) for the linked chunk. Every expensive child/input/layout/
header/quiet/row/menu counter remains identical across each baseline window. This is
not a claim of zero parent-body work or a phone CPU/battery improvement.
