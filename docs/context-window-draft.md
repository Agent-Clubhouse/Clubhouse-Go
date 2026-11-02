# Context window preparation

Branch: `go-context-window/settings`. Design settled; no PR until desktop fixtures and integration clearance arrive.

## Contract seam

The settled design wire vocabulary lives in `CompanionAgentSettingsDecoding.swift` and
`CompanionChatControlsDecoding.swift`. The UI consumes domain types, never provider
IDs or inferred model capacity. Malformed context settings are absent. Unknown
kinds use a generic label; unknown application timings are ignored.
Do not retain a previous context setting when a settings response omits it.

Settled shape: nullable server strings/counts; kinds `working_window`,
`context_window`, `tier`; choices `{id,label,tokens?}`; `applies` includes `launch`
and/or `resume`; `state` is `unsupported`, `pick_model`, `unavailable` or null.
`contextWindow:{version:1}` gates writes. Every update returns fresh settings,
optionally with `contextWindowReset:{previous,reason}`. Session context folds from
`session_info.contextLimits` and `usage.context.size`. The event shape for
`context_window_not_applied` awaits desktop fixtures; no new event is invented.
Hand-built tests cover the design while authoritative fixtures remain pending.

## Test plan

- Decode each provider kind with server choices, default and selected values.
- Treat absent, null and malformed context payloads as absent.
- Disable unsupported/non-configurable settings with the supplied reason; obey
  editable/sleeping metadata, including the Dispatcher while it runs.
- Preserve an unsupported saved value for display without offering it as a choice.
- Encode only changed settings; encode a context reset as JSON null.
- Map `invalid_context_window` to actionable phone copy.
- Follow returned context choices/defaults after model/provider changes; never
  optimistically reapply or retain the old context setting.
- Show read-only reported capacity, compaction threshold and reserved tokens with
  distinct labels; hide absent/null/malformed values.
- Run affected Swift package tests with `--jobs 1`. SwiftUI source inspection and
  parser validation only while integration is pending. No simulator, native app,
  phone, install, publish, host restart or live E2E runs.

Full iOS build/UI validation remains pending desktop fixtures and orchestrator
clearance to increase machine load.

## Local validation

- 15 hand-built context domain/service tests passed.
- 66 affected context, settings, chat-control and Dispatcher regression tests
  passed with `swift test --jobs 1 --filter
  'CompanionContextWindow|CompanionChatContext|CompanionSettingsContract|CompanionChatControls|CompanionChatControl|DispatcherDomainTests|DispatcherLiveServiceTests|DispatcherContract'`.
- Four existing transport encoding/capability checks passed with `--skip-build`:
  `updateEncodesChangesAndClearsWithNull`, `emptyUpdateIsRefusedBeforeSending`,
  `durableFeaturesNeedTheCommandAndVersionOne`, `freeAgentModeIsSentOnlyWhenGiven`.
- Both modified SwiftUI files passed `swiftc -frontend -parse`.
- `git diff --check` passed. This repository defines no separate lint command.

SwiftUI type checking/rendering and new desktop-fixture integration have not run.
The existing generic chat error/notice path can display a desktop message; no
special handling for `context_window_not_applied` is added until its event shape
is supplied.
