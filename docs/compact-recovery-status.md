# Compact recovery status

Standalone presentation work for feedback report `5439b422-1cea-4716-81e9-c7c23c219537`,
captured 2026-11-06 05:25:48Z on phone build 218 (`b17f9f80`). The original PNG
was inspected locally from git blob `04e5bb0e8f9716417f36495797fefc1ddd4822f8`.
It shows a large refresh panel; it cannot establish the underlying connection enum.

## Source contract and priority

`CompanionLiveService.receive` distinguishes connecting, reconnecting, and
synchronizing (catalog catch-up), and maps transport retrying to failed. Failed
alone therefore does not prove an active reconnect. `CompanionStore.load` sets
`isLoading` and clears `error` at the start, clears resync on success, and sets
`error` plus `requiresResync` on failure. Resync also remains set during recovery.

The presentation must classify these inputs in this order:

| Connection | Conversation flags | Presentation | User action |
| --- | --- | --- | --- |
| connecting | any | Connecting… | Details |
| reconnecting | any | Reconnecting… | Details |
| synchronizing | any | Synchronizing… | Details |
| offline | any | Offline | Retry connection, Details |
| failed | any | Connection issue | Retry connection, Details |
| connected | loading | Refreshing conversation… | Details |
| connected | not loading, error | Conversation refresh failed | Refresh, Details |
| connected | not loading, resync | Conversation needs a refresh | Refresh, Details |
| connected | no loading/error/resync | Hidden | None |

Host and conversation error details must survive overlap with progress. Progress
must never be inferred from resync or an error. No presentation state changes
command blocking, retries, lifecycle scheduling, provider actions, or permissions.
Stop/settings uncertain-result warnings remain the caller's separate concern.

## Integration boundary

The component is intentionally unwired here. The parent/header owner owns
`CompanionConversationView` integration after source review. Composer, RootView,
Store, lifecycle, and transport are outside this change's scope.

Construct `CompanionRecoveryStatus(connection:isLoading:requiresResync:error:)`
from the current host connection and conversation flags. Pass it to
`CompanionRecoveryStatusView(status:onRetry:)`; a clean connected value takes no
layout space. The view has no Store dependency and never creates a Task.

`onRetry` receives `.reconnect` or `.refreshConversation` only after a button
press. The caller can use its existing `store.reconnect(hostID:)` and
`store.load(target, force: true)` paths respectively. The caller must continue to
derive command availability from Store; presentation is not authorization.

Automatic recovery uses a compact progress row with a 44pt details button.
Unavailable/stale states add a 44pt Retry or Refresh button. Narrow layouts and
large Dynamic Type stack the label above the controls, with no text truncation
or font cap. Details open a scrollable sheet retaining complete error text;
an issue glyph/accessible issue label signals errors even during progress.
Accessibility identifiers are on leaf controls only; the containing element has
no identifier because #311 found container identifiers masking child selectors.

The header owner should review overlap with the existing first-load transcript
spinner and timeline error text during integration. This component intentionally
does not change either caller surface or suppress any existing warning.

## Test plan

- Exercise every connection enum case crossed with loading, resync, and errors.
  Check active progress survives resync/error overlap, while offline and failed
  never claim reconnecting or refreshing even if a history request is in flight.
- Distinguish connected history loading from connected load failure and stale
  history requiring explicit refresh; clean connected status disappears.
- Preserve full connection and conversation errors without truncation; provide
  useful fallback details for empty error messages.
- Host only synthetic status views: compact standard-size progress row,
  actionable unavailable states, hidden clean state, large Dynamic Type at narrow
  widths, and complete detailed explanations. No desktop/provider/network fixture.
- The five hosted tests only measure `sizeThatFits` and check model strings. They
  do not establish sheet/action reachability, leaf selector behavior, or hit target
  geometry. The integrated synthetic UI must tap Details, read full errors,
  dismiss the sheet, and route Retry/Refresh correctly, including large text.
- Run source parsing and `git diff --check` immediately. Run package tests and
  hosted app tests/build when the orchestrator grants the serial heavy-work slot.
  Record exact commands/results in the PR; do not claim unrun checks passed.

Focused issue: [#322](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/322).
Related issues reviewed: #125 (composer spinner), #150 (host wording), and #205
(first snapshot stall). These do not own the standalone recovery presentation.

## Validation commands

```sh
swift test --jobs 4 --filter CompanionRecoveryStatusTests
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<allocated simulator>' \
  -derivedDataPath '<worktree>/.codex/reconnect-status-evidence/DerivedData' \
  -jobs 4 -parallel-testing-enabled NO -test-iterations 1 \
  CODE_SIGNING_ALLOWED=NO -only-testing:ClubhouseGoTests/CompanionRecoveryStatusViewTests test
git diff --check
```

The package target automatically includes the new Domain file. The app and hosted
tests use Xcode synchronized groups, so no project-file changes are needed.
There is no dedicated repository lint command; source parsing and whitespace
validation accompany the compiler/test checks.
The bounded allocation is filtered Domain tests and exactly five hosted tests,
once without retries; it does not authorize a full-suite follow-on.
