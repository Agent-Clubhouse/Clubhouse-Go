# Project page (#442)

The page has one New agent / Terminal row, a shared desktop-chip scope for linked members, Needs you followed by Agents, and a single sleeping/retained-finished disclosure. Whole helper subtrees stay together when a helper needs attention, preserving their parent disclosure and collapsed preference. Historical exited agents are omitted from active rows and appear once as retained runs; Dismiss/Clear use the existing desktop commands. Offline members retain a placeholder without presenting their cached agent tree as live.

The toolbar menu offers Wake with a message and the functional read-only Project info sheet from #443. Single projects also retain the existing Pin / Inactive policy: desktop shared project state when available, existing local preferences otherwise, pinned projects kept active. Changes is removed from the page, including its automatic read. Domain changes/diff decoding and service tests remain; the obsolete project-page UI path through Changes is intentionally removed from the smoke scenario.

For linked projects, All → Terminal / Wake opens an explicit machine chooser; a selected member acts directly unless multiple project copies share that machine, in which case the chooser disambiguates them. No operation fans out. Availability is checked both in the chooser and again after dismissal, and Wake opens chat only after its sheet finishes dismissing. New agent continues through the existing linked-project spawn chooser.

Linked Pin and Mark inactive are deliberately left at their existing Home behavior with no new per-machine menu structure or Go-local fan-out. The user's desired all-copy semantics require a desktop-backed shared-state/sync contract first; Go adoption is a separate follow-up after that contract lands.

## Integration pending

- Root owns the Home changes: remove its header overflow, use the shared menu from a project-header long press, and wire chips/filtering under #439/#440. `CompanionProjectMenuItems` supplies Wake and Info and the single-project state items; Root owns presentation and concrete machine routing.
- Root adopts `CompanionDesktopChips` and the extended `CompanionAgentTreeQuietFold` signatures documented beside this file.
- Rebase onto the landed #441 machine presentation, #432 contrast helpers and #433 typed telemetry before validation. The prepared stack currently references #441's optional presentation API.
- #442 stays open while the Root criteria and desktop linked-state adoption remain outstanding; use Refs #442.

No RootView, Navigation, HomeLayout, SpawnSheet or production conversation/chat files are changed. Visual validation is simulator-only, with no physical device or live desktop.
