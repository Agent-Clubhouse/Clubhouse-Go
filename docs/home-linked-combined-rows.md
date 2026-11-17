# Combined linked projects on Home (#536)

The approved Option 1 renders one active tree per linked project, followed by one quiet disclosure. `CompanionHomeLayout` remains the source of live agents, ordering, helper ancestry and scroll-held order. `CompanionHomeLinkedProjectRows` renders that tree without rebuilding the catalog or flattening helpers into separate roots.

Rows reuse Needs you's `CompanionAgentRowContext` and `CompanionHostTag`: full machine names appear in visible metadata and the combined accessibility label. The selected desktop supplies the implied origin, so its rows omit redundant machine-only badges. When a link contains multiple projects on the same machine, the Home-only context overrides that suppression with `entry.label(for:)` (for example, “Studio Mac · Docs”) for active and quiet rows in both All and single-machine scopes. Other screens keep the existing empty-default context. No font cap or horizontal agent carousel is introduced.

`CompanionHomeLinkedRows` combines retained finished records from operable scoped members, deduplicates full host/project/agent targets, and sorts completion times newest first with stable ties. One existing `CompanionAgentTreeQuietFold` supplies sleeping rows, retained history, Dismiss and Clear. Its disclosure key uses the linked identity (`quiet:link:<linkID>`), so every member shares one expansion state. It starts collapsed with fresh preferences. Unlinked/single-desktop scopes retain their existing fold keys.

Clear invokes the existing per-project Store operation for each displayed project's retained records, preserving its desktop capability/connection guard and the first reported error. Dismiss still targets one full agent identity. Offline machines keep their separate session-only disclosures and dimmed, non-actionable cached rows; they do not contribute live agents or finished records to the combined fold. Shared Pin/Inactive authority and the machine-targeted Wake/Terminal/New agent chooser are unchanged.

## Regression coverage

- Domain `CompanionHomeLinkedRowsTests`: cross-machine ordering and repeated IDs, helper ancestry, selected/held order, a quiet-only member, stable retained-run ties, offline/live counts, selected scopes, and targeted Dismiss/Clear.
- Hosted `CompanionHomeLinkedRowsTests`: mounted production linked rows and badges, the expanded quiet-only machine and retained origins, and the actual linked All/AX5 path with a full long machine name. It does not claim to mount Home's separate single-copy `projectRows` path; UI tests cover that scope.
- UI `CompanionCombinedLinkedHomeUITests`: light/dark/XXXL, collapsed/expanded quiet rows, full origin labels, helpers, scope, cached offline disclosure, and actual Dismiss/Clear. XXXL checks full-row viewport containment and screenshot OCR of the entire multiline badge, with rendered-text bounds inside the row. The existing same-machine preview fixture covers All and the Studio scope, including project attribution after expanding quiet rows.
- Existing `CompanionLinkedProjectUITests.testHomeAndProjectPageMergeMachinesAndUnlinkSplitsThem` and `testDisconnectedMemberKeepsItsPlaceWithoutShowingCachedAgents` replace obsolete live machine-subheader lookups with full origin assertions on actual agent rows. All navigation, unlink, disconnected-content and scope assertions remain.

Validation results and simulator screenshots are recorded in the PR. No physical-device validation or installation is part of this change.
