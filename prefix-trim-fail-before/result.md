# #569 deterministic fail-before: H1 reproduced

Uncredited diagnosis on main f89bb9ee plus test-only fixture1f719268. QA verified both exact-once failures. Hosted and UI each fail ONLY the unchanged6pt assertion; all setup, final-arrived, model and pixel signatures pass.

| Case | Pinned | Entry lower before | Entry lower after | Shift | Final offset | Miss | Gate | Arrived |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Hosted |1324|1295|1198.333|−96.667|1324|+96.667|attempt2/54.659ms|137.003ms|
| UI |1081|1005|908.333|−96.667|1081|+96.667|attempt2/53.683ms|178.932ms|

UI reading marker166.667→70pt. Both2pt signatures passed. Native summaries/audits and app stdout are included. The real tail event changed the rendered prefix while delivery was withheld by the existing DEBUG hook; actual row frames and matching content heights gated release.

Build46133637 passed; reviewed policy/docs-only1f719268 reused byte-identical artifacts and passed compiled deinit and20policy tests. Original compile stop, policy stop and zero-test selector invocation receipts are preserved separately; no executed test was retried. Valid lifecycle99.56sec, swap0, private816524AA Shutdown+deleted/system0Booted/ownedprocess0. No restore logic changed.
