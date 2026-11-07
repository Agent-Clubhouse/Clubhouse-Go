# Unapplied focused-assistive editor allocation proposal

Exact base `d8867656dc41cd3539938cb249a7ba25f0a1a27b`. Source-only UNAPPLIED
candidate: no tracked edits/application/parse/typecheck/build/test/simulator/app
or provider probe, commit or push. Runtime allocation is separate. Frozen dfb6,
d886 failure evidence, initialtap397/ef35 and all other checkpoints remain intact.

## Proven boundary

Composer is byte-identical at dfb6 and d886, blob
`06afdcb4e5f0e7510a5177af4bb17a325836e32d`. Parent record
`fe3f774ce6bf5ce972e09a9c6521ee663262f057` reports one actual SE3/iOS26.0
375x667 execution: pre-focus native editor114, focused /r editor88.00000000000001;
Attach/Interrupt/Send/Dismiss each44, editor100 predicate fails BEFORE Dismiss.
Keep the width failure; never round it to100 or treat it as floating noise.
Controls hit/app containment and Dismiss44 passed; later order assertions,
semantic Dismiss, five-second keyboard/focus/draft, slash closure/refocus/newslash
were not reached. Cloud402/iOS26.5 editor116 and old order failures remain
separate. No media/full-map/root filesystem investigation was duplicated here.

Native rectangles account for the current375px-wide window: prefix67 + Attach44
+ gap8 + editor88 + gap6 + Interrupt44 + gap10 + Send44 + gap8 + Dismiss44 + right12
=375. These are EXPORTED rects, NOT measured SwiftUI layout slots/proposals. No
exact26pt state-delta/style/native transform cause is proved. Native100, focus,
layout fitting and application pixels remain unproved by source arithmetic.

## Primary product change and exact trigger

Only existing `inputRowLayout` comment and condition change: select its EXISTING
AnyLayout VStack for AX OR `assistiveRow`. `assistiveRow` remains exactly
`composerFocused && showsKeyboardDismissButton` (308), and showsDismiss (352–358)
remains DEBUG preview+assistive flag OR actual VoiceOver OR actual Switch Control.
No new breakpoint, device width, state, measurement feedback, style/font/padding/
spacing/negative gap/minimum/control cap, condition, action or gate is added.
The same field, binding, selection, native hook and Attach picker stay declared
ONCE under the SAME AnyLayout children. No duplicated ViewThatFits field, new
branch identity, focus repair or conditional relocation of picker state.

| State / width | Existing | Proposed |
| --- | --- | --- |
| Ordinary unfocused, any width | HStack | Same HStack |
| Ordinary focused, no assistive Dismiss, any width | HStack | Same HStack |
| Ordinary focused assistive,375 | HStack | Existing VStack layout |
| Ordinary focused assistive,402 | HStack | Existing VStack layout |
| Ordinary focused assistive, wider phone/iPad or narrowed window | HStack | Existing VStack layout, no guessed threshold |
| AX unfocused/focused, assistive or not, all widths | Existing VStack | Same existing VStack |

This is intentionally editing-state/capability adaptation, not only SE3 and not
an observed-width switch. Ordinary focused assistive Attach/editor get a line
above Stop/Send; config and Dismiss remain their original outer siblings aligned
to the bottom action rail. Attach stays WITH the editor at ordinary sizes; AX
already places it in the action rail and retains that branch unchanged. Actions,
labels/IDs, enabled gates, confirmations, send, picker/upload, slash and native
focus/dismiss handlers remain byte-identical. Existing ordinary1...8 line policy
and AX focused1/unfocused3 policy remain unchanged; no hidden one-line cap.

At nominal375 minus existing outer24, config/Dismiss minimums44 each and two4
outer gaps leave255 for the middle layout before its Attach/editor internals.
Removing the adjacent action group from competing on that same text line gives
space, rather than merely adding minWidth100 to a crowded row. This is topology
feasibility, NOT a promise that the native editor exports100 or fits every
keyboard/viewport. Adding minWidth100 alone or freeing exactly12 by guessed
native-padding arithmetic can instead overflow another control and is not used.

## Primary assistive-method-only test successor

Only `testAssistiveDismissControlFitsTheComposerAndKeepsTheSlashWordClosed`
changes in KeyboardDismissal. Original pregeometry PNG, canonical Interrupt
exact1 guard/label, original editor100 and Dismiss44, existing hit/app checks,
Stop/Send nonoverlap+<=16, Send<=Dismiss, all actions and ENTIRE suffix from the
single original `dismiss.tap()` through original slash/refocus assertions stay
byte-identical. Replace only obsolete editor<=Interrupt/editor<=Send horizontal
relations with editor ABOVE the actual config/Interrupt/Send/Dismiss rail.
Attach remains with editor, so it is not falsely required below editor.

New local optional-viewport helper has NO gesture/tap/wait/focus/firstMatch.
Common actual Window ownership uses chained public containing River NavigationBar
and composer-region Other. Total Window count is diagnostic only; require one
content owner before retrieval. Guard global nav/River1, composer any/Other1,
editor any1, and actual five composer Button IDs1; selected-window local counts
must equal globals BEFORE frame reads. Input remains app-global because native
keyboard/input windows may be separate. No Main-label/largest/frame matching.

