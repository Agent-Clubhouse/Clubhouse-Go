# Additional provider validation

The opt-in `CompanionAdditionalProviderTests` run against the integration owner's isolated, loopback-only Annex profile. They require existing provider authentication and a verified memory-only invitation supplied outside the test bundle. No credentials or PINs are committed. Production repositories and existing agents are excluded.

Run one method per fresh fixture launch. Set `TEST_RUNNER_CLUBHOUSE_RUN_ADDITIONAL_PROVIDER_SMOKE=1`. For wake tests, also set `TEST_RUNNER_CLUBHOUSE_PROVIDER_STARTS_ASLEEP=1` and start the owned fixture asleep. For Copilot active-generation control, set `TEST_RUNNER_CLUBHOUSE_PROVIDER_CLIENT_QUEUE=1`. Permission tests require `TEST_RUNNER_CLUBHOUSE_PROVIDER_INTERACTIONS=1` and an explicitly constrained interaction fixture. These tests skip in ordinary CI; local results do not replace hosted gates.

## Provider semantics

- Claude SDK accepts a direction during generation using native `priority: next`. It applies at the next tool boundary; a text-only generation can finish before the direction produces another response. Do not infer immediate interruption or same-turn steering from the response marker alone. Inspect the runtime turn IDs and delivery events.
- Copilot ACP advertises `steer: false`, `queue: client`, `interrupt: true`, `questions: false`, `planApproval: false`. The active-generation test must show a queued follow-up, interrupt the first turn, then observe delivery. Structured question cards and native plan approval are unsupported in the current adapter; ordinary permission requests are distinct.
- Image/file previews use the paired desktop's experimental content policy. A provider returning a local Markdown path can link an authenticated bounded preview. This is separate from proving native provider tool-image emission. Phone attachment upload and arbitrary remote image retrieval are not implemented.
- Wake tests use the real mobile `agent.start` command and real provider adapter, with a test-only launch factory restricted to the owned test agent. They establish a cold provider launch through mobile, not arbitrary durable-agent workspace setup or persisted-session restoration.

## Fix discovered during live Claude testing

A desktop lifecycle `agent:status` update could replace an authoritative chat waiting-for-question/approval state with generic running/idle. The live adapter now preserves the more specific state until a chat event resolves it or a terminal lifecycle state arrives. A parameterized regression covers questions and approvals, followed by return to running. This does not change desktop protocol or permissions.

Full run outcomes, CLI versions, tested commits and local XCTest/provider evidence are recorded in task-13 `ADDITIONAL_PROVIDER_HANDOFF.md` after the final checks. Framebriar and shake integration remain unchanged.
