# #567 / Draft #568: parked characterization

Base main `ffcf13e8`; final source head `10da2bec`. No restoration code merged. Home still starts at the top when returning from another tab, as shipped in #551.

The final permitted identity-only round is complete. The original 29-line 8pt fractional anchor test stayed byte-identical (SHA256 `15183912a37241c4340c60f458aaaeae53991010b37aa3c483a21c8dc653db42`). No assertion retries or tolerance changes.

|Mechanism|Saved/expected y|Actual y|Finding|
|---|---:|---:|---|
|Fractional identity, tab return|160|411.667|Exact row centre|
|Fractional identity, push/pop|160|453.333|Exact row centre with changed bottom inset|
|One adjusted negative fractional identity|160|unchanged centre|Non-standard UnitPoint ignored by native List|
|Point ScrollPosition, previous diagnostic|160|unchanged centre|State written twice, native offset did not move|
|Standard `.top`, same saved agent 8|116|131|+15pt|
|Standard `.bottom`, same saved agent 8|707.333|692.333|-15pt|

The symmetric 15pt gap likely belongs to native List row/section insets; this is an inference, not a calibrated solution. `.top` missed the pre-decided approximately 1pt criterion, so row-top restoration was not implemented and the work is parked. Options require a new decision: explicitly calibrated row-top restoration, or migrating Home to a ScrollView. Neither option has performance/accessibility/regression proof.

Both main and head recorded zero owner/content-input/content/layout/header evaluations on all 16 programmatic scroll steps. Row/menu increments were lazy realization. Native finger-gesture behavior remains unproven. Step fixture first required a native large-title warmup; the first failed raw-offset assertion and receipt were preserved, then QA reviewed the identical corrected overlay on both trees. Every measured raw-offset 1pt check plus exact top-inset invariant remained.

Fresh final head Debug build passed (216s), compiled deinit and policy gates passed. Diagnostic r3: main step 1 PASS; head step and standard-anchor probe 2 PASS, original fractional anchor 1 FAIL (two alignment assertions). These temporary instrumented runs are uncredited. Broad/live-stream suites were not run on this restoration head because the anchor gate failed.

Final lifecycle: own simulator `695314C8-C88A-4C63-BC9B-5A761943E342` shut down, system-wide 0 Booted, all owned ticket/xcodebuild processes exited, swap growth 0. Results and full local xcresults remain under `/tmp/ux-567-proof/tickets/anchor-diagnostic-r3`. The host was returned to go-composer-control for #573. Evidence contains generated identities only.
