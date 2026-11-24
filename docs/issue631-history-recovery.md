# History refresh ownership after recovery (#631)

## Supported defect

On main `9600bf51b01feb63c54f18e8b849d1d27b01f18d`, `CompanionStore.load` owns `isLoading` until its history request returns. A resync marked the conversation stale without retiring that request; unavailable-host reports also left it loading. The conversation view admits a reconnect refresh only when connected, stale and not loading. A pending read from the old connection could therefore keep an empty or cached conversation in Refreshing and block the replacement read. An old success could also clear the stale flag before replacement admission.

A normally thrown history error already stops loading and exposes Refresh conversation. The defect here is ownership across recovery, not the absence of that error handler. The mixed timeout window in device report4bee43f3/build77b24899 does not identify the request that caused its empty transcript. This source-supported reproduction does not establish that report's single cause.

## Change

When a desktop requires resync or is reported unavailable, retire only its active history loads: invalidate their generation, clear loading, and require resync. Cached items, draft, loaded metadata and existing error details are preserved. The existing connection notice or Refresh conversation action can then be shown, and the view's existing reconnect predicates admit a fresh read. Both success and error from the retired request fail the existing generation guard. A replacement generation continues to own its spinner and result.

The old HTTP operation remains subject to its existing transport limits; this change retires its Store ownership. No transport deadline, retry policy, snapshot format, command gate, header or view was changed. Suspension is covered by the same resync event emitted by `CompanionLiveService.suspend`, followed by its offline host report. A successful empty snapshot still completes normally rather than being treated as an error.

## Focused proof

Tests-only commit `0dfc071ce96cbd2af1257a8784e1c8dd38eaf391` retains the entire main product source. Its new real-Store regression has four cache/error argument cases and24 controlled interleavings: resync versus reconnecting host report; empty versus cached conversation; old success versus timeout; old completion before reconnect, during replacement, or after replacement. Another desktop's history remains pending throughout and completes independently. The test explicitly holds the replacement read to verify that an older completion cannot clear its loading state or replace cached items. Existing normal thrown-error behavior and successful empty-history completion are separate controls.

The identical focused test source fails against the unchanged product (168 issues, three selected tests, .018s test execution), including loading staying true, fresh-read admission false and missing replacement history calls. The normal error and empty-success controls pass. With the12-line Store change, all three selected tests pass in .009s. Related Store, StoreFailure, RecoveryStatus, AttentionAvailability and LiveService selection passes113 tests/six suites in .074s. These are local macOS SwiftTesting results (library1085, Apple Swift6.2), run through the package-only FIFO with `--jobs 2`, not a device/UI/hosted reproduction or performance claim. Full text logs remain private; independent review and integration proof remain separate.

Commands:

```
swift test --jobs 2 --filter 'CompanionStoreTests/(interruptedHistoryAllowsReconnectRefreshAndRejectsLateCompletion|failedRefreshKeepsCommandsBlockedUntilReconciled|emptyHistoryCompletesWithoutLeavingARefreshSpinner)'
swift test --jobs 2 --filter 'Companion(StoreTests|StoreFailureTests|RecoveryStatusTests|AttentionAvailabilityTests|LiveServiceTests)'
```

Original baseline focused log:79288 bytes, SHA-256 `ba956ab03ef600e716b3f3877e6c9282bd37918359bec3b9cd29a521659757bb`.
Corrected focused log:45585 bytes, SHA-256 `a031643c417c99a559d72d5c6df4b66aa3efbde97e47b439a71d584907035620`.
Related suites log:24511 bytes, SHA-256 `2750d7aedb6723fc11be2388624258950c08e3f39163439e9d40cdc0d7a0726c`.

The unit test exercises the existing reconnect admission predicates and actual Store reads; it does not execute SwiftUI observation, URLSession, a physical desktop reconnect or the reported device session. The parent owns independent review, PR integration and landing. No screenshots or duplicated CI runs are part of this candidate.
