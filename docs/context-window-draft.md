# Context window draft preparation

Branch: `go-context-window/settings`. No PR until the desktop contract is final.

## Contract seam

The draft wire vocabulary lives in `CompanionAgentSettingsDecoding.swift` and
`CompanionChatControlsDecoding.swift`. The UI consumes domain types, never provider
IDs or inferred model capacity. Unknown or malformed context settings are absent.
Do not retain a previous context setting when a settings response omits it.

Pending desktop decisions: exact kind strings, choice object shape, nullable token
counts, the type/meaning of `applies`, and whether update results include fresh
context choices after a provider/model change. Hand-built tests exercise the
provisional shape; they are not desktop contract fixtures.

## Test plan

- Decode each provider kind with server choices, default and selected values.
- Treat absent, null, unknown kinds and malformed context payloads as absent.
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
  parser validation only while the contract is draft. No simulator, native app,
  phone, install, publish, host restart or live E2E runs.

Full iOS build/UI validation remains pending the final contract and orchestrator
clearance to increase machine load.