Require software Keyboard1/inputView1, assistant<=1/tab<=1; finite positive
app/selected-window/nav/composer/input and optional frames. Intersect actual
window with app; nav/composer must be within it, Keyboard/input visible and
overlapping, visible assistant overlaps input, optional tab visible. Finite
wholly offscreen assistant contributes no obstruction. Viewport is actual
window/nav bottom to earliest full-input/Keyboard/visible assistant/tab/window
boundary. Before returning it, require/log `viewport.contains(regionFrame)`:
the WHOLE measured composer region, including slash/pinned/attachments, must fit
between actual nav and full input. A region crossing that boundary fails closed
even if editor/action leaves fit. This is a strict unsupported-shape gate, not a
source/runtime guarantee that every draft height will fit; ordinary1...8 remains
unchanged. No guessed keyboard accessory size, globalWindow1 or key-rect-only
boundary. These native roles/IDs are explicit fail-closed empirical prerequisites,
not universal native guarantees. Missing/duplicate/invalid shape returnsnil and
outer method stops before original Dismiss. Public snapshots are sequential.

Retain original action loop and add config, strict44 width/height and finite
whole-viewport containment for all five actions. Require finite full editor in
same viewport and editor hittability. Original source lacks atomic exported
identity; unique global/local cardinality is the explicit precondition. Current
counts, raw/intersected frames, finite/overlap predicates and target geometry
are logged. Unsupported shape captures original PNG+capped64KiB public hierarchy;
strings do not determine coordinates or action. No epsilon, scale normalization,
44pt text-line claim, selector fallback, focus repair or timeout change.
Ordinary XCTest assertions retain existing continueAfterFailure behavior; only
explicit new shape/finite guards stop the method. No claim every failed assert
prevents downstream action. Runtime full minimum/containment evidence is needed.

## Explicit adjacent Compact dependency (separate proposal)

The primary product/test patch is NOT a claim Compact ordinaryWorking is
unaffected. `workingRow(largestText:false)` launches assistive+sampleimages;
empty/unfocused and image-only/unfocused assertRow calls46/54 remain HStack;
its typed/focused call61 intentionally becomes VStack. The ordinary assertion425
(editor horizontally before Interrupt) then becomes obsolete. Refocus after
Cancel calls assertEnabledEditingRow, whose existing finite viewport/control
checks remain relevant; final typed/unfocused89 returns to original HStack.
AX largestText uses the same VStack as before, including its distinct action
placements,70% width and approval review predicates.

A SEPARATE optional Compact dependency diff is supplied for independent scope
review, NOT folded into the primary product+assistive-method diff. It adds a
specific defaultfalse `ordinaryAssistiveEditing` assertion parameter, passes it
ONLY at the typed/focused call61 as `!largestText`, and adds strict native
editor>=100 plus editor-above-Send in that ordinary-specific branch. This covers
the changed text+image focused route without importing AX70%/role assumptions.
All original AX `stacked` predicates (including
70%/approval roles) and unfocused horizontal assertions, minima, Stop/Send gap,
images/drafts/confirmations/cleanup/actions remain unchanged. No broadening of
the generic AX stacked flag or environment-derived silent selector fallback.
This dependency needs explicit acceptance before treating Compact validation as
compatible; no tests are silently omitted or reinterpreted by the primary patch.

## Affected behavior / future evidence, not executed tests

- Exact assistive method: original /r focused stack, actual editor100/control44/
  adjacency/full keyboard-accessory containment, ONE semanticDismiss, keyboard/
  draft/focus/control closure, same-word e stays closed and newslash reopens.
- Compact ordinaryWorking: unfocused empty and image-only original HStack;
  text+image focused stack, native Interrupt confirmation, same draft/image
  afterCancel, explicit original refocus, Dismiss, unfocused original HStack.
  Requires the separately enumerated assertion dependency, not an automatic run.
- Multiline ordinary assistive1...8: source policy preserved, but longer draft
  height and full viewport fit need bounded separately reviewed coverage; no new
  testcase/action is fabricated in this method. AnyLayout identity is a source
  structure property, not native focus/draft/selection continuity runtime proof.
- AX Compact: already stacked path and field policy/roles unchanged; all
  existing approval/image/multiline/keyboard assertions remain necessary evidence.
- Nonassistive idle/working, ordinary centering and multiline tests: product
  condition is false, no new layout change; no regression success inferred.
- PreviewSmoke Sleep test launches assistive but has NO explicit editor focus/
  typing in its32–73 source path. It therefore does not necessarily activate
  the changed ordinary layout merely from its launch flag. Native unintended
  focus is not source-proved absent; report reached state, not all-flag claims.
- Actual VoiceOver/Switch Control ordinary focused edits at ALL widths share
  the condition; no real assistive-service/device validation is claimed by the
  preview flag. Keyboard appearance/dismissal and retained-page focus, draft,
  caret/selection continuity and reduced transcript height remain runtime risks.

## Exact reconstruction

Reversing only the condition/comment reconstructs full base product. Restoring
only the assistive method reconstructs full base KeyboardDismissal; protected
Streaming/Dispatcher/shared methods and every downstream assistive byte remain
equal. Reversing the three optional Compact hunks independently reconstructs
its full base. No source files are applied, no parser/SDK/test is executed, and
no existing failure/evidence is replaced. Source review precedes any application
or separately allocated validation. No complete #326/keyboard acceptance implied.
