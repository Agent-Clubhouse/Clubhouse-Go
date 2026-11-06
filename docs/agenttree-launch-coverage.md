# Agent-tree initial launch and behavior coverage

This narrow test change makes each AgentTree test's initial launch a single unsuppressed attempt and records case-specific progress. It does not diagnose or repair the simulator/runner launch failure itself.

## Evidence and ownership

PR325 at cd9d60e85929e4cc2857566bd71678ae4f12f752, ordinary CI42194725657 attempt1, agents/keyboard job127848469493, retained two nominal passes with no tree assertions: NestedRows iteration1 (62.638s) and Project iteration2 (61.574s). Both logs show an accepted expected launch failure followed directly by teardown. Project iteration1 separately failed after245.410s while obtaining launch progress. A later keyboard runner restart and subsequent sibling successes do not prove the earlier tree scenarios or establish a content-related cause.

Keep the chronology and original log (SHA256 a0d745da32220a1955f5b8030031501517fdabbd34c6e5019e685da1c6fce161) separate from issue308's older late-navigation/time-budget failures. This is follow-up under the existing launch investigation, not a duplicate issue or closure of308. Hardware Return310, wake-focus313 and partial rich-content325 remain separate.

## Exact control-flow change

Both initial calls use `launchApp(arguments, attempts: 1)`. At the reviewed UITestSupport source blob3adf4e48ded93ddca60554bbfa5b3b8ebaabef3d, the only `XCTExpectFailure` call is inside `for attempt in 1..<max(attempts, 1)`. Passing1 makes that range empty. The final `app.launch()` and existing foreground assertion execute outside the expected-failure closure with `continueAfterFailure = false`. Initial launch errors are therefore not classified as expected by this helper. The unused options object still exists; constructing it does not enter an expected-failure scope.

No shared helper, matcher, verifier, timeout, environment, orientation, product, content, focus or CI configuration changes. The existing240-second source allowance and30-second margin remain. The existing helper deadline only guards its own call sites; it is not a process hard-kill guarantee.

## Passive evidence contract

Each case records its exact `#function` and elapsed `ProcessInfo.systemUptime` at initial launch start/return, after its first existing tree assertions, and after its final existing behavior assertion. NestedRows additionally records the intentional preference-persistence relaunch start/return and completed persisted-tree assertions. The original terminate/arguments/direct-launch sequence remains unchanged; this relaunch is a required behavior phase, not a launch retry.

Milestones are synchronous empty XCTest activities with monotonic timestamp reads. They add no AX queries, scheduling operations, waits, gestures, screenshots, polling, tasks or recovery behavior. The original assertion and action ordering is preserved. A launch-return milestone is not readiness or completion. The final marker follows the last original assertion; acceptance also requires the actual assertion/result records, not the marker alone. Missing final completion remains an explicit coverage gap even if a framework summary says Passed. No English-log parser or CI-verifier enforcement is introduced.

## Validation status and proposed scope

This document accompanies a source candidate; no runtime result is claimed. After independent exact-diff review, nominate only:

- `ClubhouseGoUITests/CompanionAgentTreeUITests/testNestedRowsCollapseRollupRelaunchAndNeedsYouNavigation`
- `ClubhouseGoUITests/CompanionAgentTreeUITests/testProjectUsesSameTreeAndCrossProjectCaption`

One fresh Debug compile/existing binary gate followed by those two methods on an owned simulator, serial/default once and explicit runtime YES/default240/max240, requires separate allocation. Preserve all original assertions, waits, navigation bounds and images. Expected complete path: two initial launches total plus the one intentional NestedRows relaunch. Existing navigation helper behavior is unchanged and must be reported honestly; single initial launch is not a claim every gesture or low-level event is single-attempt.

Stop on build/gate failure; no corrective repeat, timeout increase, expected-failure broadening or tree/CI acceptance inferred from a launch-only result. Retain actual per-method iterations, phase durations, assertions, original captures, launch/runner failures, timeout receipts and owned cleanup. A local pass would not resolve the historical hosted failure or replace ordinary CI. Keep consolidated326 at its frozen head while this separate source proposal is reviewed.
