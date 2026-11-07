# Full-width composer for feedback 3277d430

Report 3277d430-b8a4-45d0-a21e-5794117f70ce was captured at 2026-11-07 03:16:16Z on installed b17f9f80/#303 (2.0.0+218). Its owner inspected an eight-line Working draft, with Options/Stop occupying a mostly empty left column. This is a real usability defect. The screenshot is not current-head evidence. #325 retains that old layout. #328 f19c/a51 already collapse Options consistently and place Interrupt beside Send, but ordinary editing still reserves side columns.

This successor of a51 belongs to #328. It uses one full-width text row above the action row at every focus state/text size. Options and Attach precede Interrupt/Send; the existing accessibility Review and optional Dismiss controls keep their roles. The original TextField position, binding, focus, selection, input hook, line limits and actions remain. No new state, owner, cached draft, alternate field, equality wrapper or observation bypass. Layout/insets no longer change on ordinary versus assistive focus. Product bytes are the reviewed-direction candidate ba5a2ad38b82d60b781fb65e28b1b3df4c12e77b.

The change intentionally spends an action row of height to recover text width and consistent placement. Ordinary text still grows up to eight visible lines; accessibility editing retains its existing one-line limit, with the entire draft retained. Width does not prove vertical fit. Eight explicit lines with pinned approval must pass the smallest-viewport checks; no skip, truncation, smaller text/target, conditional success or allowance relaxation is supplied for overflow. A measured failure remains a product/layout gate requiring a supported correction before acceptance.

At the existing nominal 44-point minima, the six-action accessibility row (Review, Options, Attach, Interrupt, Send, Dismiss) needs 264 points plus 30 points of outer-row spacing, or 294 points. On a 375-point surface with the existing 16-point outer insets there are 343 points before native style/allocation effects. This is a source minimum calculation, not native-width or hit-target proof. The UI assertions independently check each original strict44 floor, pairwise non-overlap, actual order, region/viewport containment and Interrupt-to-Send gap at most16. Larger native allocations or insufficient vertical space fail normally.

## Placement tests

Two new methods in the existing Compact suite launch the ordinary preview without the assistive flag, each once under the existing source240/helper210 allowance. They enter Working River through the original navigation helpers and retain pending approval. One types exact newline-separated Line1 through Line8, sampling every intermediate state. The other types a finite ordinary string that must soft-wrap. Both require exact complete text, keyboard focus, no assistive Dismiss, whole composer/targets inside the measured header-to-full-input viewport, and full horizontal text extent after the two explicit16-point insets. They open Options, dismiss the menu using the existing guarded helper, refocus, open Interrupt confirmation, Cancel through the existing helper, and verify exact draft/normal preview-error predicates. No Send or confirmation dispatch is added. A missing error is only the existing UI observation, not network telemetry.

Existing Compact actions/launches/waits and confirmation helper are unchanged. Its old ordinary Interrupt-beside-editor placement assertion becomes editor-above-actions; strict44, attachment, approval, gap, Cancel and draft checks remain. Shared editing checks now additionally require the whole region, pairwise target capacity and full-width editor for ordinary and accessibility fixtures. Existing PreviewSmoke ordinary one-line midY/last-line alignment assertions become editor-above-action/full-width assertions, with exact Hey added; single/wrapped line-height checks and original typing budget remain. The accessibility placement test remains byte-identical. The three hosted ComposerIsolation methods, including strict zero rebuild, positive streaming, native identity/selection and remount controls, are unchanged.

## Proposed bounded acceptance (not allocated/executed)

Fresh reviewed Debug build and exact30ARC/17-retained ownership gate, then one serial pass on owned SE3/iOS26.0 (375-point width):

1. All three existing CompanionComposerIsolationTests hosted methods, unchanged.
2. All five CompanionCompactComposerUITests methods (three existing plus the two ordinary no-assistive methods).
3. CompanionPreviewSmokeTests/testComposerSingleLineHeightMatchesWrappedLineHeight and testComposerCentresOneLineAtLargeText.
4. CompanionKeyboardDismissalUITests/testAssistiveDismissControlFitsTheComposerAndKeepsTheSlashWordClosed.

This is3hosted+8UI, 11distinct methods. Every failure is normal; no corrective repeat, iteration/retry expansion or conditional exemption. Exact runner/allocation/runtime settings still require the usual reviewed recipe; this document does not allocate a run. Existing new Compact source allowance remains240/helper210; helpers retain their inherited finite navigation/tap bounds. Actual attempts and runtime must be audited, not inferred. First failure stops the nominated sequence. Originals at all reached states precede geometry assertions. Unreached later states remain missing coverage, not passes. Preserve source/raw outcomes and owned cleanup/parent drain.

Ordinary current-head iOS26.5 CI remains required after meaningful combined publication. Preserve current runs, wait for prior #328 terminal, fresh-check actual head/base, then publish the single reviewed product+placement+existing a51 strict-observation/CI-split successor. Do not spend an extra unchanged run on a51 alone. No #325 import or update here. Current actual-head CI and its retry qualifications are separate evidence.

## Limits and retained holds

Native queries/screenshots are sequential, public frame/hittability does not prove full rendering or touch recipient. Inherited firstMatch/window/navigation assumptions remain explicit. Source16-point inset expectations are a test layout contract, not an Apple AX calibration guarantee. No tolerance is introduced. Inspect original pixels for ordinary1...8, AX, full-input, approval/attachment and action-row readability; keep numeric44 failures substantive until resolved under the existing strict contract. Text-height/line counts and capacity must not be inferred from source minima.

The yellow area near the jump controls remains separate. Current transcript source has a trailing overlay and scrollable Latest navigation clearance. No deleted screenshot reconstruction or guessed clearance reduction is made; reading/last-message visibility remains a gate. Prior b17 report, f19c/a51 CI, blocked tolerance proposal and all original composer failures remain preserved.

DEBUG/release frontend syntax parsing and diff/parity checks are source validation only, not SDK/typecheck/runtime/visual acceptance. No local execution allocation, provider action or current-run cancellation is inferred.
