# Test Plan — Entry-point consistency (#87, #92)

Theme: a canvas/project should look & behave the same regardless of which entry point you navigated from.

## #87 — Canvas selector when multiple canvases exist

### Acceptance criteria
- AC1: 0 canvases → empty state (unchanged).
- AC2: exactly 1 canvas → render the canvas directly (no selector, "go straight in").
- AC3: more than 1 canvas → present a **selector list** first; tapping an entry navigates into that canvas. (Previously it dropped you straight into the first canvas with a menu picker.)
- AC4: the selector path is reached regardless of how many projects/instances the canvases span (cross-project/instance entries all listed).

### Unit tests
- `CanvasPresentation.mode(canvasCount:)`:
  - 0 → `.empty`
  - 1 → `.single`
  - 2, 5 → `.selector`

## #92 — Consistent orchestrator display in project detail

### Acceptance criteria
- AC5: Opening a project from the Clubhouse tab and from the Projects tab shows the **same** orchestrator badge (same view, same resolved name).
- AC6: Orchestrator display name resolves from the project's **own instance** first, then the merged cross-instance map, then the raw id as a last resort — so the same project shows the same name independent of entry point and cross-instance id collisions.
- AC7: When `project.orchestrator == nil`, no orchestrator badge is shown (both entry points).

### Unit tests
- `AppStore.orchestratorDisplayName(_:instanceId:)`:
  - instance-scoped shortName wins when present
  - falls back to merged-map shortName when instance lacks it
  - falls back to the raw id when neither resolves
- Both nav payloads (`AnnexNav.project` / `ProjectNavItem`) carry the same `Project` + `ServerInstanceID`, so `ProjectExplorerView` inputs (incl. resolved orchestrator name) match.

## Validation
- `xcodebuild test -scheme ClubhouseGo -project Annex.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17'`
- Known-unrelated/env failures to ignore: `IntegrationTests.testMockServerDelivers{Agent,Snapshot}`, `testMockServerServesStatus` (mock-server loopback; byte-identical to origin/main).

## Manual validation
- Connect ≥2 canvases (e.g. app-level + a project canvas) → Canvas tab shows a selector; pick one → opens it. With one canvas → opens directly.
- Open the same project from Clubhouse tab and Projects tab → identical header incl. orchestrator badge.
