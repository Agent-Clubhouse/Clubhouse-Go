# Dispatcher recovery hosted route

At PR622 head `f576fca31028f556f18acb7204bcd6d8d4a3e63e`, both zero-argument methods in `CompanionDispatcherRecoveryUITests` were assigned once to the catch-all UI job. In first run44686861649, job136137222820 reached its55-minute maximum before either recovery method started. Its closed original1011591-byte direct job log has SHA256 `83432c1eb0d4f088da1a595f3f9cab71b8b400799839fee25df0b1ba906698bc`; the check annotation explicitly identifies the job limit. This is missing hosted execution, not a recovery UI test failure or a human cancellation finding.

The complete class now belongs to the EXISTING unicode/home lane. The generated catch-all selection excludes the whole class automatically, preserving future methods and once-only source inventory coverage. All eight jobs, hosted unit placement, application/native-test bytes, test assertions, retry reporting, workflow gates and timeouts remain unchanged. No new runner, concurrency allowance, workflow or local simulator run is added.

## Budget evidence

In the same original run, unicode/home job136137222801 succeeded from08:25:34Z to09:04:30Z:38m56s,16m04s below the unchanged55-minute limit. Its complete459809-byte direct job log has SHA256 `14666a4c12f19c7255b6e8ad6a5dae8cf96ec93d0dc49d87b4fcc394ae01156a`. Composer/sheets took44m23s and preview/project50m08s; unicode/home had the largest measured headroom of those successful UI lanes. These are observations from one run, not future elapsed-time guarantees.

The two recovery methods retain `launchApp`'s existing240-second per-method source allowance. Two first-attempt allowance slots total8 minutes, less than that observed16m04s headroom. The existing three-iteration retry policy could consume more and exceed the job budget; this change neither promises otherwise nor raises any limit. Queue contention, framework overhead and later test changes require actual measurement. The workflow's120-second default remains unchanged; source `executionTimeAllowance` continues to apply its existing method-specific setting.

## Validation and remaining gates

The routing regression failed against the old matrix because recovery was absent from the home lane. With this isolated change, all36 Python CI unit tests pass, including full source UI class partition, future catch-all, missing/duplicate/unknown selectors, one hosted unit lane and mocked boot-client bounds. The regression also retains exactly eight UI jobs. Product, native UI-test, workflow and verifier files are byte-identical to the parent; no local native/simulator execution was performed.

The next proof is the exact reviewed successor's normal hosted first outcomes for `testInterruptAndNewChatHaveSeparateConfirmedEffects` and `testStopChatIsConfirmedAndRequiresDesktopStateEvidence`, plus actual lane elapsed time and retained original artifacts. Source/CI tests are not hosted native acceptance. Preserve the original zero-start disposition, earlier local failures, unsupported controller history/genuine restart/desktop atomicity limits, and the separate package failure. Shared PR refs remain untouched until writer STOP and peer review are established. This routing proof can proceed independently of unlanded620; it does not make aggregate CI green or authorize bypassing another required check.
