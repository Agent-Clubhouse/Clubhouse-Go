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
* Updated decision after desktop source attribution: generic cross-provider `agent.update(orchestrator)` bypasses guided checks on current hosts. Old hosts now show an unsupported state instead of a provider menu. The live adapter refuses generic cross-provider writes even on a guided-capable host. Same-provider no-op fields are stripped (including when accompanying unrelated edits), so a post-read race cannot turn them into a switch. Unrelated supported settings and Dispatcher authority gates remain; no failed guided transition falls back to generic update.
* Model uses the saved settings endpoint and existing separate editor. Live model/effort come from session reports. Provider change may reset model/effort/context/routing/resume selection, as the preview explicitly lists. There is no saved-effort field or transactional provider/model/effort editor in the v1 mobile contract.

## Proposed small UX change

Keep the existing guided service and transaction flow. Put provider choices and a primary **Apply provider** action before the detailed preview. The action is always present, initially disabled with a reason. Choosing checks a proposal only. Display **Proposed provider** separately from **Last confirmed saved provider**, and show the host's refusal adjacent to Apply. A successful receipt says the provider was applied on the desktop and that starting remains separate; it must not say the provider is running.

The current session is reported separately: a desktop-reported sleeping state is sleeping; an awake session's reported execution mode may describe its runtime. Never derive active provider/runtime/model/effort from the choice, preview or save. If provider identity is not reported, say it is not verified. Keep Start new session separate, subject to the unchanged fresh-preview guard and confirmation; after dispatch say only Start requested, not started/verified. Preserve all uncertain-outcome reconciliation and refusal messages.

Keep preview scope, reset consequences, retained recorded history versus non-transferred context, authentication/quota limitations and separate-start consequences readable. No new setting or managed backend behavior is invented. Existing telemetry/identifiers stay stable where possible.

## Contract gaps for desktop relay (no backend implementation here)

1. V1 start returns an untyped completed result to this screen; it does not establish the actual provider/model/effort/native session that subsequently runs. The catalog's orchestrator and preview's target runtime must not be treated as that evidence. An observed session identity/provider plus settings revision would be needed for a verified wake claim.
2. Preview/change carry no persisted model/effort values or managed-composition migration review. Preserve their reset list; keep a cross-provider model/effort editor and managed migration with #3731.
3. Old-host generic update lacks guided checks and can bypass them. Disable its provider-switch UI and refuse generic cross-provider writes before dispatch. Map `provider_change_requires_preview` to an actionable message. Preserve unrelated settings/Dispatcher guards; never fall back after guided refusal.

## Synthetic proof plan

Before/after UI must distinguish a proposed Codex from saved Claude and show a discoverable Apply action, then show saved Codex only after a synthetic host receipt, with no start before the separate confirmation. The synthetic service uses in-memory state and records command payloads; it never launches providers or writes configuration. Fail-before uses the same new assertions on main and must fail for the intended UI behavior, not a crash or fixture error.

Narrow source/domain/security matrix: opening and selection write nothing; successful changed/already-selected receipt, refresh and strict separate start; wrong-target/provider result; stale/denied/equivalence-blocked preview; contradictory readiness; offline/reconnect; unknown-save/start replay and epoch/expiry; unsupported/legacy entry; model/effort reset disclosure and no new fields sent. Reuse existing contract tests, adding only meaningful gaps.

Native UX: standard and accessibility size on an owned small phone plus normal phone; Apply/refusal/outcome all reachable, saved/proposed/session text distinct, Start cancellation sends nothing, confirmation sends exactly one checked start, unknown result locks and reopens. Independent UX/source/security review of the implementation and manifest precedes execution; exact-head runtime review precedes the PR. Native tickets come after #609's exact cleanup through the measured guard/default FIFO. No real-provider smoke tests run.

## Reviewed implementation additions

The independent proposal review requested last-reported wording, scoped receipts (host/agent/proposal/command), contradictory/failed follow-up-read controls, and a reachable disabled Apply reason at small-phone AX size. The implementation binds a destination to its target, retains the last matching saved-provider report while selecting a new proposal, and keeps Apply present/disabled with both a spoken hint and visible reason. Receipt, proposal and next-start runtime do not certify actual session/provider/model/effort.

A runtime proposal that disagrees with an explicit saved Chat/Terminal request is unsupported before Apply; this UI never sends a runtime/wrapper swap. V2's Codex-terminal-only managed work remains unshipped and unadopted. V1's native-primary-only preview cannot certify skills/MCP delivery; refusal or missing verification never triggers another provider path. The original incident remains unconfirmed.

Synthetic fixture changes are DEBUG-only and opt-in, only in the unpaired preview service and scoped to its sleeping target. Save/start results and idempotent replays live in memory; normal preview commands still refuse. Printed synthetic command identities provide a strict count/order audit. The fixture does not start a provider or alter an actual agent, file, session or host. A separate command-spy suite runs unchanged on main as the fail-before for the generic bypass.

Deliberate test-contract changes: the old legacy-menu confirmation test now requires an explicit unsupported/read-only state; Sleep refusal still cannot create provider authority; opening the guided form now requires a visible disabled Apply button, replacing its absence. The old history-session-reset control now observes an independently initiated desktop reset rather than invoking the newly prohibited generic provider switch. Its original wake-choice assertions remain. All unrelated assertions remain in place.


Apply is now in a screen-local safe-area inset with its visible/spoken reason and an explicit Review change jump. It stays on screen while browsing/selecting providers and while reading detailed warnings; it does not consume global navigation or tab chrome. The native tests assert Apply and its reason are fully on-screen immediately after tapping a provider, before any search scroll, then use the actual Review change action to reveal the comparison. Known saved model values are labelled last loaded; defaults are saved defaults, not resolved models. A receipt's model reset replaces that value with an explicit unreported post-Apply state; saved effort is unavailable in v1, and session model/effort use last reported session facts only. No unknown value is inferred from the proposed provider.

Ownership review: the explicit DEBUG fixture adds only String, Set<String> and [String: AnnexProviderChangeResult]. The Sendable receipt graph is closed over Outcome/Preview structs containing String, Bool, enums and String arrays; it owns no UI, transport, process, native session or callback. Only the PreviewService policy surface/reason and documentation are updated; ARC-only teardown, capture sites and enforcement remain. A cached-parser source preflight checks every protected class surface and constructor/capture site before any build; the compiled app gate remains mandatory.

The new in-memory provider UI fixture is additionally restricted to canImport(UIKit): it is a native app acceptance fixture, not a macOS package implementation. Normal preview behavior and all provider flow/live transport/package tests remain compiled and covered. No coverage baseline, exclusions or test skips change; the package domain does not acquire an unreachable native acceptance path.

First candidate native execution exposed an accessibility identifier collision introduced by the new inset: the original AX hierarchy labels both visible inset buttons with the outer provider-flow identifier. The container identifier now attaches to the Form before the inset, preserving the actions' own stable IDs. This is separate from the unconfirmed user incident. The same invocation showed Sleep's last Form row partly below the viewport even though hittable; its existing test now finishes a bounded native Form scroll before the unchanged full-containment assertion and captures that state. No authority, label, tolerance, timing allowance or Apply assertion changes.
