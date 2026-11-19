# #614 one-group offline classification — review request

Native source 4601d1c97dc44637262d9ce98df1651ed2095447, merge tree f9c9e532ca60ed76977a364269043c4eff8eb77a, original manifest 08dcf38a4af28a0343c1cda96985d07256fcb67a28be2a6af54bf0ae43e7db39. No source/native rerun or original receipt edit.

Original T receipt remains rc1/STOP (2f0bcfff2808c547a18d2186d3d2e7de6ef607b5bb48419c5b58761d2987c085). Actual two first-execution methods passed; immutable core 5e10b26f hardcodes the original 3-group map rather than this preapproved one-group map. This separate offline classifier does not change that verdict.

Review `verify-integration-614-trace.py`, `test_integration_614_trace.py`, and frozen `integration-614-one-group-scope.json`. The scope contains only synthetic command identities, noncontent paths/hashes and source identity. Original diagnostics/xcresults/captures remain private and are being independently inspected by go-bug-runner.

The CLI pins the original manifest, receipt, method order, summary, trace projection and original diagnostic. It re-extracts ALL fixture-prefix lines from that original diagnostic, compares the retained projection, then requires exactly five ordered lines: preview(old)/Apply A/replay A/preview(saved)/Start S. A and S are frozen separately from the events under test, distinct, and also match original receipt command IDs. No additional mutation/group is accepted. It preserves the original STOP and emits a separate scoped classification with explicit limits.

Eight pure synthetic methods pass: valid group; mismatched replay; replaced disjoint Start; Start reusing Apply; missing Start/entire group; extra group/Start/unknown event; wrong order; nonzero pre-Start state. No subprocesses/native calls/signals or raw originals used in these tests. Actual retained-original classification awaits independent review of this verifier. Review is limited to this offline evidence code, not V2 or native/product acceptance.
