# Unapplied assistive-row trailing Interrupt semantics proposal

Base: frozen `dfb6f4c13196f0ca3f1d70d266ceb8cc37b20dda`. SOURCE-ONLY, unapplied.
Only proposed test change is inside
`CompanionKeyboardDismissalUITests/testAssistiveDismissControlFitsTheComposerAndKeepsTheSlashWordClosed`.
Proposed doc path: `docs/combined326-assistive-trailing-order.md`.
No tracked application, parse, typecheck, build, test, simulator/app probe, commit,
push, new helper, product or shared support change. Active Dispatcher0103 runtime
and initial-tap/Streaming/AX-placeholder/other-shard analysis remain root-owned.

## Contract and retained evidence

The accepted compact composer places Interrupt immediately BEFORE Send on the
TRAILING side of the editor. The old assertion at base159 instead requires
Interrupt entirely left of the editor. Product source declares editor first,
then adjacent Interrupt/Send; this semantic correction changes no product order.

All three actual CI42237380626 attempt1/job127959571248 executions failed BEFORE
Dismiss at that obsolete inequality. Retain all three failures and originals.
Their identical logged frames show editor maxX234.6667, Interrupt x240.6667 with
maxX284.6667, Send x294.3333 with maxX338.3333, Dismiss x346. Stop/Send gap is
9.666666666666686, centers505. The printed Interrupt width is literally
43.99999999999997; do not round it into a strict >=44 pass. This method's
existing44 checks cover Dismiss; no new Interrupt44 assertion or claim is added.

The mapped evidence did not reach the original screenshot after geometry, native
Dismiss action or downstream slash-word/refocus assertions. Root's derived video
review adds visible trailing-order evidence only, not Dismiss-action acceptance.

## Exact proposed test delta

- Add an ORIGINAL full-app screenshot after the exact Dismiss label check and
  BEFORE canonical-target lookup/geometry assertions. It preserves current row
  and keyboard pixels if any new count/geometry predicate fails; no image is
  fabricated or extracted by preparing this source proposal.
- Query `app.buttons.matching(identifier:"companion-interrupt")`; log/count and
  require EXACTLY1 before `element(boundBy:0)`. Explicitly retain exact label
  `Interrupt` (the former label-based selector's semantic expectation). No first
  match, alternate ID or duplicate fallback.
- Cache editor, Interrupt and Send CGRects once for the new relations, log both
  action frames and gap, then require editor.maxX <= Interrupt.minX,
  Interrupt.maxX <= Send.minX, and gap <=16. The latter two use the SAME queried
  Interrupt/Send pair, with no epsilon, rounding or threshold relaxation.
- Preserve the original editor<=Send and Send<=Dismiss assertion lines verbatim,
  all original hittability/app containment, Dismiss44 minima, editor100 minimum,
  labels, row activity and original post-geometry screenshot.
- Preserve every original action/wait/launch/focus/typing/slash assertion,
  including the exact suffix from Dismiss.tap through final slash-menu reopen.
  No retry, new focus rescue, helper, wait, timeout or allowance is added.

Reversing ONLY the exact method delta reconstructs the full base file. Every byte
outside this method remains equal, including the shared focus/transcript-point/
assertDismissed helpers, Streaming and initial-tap tests. No different Dynamic
Type branch is introduced: this existing case has no AX-size launch argument.

Future acceptance, under separate review/allocation, still requires the original
complete method: actual Dismiss closes keyboard and editing, draft remains `/r`
and slash menu disappears; refocus+e does not reopen that word, a new slash does.
A corrected ordering check is not proof those actions work. Full control pixels,
actual keyboard geometry, native hit ownership and complete scenario acceptance
remain runtime work. Existing failures, source refs and product44 question remain
preserved. No execution or passing result is claimed here.
