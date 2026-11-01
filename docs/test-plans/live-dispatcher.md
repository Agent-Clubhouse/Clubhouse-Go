# Dispatcher live E2E plan

Run against desktop main with the isolated profile and private simulator from `scripts/e2e-live.sh`.
All providers use the scripted fake or nonexistent CLI paths; no paid prompts.

1. Seed experimental `dispatcher` and `newChrome`, leaving Dispatcher disabled for earlier tests.
2. Enable/disable from phone Settings; verify the pinned row appears above projects and disappears.
3. Open chat, wake, send a scripted turn, observe its stream; sleep on desktop, reconnect phone, wake and resume.
4. Verify Dispatcher settings expose CLI, model, runtime, Free Agent Mode and auto-sleep while hiding locked identity/persona/orchestration. Save supported settings and confirm desktop state.
5. Toggle Echo's Orchestrate and Connect switches while Dispatcher is on. Verify desktop policy and wire changes.
6. Change Dispatcher on desktop with phone connected and backgrounded; verify phone snapshot catch-up and real wire event/replay ordering.
7. Drive the authenticated real MCP bridge using only the fake child's credentials: wake/sleep Echo and deliver a message; verify sender caption and text on phone. Record structured `routed` if present without claiming renderer coverage before its separate PR lands.
8. Use fixture's paired mTLS observer for raw refusal checks: `dispatcher_flag_off`, `dispatcher_off`, and locked Dispatcher updates. Classic layout is fixed at startup; do not pretend a later flag write tests `dispatcher_layout_off`.

Pending separate phone PR: MCP-off disabled switches and explanation, and structured `routed` rendering. Add when orchestrator confirms main includes them.

Validate with a focused `--only` run, `swift test`, Xcode build, then full live suite and `verify-xcresult.py`. Confirm desktop bugs against logs/code, search duplicates, file with batch label, and retain issue-linked checks.
