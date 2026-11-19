# Mobile provider Apply (#610)

## Diagnosis and versions

Branch starts at Go main `85ee757ae3de9d962d0cafab81ad0011314522ab`. The Provider screen, flow and wire types are unchanged from the beta.3 source `77b248991`. Those source versions do not establish the installed phone/desktop pair in the reported incident. No incident transaction receipt or successful save is known. Missing target native instructions block the investigated desktop's managed transition; that is not an established cause of the user's incident.

Desktop managed migration is owned by Clubhouse #3731. Remote read-only agent cards (#3733) are separate. This work changes no real agent, native file, managed part, model setting, session, WIP or history, and includes no install or release.

## Existing entry paths and authority

* `CompanionAgentSettingsSheet` offers the guided destination only when the host has the exact supported provider-control capability, or an unresolved provider action needs reconciliation. Opening the destination does not preview or mutate.
* Guided selection calls `providerPreview` only. The saved provider is a separate field in the response; `provider` is the proposal. The preview's target runtime is prospective, not an observed session. Provider availability means local CLI installation only.
* `CompanionProviderFlow.save()` sends one `agent.providerChange` with the opaque expectedState. The host revalidates and persists the provider. A matching completed receipt followed by a fresh preview gates a separate explicit `agent.start(resume:false, expectedProvider:...)`. Selection never starts; Apply never starts. A confirmation remains required for Start.
* The save guard requires sleeping, no active provider, availability, exact native-primary equivalence/scope, retained history, no context transfer, supported capability, connected host and the Store's existing genuine operation gates. No managed special-case can bypass it. Managed and unmanaged agents both require the host's permitted result; the phone does not infer managed equivalence or generate native instructions.
* An uncertain write remains locked across sheet dismissal. Check previous result replays the identical command ID/body only within the original epoch/idempotency window. Stale/refused results clear the preview; reconnect does not establish a save or session.
* Old hosts retain the existing generic `agent.update(orchestrator)` menu, its field editability, confirmation warning and returned-settings path. This screen redesign does not reroute or strengthen that legacy contract into a falsely verified wake claim. Existing callers remain supported.
* Model uses the saved settings endpoint and existing separate editor. Live model/effort come from session reports. Provider change may reset model/effort/context/routing/resume selection, as the preview explicitly lists. There is no saved-effort field or transactional provider/model/effort editor in the v1 mobile contract.

## Proposed small UX change

Keep the existing guided service and transaction flow. Put provider choices and a primary **Apply provider** action before the detailed preview. The action is always present, initially disabled with a reason. Choosing checks a proposal only. Display **Proposed provider** separately from **Last confirmed saved provider**, and show the host's refusal adjacent to Apply. A successful receipt says the provider was applied on the desktop and that starting remains separate; it must not say the provider is running.

The current session is reported separately: a desktop-reported sleeping state is sleeping; an awake session's reported execution mode may describe its runtime. Never derive active provider/runtime/model/effort from the choice, preview or save. If provider identity is not reported, say it is not verified. Keep Start new session separate, subject to the unchanged fresh-preview guard and confirmation; after dispatch say only Start requested, not started/verified. Preserve all uncertain-outcome reconciliation and refusal messages.

Keep preview scope, reset consequences, retained recorded history versus non-transferred context, authentication/quota limitations and separate-start consequences readable. No new setting or managed backend behavior is invented. Existing telemetry/identifiers stay stable where possible.

## Contract gaps for desktop relay (no backend implementation here)

1. V1 start returns an untyped completed result to this screen; it does not establish the actual provider/model/effort/native session that subsequently runs. The catalog's orchestrator and preview's target runtime must not be treated as that evidence. An observed session identity/provider plus settings revision would be needed for a verified wake claim.
2. Preview/change carry no persisted model/effort values or managed-composition migration review. Preserve their reset list; keep a cross-provider model/effort editor and managed migration with #3731.
3. Old-host generic update lacks the guided expectedState/strict-start contract. Preserve the supported existing caller and disclose its limits rather than claiming equivalence.

## Synthetic proof plan

Before/after UI must distinguish a proposed Codex from saved Claude and show a discoverable Apply action, then show saved Codex only after a synthetic host receipt, with no start before the separate confirmation. The synthetic service uses in-memory state and records command payloads; it never launches providers or writes configuration. Fail-before uses the same new assertions on main and must fail for the intended UI behavior, not a crash or fixture error.

Narrow source/domain/security matrix: opening and selection write nothing; successful changed/already-selected receipt, refresh and strict separate start; wrong-target/provider result; stale/denied/equivalence-blocked preview; contradictory readiness; offline/reconnect; unknown-save/start replay and epoch/expiry; unsupported/legacy entry; model/effort reset disclosure and no new fields sent. Reuse existing contract tests, adding only meaningful gaps.

Native UX: standard and accessibility size on an owned small phone plus normal phone; Apply/refusal/outcome all reachable, saved/proposed/session text distinct, Start cancellation sends nothing, confirmation sends exactly one checked start, unknown result locks and reopens. Independent UX/source/security review of the implementation and manifest precedes execution; exact-head runtime review precedes the PR. Native tickets come after #609's exact cleanup through the measured guard/default FIFO. No real-provider smoke tests run.
