Independent runtime audit request: #584 / Refs #582

Goal: independently review the final C50, cold R0, SE RSE and then current-main D coverage evidence on exact fab40073358820b4fcd75d73819ccb04fb096111. qa-ui-batch already accepted the exact-head static implementation, A/F/N/H/S/Q/CPU108/C23 before its weekly limit. You did not author this product/test patch or its native runs. This is a bounded read-only peer QA task over our existing link, not a new agent or a replacement claim for any unreviewed code.

Authority/boundaries: choose your audit ordering and evidence checks; report PASS or actionable findings with paths. No source changes, builds, test executions, simulator/phone actions, acceptance-bar changes, retries, merges or heavy admissions. If your filesystem/access scope cannot read these artifacts, decline with that exact boundary; evidence is also on evidence/ux-582. Unexpected count/order/outcome, stale artifacts/head, unmet cleanup or changed main is a finding, never an allowance. Formal product/device acceptance remains deferred; parent owns landing.

Concrete native evidence under /tmp/ux-582-proof:
- manifest.json (SHA256 63b70b0cd8ec2f8f87885403b5975214ba6cbc9f2a91b3c6f7db6ea115929641), run-ticket.py and audit-native.py, reviewed exact config.
- a-r9-receipt.json / success-A.json: exact fab clean source, cumulative diff18c0150d65dea84d0221a035761b8872ade14f003b0d6b46ca4ebd2783413ff0, build-time app/test fingerprints, build/deinit/policy pass.
- c50-r1-receipt.json plus tickets/c50-r1/{summary.json,tests.json,tests.xcresult.single-run-details.json,actual-order.json,audit.log,reading-activities.json,test.log,attachments,diagnostics}. Expected50 once/order; observed47P/1strictE/2Skip. FitInvariant is deliberate strictE; ForcedTray is a legitimate measured hysteresis skip requiring its annotation; pointerwheel is iPad-only skip. Original Reading6pt history return passed53.686s after the full prefix. OwnC673E14F deleted, processes[],0Booted/swap0. Published full packet evidence/ux-582 c162fbb32 runtime/c50-r1.
- r0-r1-receipt.json and tickets/r0-r1 same native files: expected1 original Reading restoration cold once, observed1P/noE/noSkip. Own710BC94A deleted, processes[],0Booted/swap0.
- rse-r1-receipt.json and tickets/rse-r1 same native files: expected15 original Reading methods once; observed14P/1iPad-onlySkip, noE/F. Own5E8DC73E deleted, processes[],0Booted/swap0. Check the original6pt and rotation/following controls, source+build fingerprints and no per-test repetitions.

Check the raw details/activities and artifact/source identities, not just these summaries. All source/test contract hashes remain the accepted ones; CompanionReadingUITests byte-identical to main85ee SHA2566c5749d41ba1670ac001c65428016333d7c0818af7f9ea44d3579f980c7784b5. Prior QA C23/CPU accepted notes are in evidence/ux-5821e8c7f965.

D is currently compiling under pkg FIFO/jobs2/global guard/hard1200. I will send its completed concrete packet separately. Expected: fetch/recheck current main, clean unmodified merge tree, no overlap, fresh scripts/coverage.sh --check; verify new10 opening value methods plus capture-epsilon cases actually pass, ratchet and all package process closure. Preflight main remains85ee (same tested base). Do not accept D until the completed raw packet arrives.

Retained disclosures: user-approved bookmark-first opening (canonical row first below Show earlier); reviewed semantic entry-relative fixture changes; XXXL first encoded frame shows only the first 'Reading...' line,90 readable after restore; FL landscape recorded only/#483 excluded; device check deferred. No weaker6pt/count bar. PR stays draft pending final independent evidence acceptance.

Please reply via existing ux-root link with task final-584-runtime-review, taking bounded audit decisions within those constraints.
