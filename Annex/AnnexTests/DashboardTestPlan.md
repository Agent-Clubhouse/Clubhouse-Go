# Test Plan — Dashboard simplification (#84, #85)

## Scope
- #84 Simplify Dashboard stats to a single "Agents" tile (`N (M running)`) + a projects list, and make tiles navigate to their tabs.
- #85 Replace the Dashboard top-right bolt (quick-agent) button with the Settings gear.

## Acceptance criteria

### #84
- AC1: Stats area shows a single **Agents** tile reading `48 (4 running)` (total with running count), not separate Running + Total tiles.
- AC2: Projects tile and Pending tile remain.
- AC3: Tapping the **Agents** tile switches the root tab to `.agents`.
- AC4: A **projects list** is shown on the Dashboard (rows, not just a count).
- AC5: Tapping a project (or the projects header) switches the root tab to `.projects`.
- AC6: Existing running-agents row and quick actions still work; pull-to-refresh unaffected.

### #85
- AC7: Dashboard top-right toolbar shows a **gear** (Settings) button; tapping opens `SettingsView`.
- AC8: The bolt/quick-agent toolbar button is removed.
- AC9: Spawning agents is still reachable via the "Spawn Agent" quick action.

## Unit test cases (Swift Testing)
- `agentsSummary` formats `total (running running)` correctly:
  - total=48, running=4 -> `48 (4 running)`
  - total=1, running=0 -> `1 (0 running)`
  - total=0, running=0 -> `0 (0 running)`
- `agentsAccessibilityLabel` -> `Agents: 48 (4 running)`.

## Manual validation
- Launch app against a mock/connected server.
- Verify single Agents tile text, tap -> Agents tab.
- Verify projects list renders; tap row -> Projects tab.
- Verify gear in top-right opens Settings; confirm no bolt button.
- Verify Spawn Agent quick action still opens the spawn sheet.
