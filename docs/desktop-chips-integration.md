# Shared desktop chips (#442, Home adoption in #439/#440)

The view and selection type live in `Annex/Annex/Companion/Views/CompanionDesktopChips.swift`.

```swift
@State private var desktopSelection: CompanionDesktopSelection = .all

CompanionDesktopChips(hosts: store.hosts, selection: $desktopSelection)
// Project pages can instead pass the linked members; desktop IDs are deduplicated:
CompanionDesktopChips(members: entry.members, selection: $desktopSelection)
```

`CompanionDesktopSelection` is `.all` or `.host(String)`. `hostID` returns nil for All. `reconciled(with:)` returns All if a selected desktop disappeared. The component reconciles when the host IDs change or it first appears, and hides when fewer than two distinct desktops remain. Selection belongs to the owner's launch-lifetime state, with no preference or command writes. An offline desktop stays selectable so filtering can retain its offline presentation; selection never grants authority to operate it.

The chips scroll horizontally. Labels have a bounded width and wrap vertically through accessibility XXXL. The view uses the palette's tint/onTint/card/label tokens and the shared #441 optional machine-state presentation: Connected has no glyph. Accessibility labels include each desktop's state, selected traits identify the active scope, and identifiers are `desktop-chips`, `desktop-chip-all`, and `desktop-chip-host-<hostID>`.

An optional `onSelect: () -> Void` callback runs for a user tap, including a tap on the current selection. It receives no identifier. Owners can record the typed #433 `.selectDesktop` control with their actual source screen. Automatic reconciliation does not invoke it.

RootView is unchanged in this stack. Root adoption must filter Home, suppress implied host tags, retain offline placeholders, and add the connected-count subtitle required by #439. The component depends on #441's shared Domain presentation; rebase onto its landed implementation before validation/adoption.
