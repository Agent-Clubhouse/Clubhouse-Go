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
- Run source parsing and `git diff --check` immediately. Run package tests and
  hosted app tests/build when the orchestrator grants the serial heavy-work slot.
  Record exact commands/results in the PR; do not claim unrun checks passed.
