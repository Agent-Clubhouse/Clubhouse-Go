# #582 / draft #584 evidence (work in progress)

Current source caaac0337 BUILDS but FAILS first-paint correctness. This is not merge-ready.

FD-r1 proves the expanded paused transcript first paints Reading marker 1, then jumps to saved marker 90 (offset 0 to 8605.333pt). The full unaltered recording, selected full PNGs with actual timestamps, full stdout timeline, report and exact cleanup are in runtime/fd-r1. Fresh Latest shows the tail on its first frame. Destination reopening and opposite-state chat switches were not reached because of a later recording-helper hittability error. No retry or acceptance is claimed.

QA approved one bounded experiment BEFORE code: synchronous cached-ID proxy scroll request on first appearance, once per transcript identity, with no delay, guessed offset, window trimming or assertion relaxation. The proposal is runtime/fd-r1/redesign-proposal-r1.md. The exact implementation and run configuration still require QA static review before building. If it paints wrong first, stop this approach.

A-r3 passed build, compiled deinit gate and 20 policy tests. N-r1 stopped at the new zero-numeric-arrival method (10/11 methods, 11/12 executions passed); its assertions remain unchanged. All four existing Reading/restore/hidden contracts remain byte-identical to main77b24899. FD's simulator was deleted, system0Booted/processes[]/swap0. All acceptance/broad/CPU/coverage phases remain held.

Earlier proposal/manifests and original A/N receipts are preserved as history. CPU r2 overlays are stale after any new product head and must not be run without refreshed provenance and QA review.
