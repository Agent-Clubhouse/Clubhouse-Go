# Retained finished runs in the shared quiet fold (#442)

The #434 initializer stays valid. These additive, defaulted parameters extend it:

```swift
CompanionAgentTreeQuietFold(
    projectID: projectKey,
    tree: tree,
    preferences: preferences,
    parentLines: parentLines,
    finishedRuns: store.finished(in: project),
    onDismissFinished: { run in Task { await store.dismissFinished(run.target) } },
    onClearFinished: { Task { await store.clearFinished(in: project) } },
    canOpenFinished: { store.agent(for: $0) != nil }
)
```

`finishedRuns` is optional. **Omitting it (nil) preserves #434's catalog-only behavior. Passing a list, including an empty list, supplies the authoritative retained list.** Explicitly exited catalog runs that have been dismissed are not resurrected from their old catalog status. Matching retained/catalog rows are rendered once, and retained records remain visible when the catalog no longer contains their target. Repeated retained targets are deduplicated in the caller's existing order.

`onDismissFinished` supplies swipe, context-menu and accessibility Dismiss actions; nil offers no mutation action. `onClearFinished` supplies Clear finished runs inside the disclosure when retained records exist. These callbacks preserve each caller's existing store/desktop behavior. `canOpenFinished` preserves navigation for targets the caller still knows; without it, only targets in the supplied tree open a chat. Forgotten records remain readable without a dead navigation link.

The disclosure uses the same `quiet:<projectID>` preference key and `fold-quiet-<projectID>` accessibility identifier as #434. Retained row IDs now include host, project and agent (`finished-<host>-<project>-<agent>`) so linked copies cannot collide. Host tags use #434's row context.

Project page adopts the extended API here. Home's adoption remains a Root lane follow-up after #442 lands; do not build a second retained-run fold. A caller constructing separate active/attention sections must treat explicitly exited retained quick runs as historical, rather than rendering another live row for them outside the quiet disclosure.
