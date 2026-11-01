# Agent settings contract — 2026-11-01

Test cases written before implementation, against desktop contract `mobile-control-v1.md` and fixtures at `4caf8ebbb61963fa105a90c8999cd7b276a9038d`.

- Decode orchestration `mcpEnabled` true and false; missing, null and wrong types default to true. Decode `settings.orchestrator.changeStartsNewSession` true and false; absent and wrong types default to false.
- Decode `agent-settings-mcp-off.json`, keeping saved sources while effective switches are false. Decode new update receipts, including CLI changes with `sessionReset:true`, and MCP refusals.
- MCP off: keep Orchestrate, Cross-project helpers and (when Dispatcher is on) Connect to Dispatcher visible, disabled, with Clubhouse MCP explanation. MCP on: Dispatcher connection is offered with Orchestrate on or off; Dispatcher off hides it. Helper identity is not exposed yet (desktop #2618); a returned false must win over a sent true.
- Encode each changed orchestration field by itself; no untouched field is sent. In particular a policy may read `connectToDispatcher:true` with Dispatcher off: changing access, control, helper limit, orchestration or cross-project helpers must never echo that value. Explicit connection changes still encode.
- Runs on: a different CLI with a saved session asks using the desktop sentence. Cancel sends no update and retains the old picker selection. Confirm sends only the CLI change; same CLI or no saved session needs no confirmation. Preview refusal after confirmation proves the request was attempted.
- A post-change snapshot with `hasSession:false` removes Wake & Resume from the sleeping agent's choices. If the existing snapshot path handles this, add a regression test without new production state code.
- Both create and update `mcp_off` display the desktop sentence; missing/empty/code-only messages get a readable Clubhouse MCP fallback. New agent already renders the shared create error.

Validation: focused package tests, full `swift test --enable-code-coverage`, `scripts/coverage.sh --skip-tests --check`, vendored Framebriar tests, simulator build-for-testing and xcodebuild test on a privately created simulator. Follow `docs/testing.md`; no separate lint command is specified. UI smoke cases cover settings switches and CLI cancel/confirm when practical.
