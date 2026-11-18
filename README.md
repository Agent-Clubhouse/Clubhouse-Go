# #582 / draft #584 — HARD STOP after the bounded experiment

Exact source `7c12e00df` is NOT merge-ready. A-r4 fresh build, compiled deinit gate and20policy tests PASS. FD-r2's ONE F1 UI method PASS reached all scenarios, but its real video FAILS the first-frame gate: native destination reopen paints marker1 before jumping to90. No assertion or test retry follows it.

See [runtime/fd-r2/report.md](runtime/fd-r2/report.md) for the decisive73.333ms transition, full unaltered video/PNGs, actual frame timestamps, app stdout/timeline, controls, limits and exact cleanup. The synchronous cached-ID proxy request did execute once; native offset remained0 until the existing geometry correction.

The initial expanded paused opening improved, but the native-destination counterexample triggers QA/Orchestrator's hard stop. All N/H/S/CPU/broad/combined runs remain held. The earlier zero-command assertion is unchanged. Private simulator8876542F was deleted, system-wide0Booted, owned processes empty, swapgrowth0; host released.

Two explicit options go to the Orchestrator/user: start the initial window at the bookmark, moving older history behind Show earlier messages (a UX/contract decision requiring new review/proof), or do not ship #582 and retain shipped behavior. No further timing iterations or silent window trimming.

History: runtime/fd-r1 preserves the original expanded-mount top-to-bookmark failure. runtime/a-r4 preserves the fresh build/gate results. Earlier proposals and A/N receipts remain as honest history; old CPU overlays are stale and must not be run.
