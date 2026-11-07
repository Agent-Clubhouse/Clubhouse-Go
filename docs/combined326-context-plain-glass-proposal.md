# Context button plain/glass source proposal

Status: UNAPPLIED. Base `20b8099024f3880a44ae1ec6c6b33f688454bb14`. No parse, SDK typecheck, build, test, simulator, probe, application, commit, or push is authorized by this proposal.

## Proposed boundary

Only `CompanionConversationView.contextButton` changes. Its conditional ring/Image label becomes one concrete `HStack(spacing: 0)` with the existing 44-point minimum and rectangular content shape at label level. The label receives `.glassEffect(.regular.interactive(), in: .capsule)`; the Button explicitly uses `.buttonStyle(.plain)`. The original outer minimum frame and entire accessibility suffix remain byte-identical. No added padding, toolbar setting, spacing between controls, control size, fixed/max width, overlay, proxy action, or threshold change.

This deliberately adopts the existing identity button's explicit plain/interactive capsule treatment. It does not claim native-toolbar visual parity: the identity is principal content and context is topBarTrailing. Plain governs idle content styling and may still apply state effects. Parent toolbar glass can remain or compose with explicit glass. No toolbar-background suppression is proposed.

## Evidence and limits

The inner-label-only predecessor `1df655fbff18ced79c4a58174689fe215edf811a` did not fix the native 36-point context height. This candidate adds exactly the glass modifier and explicit plain style beyond that predecessor; it is not a repeat of label sizing as a sufficient remedy. The accepted 20b base contains neither change. Diagnostic ad59 is a separate branch, not the candidate base.

Root's later five complete River source groups report pre-outer 55.5 x 36, post-outer 55.5 x 44, and ring 41.5 x 14.5, followed by a native Button export of height 36. That supports examining this allocation boundary; callbacks and native queries are not atomic or calibrated, so these observations do not prove framework cause, proposed sizes, native hit bounds, or a source-to-screen transform.

Apple source blobs `bf7ae39d14291010527c3680b54b97631b75c16f` (plain) and `4e9b6baa8459e6e4e01ff7c2d20468ca15e35bcd` (glassEffect) support the styling choices. Neither guarantees a 44-point native export, native hit area, or removal of parent toolbar glass. The inner minimum around a 41.5-point ring differs from the observed automatic 55.5-point allocation; no ring-edge clipping or topBarTrailing glass appearance fix is claimed. Appearance, nav fit, percentage widths, focus/state effects and actual accessibility activation remain unverified.

## Preserved scope and affected paths

The action, original ring and fallback expressions, percentage colors/fonts/glyphs, AX label/value/hint/conditional ID, outer minimum, toolbar placement, `showsActions` gate, usage sheet binding and target are unchanged. Known percentage and unknown-context Image branches both receive the new treatment at every size and in editing/nonediting states. Review uses the same property only on the selected page through its existing `showsActions` condition; principal identity and Review position/disclosure remain unchanged. Real conversation, Dispatcher, header/reading/recovery fixtures and Review callers are untouched.

Only stateless view composition/modifiers change. No new stored field, owner, state, binding, Task, provider IO, grant, or action is added. Tree/modifier identity and inactive/native styling behavior are not proven equivalent. Existing policy is untouched; no extractor or policy refresh was run. Retry, Composer, identity implementation, diagnostics and all tests/shared support are unchanged.

Potential affected verification includes known-context identity/context/plan-limits, unknown-context settings/plan-limits, selected Review context, accessibility keyboard toolbar, Chrome and HeaderVisual routes. Existing strict 44-point tests are retained and may still fail naturally. Context's nested ring ID remains unchanged; native Button role queries retain their existing meaning. Source parity supplies no combined runtime or appearance acceptance, no Retry remedy and no completion claim.

## Review artifacts

The full candidate, base delta, two-line style delta versus failed 1df, full reversal receipt and byte/SHA manifest are supplied separately as immutable Git blobs. Replacing only the proposed property hunk reconstructs the entire original 20b file. No candidate is applied to tracked files.
