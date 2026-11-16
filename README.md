# Chat header #446 evidence

Source branch: `ux-446/chat-header`. Final validation is pending on rebased head `b3b8666ce8dc811787cb9c20068402c2bbef2ac7`, based on main `0d49cb43c96ccff1714c0f22c555e4afff5e3faf`.

## Intermittent native-top attribution (#462)

The initial full hosted run on original header head `dfb73c2331162dc5f35982d77aa67d015ad22459` reported 173 passed, 1 failed, 3 opt-in skips. `CompanionHistoryReadingTests/testNativeTopOwnsTheViewportBeforeTheFirstAnimationSample` failed at line 318: `14723.0` was not equal to `0.0` +/- `1.0`, after the next streaming chunk. The full summary and test list are retained here.

The authorized bounded comparison ran only that test once per revision, with no retries:

| Revision | Result | Raw result |
|---|---|---|
| Plain base `8bc2e5d166a0db6fd43c5c92e2bab0f7d00ad963` | 1 passed / 0 failed; strict verification passed | [base xcresult](AttributionMainFIFO.xcresult.tar.gz) |
| Original header head `dfb73c2331162dc5f35982d77aa67d015ad22459` | 1 passed / 0 failed; strict verification passed | [head xcresult](AttributionHeadAfterQA.xcresult.tar.gz) |

Classified as intermittent and tracked at [#462](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/462). Related to the native-top/streaming investigation in #252; a shared underlying mechanism is unproven. No reading/scroll/restore/follow changes or retries were introduced.

Both runs used an owned iPhone 17 / iOS 26.0 simulator, Debug, `-jobs 2 -parallel-testing-enabled NO`, signing disabled, and the shared FIFO runner. No physical device or live desktop was used. Empty result stubs from the earlier argument rejection are preserved locally and are not passing evidence.

This branch contains evidence only and must not be merged.
