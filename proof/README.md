# #610 exact-head synthetic proof (not yet executed)

Candidate `937e6061cc50bf9b43f44554501bc531d1b4fb81` on `ux-root/provider-apply-610`; base main `85ee757ae3de9d962d0cafab81ad0011314522ab`. Baseline overlay `ecd041582d90d05d41140688b34afe1cbf986764` on `evidence/ux-610-baseline` changes only `CompanionProviderBoundaryTests.swift` and `CompanionPreviewSmokeTests.swift`; those two files are byte-identical to candidate. Baseline product sources remain main. The source branch has no PR yet.

Execution is HOLD until independent review of the exact candidate capture delta, scripts and both frozen manifests. The prior review accepted source/UX authority at 48861e060, not native results. The new capture delta adds actual top/session and Review comparison screenshots; these still require observed local visual acceptance. This packet contains only synthetic source/configuration; original native screenshots/logs/xcresults stay private.

Scripts are self-contained, use the existing default FIFO and measured global guard (8GiB free+inactive, >=40% idle, <=64MiB swap growth per10s), jobs2, fresh worktree/DerivedData, exact source/diff/manifest/runner/auditor/build hashes, no test retries or repetitions, fresh owned simulator/QuickPath suppression, and bounded own-process cleanup/UUID deletion. The installed local runtime is iOS26.0, not hosted26.5. Package compilation uses global FIFO then package FIFO so heavy work cannot overlap. Guard refusal or an unexpected compile/fixture/outcome/count/recovery is STOP, never an automatic retry.

Order: P0 command-spy fail-before (two arguments, intended zero-dispatch assertions fail on main), baseline A fresh Debug/deinit/policy, T0 one intended missing Apply-before-selection UI failure, candidate P1 narrow package matrix, candidate A, phone8 then SE8, then fresh combined current-main coverage D. #609's exact closure/STOP and fresh direct host coordination precede any admission. Each ticket is separate; no interleaving is assumed without coordination.

Examples (no commands have been run):

```
/tmp/clubhouse-go-run.sh /tmp/clubhouse-go-run-pkg.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/baseline python3 -u /tmp/ux-610-evidence/proof/run-ticket.py P0 p0-r1
/tmp/clubhouse-go-run.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/baseline python3 -u /tmp/ux-610-evidence/proof/run-ticket.py A a0-r1
/tmp/clubhouse-go-run.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/baseline python3 -u /tmp/ux-610-evidence/proof/run-ticket.py T0 t0-r1
/tmp/clubhouse-go-run.sh /tmp/clubhouse-go-run-pkg.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/head python3 -u /tmp/ux-610-evidence/proof/run-ticket.py P1 p1-r1
/tmp/clubhouse-go-run.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/head python3 -u /tmp/ux-610-evidence/proof/run-ticket.py A a1-r1
/tmp/clubhouse-go-run.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/head python3 -u /tmp/ux-610-evidence/proof/run-ticket.py TPHONE phone-r1
/tmp/clubhouse-go-run.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/head python3 -u /tmp/ux-610-evidence/proof/run-ticket.py TSE se-r1
/tmp/clubhouse-go-run.sh /tmp/clubhouse-go-run-pkg.sh env UX610_PROOF_ROOT=/tmp/ux-610-proof/head python3 -u /tmp/ux-610-evidence/proof/run-ticket.py D d-r1
```

P1 expects all55 distinct methods/84 argument-expanded executions across five suites; each named method starts once, each parameter set starts once, all pass with no new skips. The existing Dispatcher MCP-off and unrelated settings tests remain in the matrix. Original raw logs/XML and source allow independent reconciliation. Native test details require one run per exact selector and the expected map; no pass credit can be inferred from a summary alone.

Each head UI invocation expects exactly7 synthetic previews,3 Apply transactions,1 identical-command lost-result replay,3 separate Starts. All changes report starts0; each isolated application starts once with expected Codex; start IDs are distinct from change IDs and the replay ID belongs to the original lost change. Raw app stdout and XCTest activities must additionally be reviewed for full order/cancellation. A successful automated map is not sufficient for UX or first-run/recovery acceptance. Named original frames must actually show top/session, saved Claude versus proposed Codex alongside persistent Apply/reason, reset/native-primary limitations, scoped Apply receipt before Start, and requested-but-unverified Start. Both ordinary/AX cases on SE and normal phone are reviewed; no real runtime/provider/configuration/session success is claimed.

The runner preserves an intended baseline test failure as raw nonzero test rc even when its classification succeeds; compile/crash/unexpected assertion never counts as fail-before. No install, release, real endpoint enrollment, external provider call or configuration mutation is part of this proof. Parent retains device/landing acceptance.
