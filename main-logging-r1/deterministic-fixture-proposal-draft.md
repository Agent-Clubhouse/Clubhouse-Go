# Conditional proposal — deterministic H1 fixture (not implemented)

Use only if the single logging prefix passes without H1/H2 evidence. This is a proposal for independent QA, not a finding or permission to change product logic.

The existing DEBUG CompanionReadingRestoreProbe.deliver runs after CompanionReadingRestoration has pinned a numeric offset but before ScrollPosition delivery. Existing hosted tests already return false on attempt1 and apply a Store text event there. Extend a dedicated fixture using that same public test seam:

1. Seed more than one window of fixed, uniquely identified entries; choose a bookmark comfortably inside the window, not at its retention edge. Record the actual entry frame, visible marker y and immutable saved entryID/distance before unmounting. Keep normal native scrolling and first mount.
2. On first restore delivery, record the pinned numeric target and the entry lowerBound; refuse that delivery once. Apply a normal session-bearing Store event that appends a distinct tail entry. Do not move the bookmark, change shownEntries, fabricate metrics, or write a UI offset.
3. Observe actual window/frame publication. Require hiddenCount and first id to change, entryID retained, entry lowerBound displaced by more than6pt, and frameContentHeight matching content metrics. If those preconditions are not met within a bounded wait, FAIL as fixture-not-exercised; no timing pass or substitute assertion.
4. Allow subsequent existing deliveries after those real geometry preconditions. The current implementation should use the stale absolute pin. Wait for product completion/public frame stability independently of expected y, then require the same visible marker within6pt of its saved alignment. Preserve all navigation/Latest/keyboard controls and original historical method.
5. Control with equal tail growth that leaves entry.lowerBound unchanged: numeric target remains pinned. Add cancellation and timeout controls; no new attempt/time budget and no broad followLatest changes.

No new product hook is evidently needed: the existing delivery closure can read bookmark.viewport frames/metrics and suppress delivery until the precondition. If final observations show the native view already arrives before the seam can hold it, propose a different narrowly scoped DEBUG seam to QA rather than faking the geometry.

A separate model-level case can exercise the real CompanionTimelineWindow alongside capture/restoredOffset and CompanionReadingRestoration at explicit frames: old window -> pin -> append/tail trim -> changed saved-entry lowerBound. That establishes whether a fixed absolute pin violates the semantic entry bookmark, but cannot substitute for native UI6pt proof.

If logging implicates H2, do not run this H1 fixture as a claimed reproduction. Instead propose a teardown-specific fixture with the observed saved caller and actual late callback order.
