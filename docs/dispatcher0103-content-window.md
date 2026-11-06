# Unapplied Dispatcher content-window successor

Source-only proposal against exact `0103ea67077d7a1a96a9e3a2ef2c28a4cece4a74`.
NOT applied, parsed, typechecked, built, tested, committed or pushed. No execution
is allocated by this proposal. It supersedes only the single-global-Window
precondition described in `combined326-dispatcher-keyboard-start.md`; that earlier
proposal document remains a historical record. Product and all other tests stay
unchanged. Root retains runtime/artifact/pixel review and allocation.

## Evidence boundary

The allocated exact0103 batch passed Debug and the binary gate but failed both UI
methods before any drag: global Window count was three instead of one; the other
existing counts matched. Preserve those two failures and the original six CI
Dispatcher failures separately. No dismissal or downstream behavior was proved.
Evidence map `beca06239fae473ad762da76ad5af88a38a8181f` (51 entries), validation
`b735788848575d3205b5b93c90e2adf0058f31f6`.

Only the necessary original public trees were inspected here, via shared Git:

- Short `30296885-2120-49A1-A7CD-CF9A2AFD0890.txt`, 17,082 bytes,
  SHA256 `abee186efbf26f03c7ec559f285d708663bc5fef7f0b98f447a0496136de7ba8`.
  The complete tree has one Window owning Dispatcher NavigationBar (line17),
  transcript Other/ScrollView (35/36), and composer-region Other (66). Separate
  Windows at111/116 own inputView (115) and assistant/Keyboard (128/141).
- Long `07E91F47-B797-48C2-A392-3A083A864939.txt`, capped65,536 bytes,
  SHA256 `33aed44892adf73acd4fae94441f33e17e5a19c0a5b896cd58224ff7d90431ef`.
  It shows the nav/transcript pair but truncates before composer/window-tail
  ancestry. It does NOT establish the complete long-route ownership relation.

Both inspected originals were independently byte/SHA verified. No pixels, media,
other attachments or root filesystem were inspected. Same-size windows cannot
identify the content owner; no Window label or description text drives selection.
The source does not guarantee a portable native Window/role export shape.

## Exact successor algorithm

1. Preserve the no-keyboard return and every original global count guard except
   the global Window==1 requirement. Log total global Windows diagnostically.
2. Chain public `containing` queries ON THE SAME `app.windows` query for
   NavigationBar identifier `Dispatcher`, Other and ScrollView identifiers
   `companion-transcript`, and Other identifier `companion-composer-region`.
   Require exactly one resulting content Window before indexed retrieval. No
   first/largest/frame-equality/Main-label selection, fallback or description
   parsing. These are descendants of a common Window; no transcript pair
   parent-child or native Section ancestry is asserted.
3. Preserve exact unique global nav/Dispatcher, transcript any/Other/ScrollView,
   composer any-role, Keyboard/inputView and optional assistant/tab counts. Add
   explicit global composer Other==1 to match the required concrete role.
4. After the one Window guard, query only counts inside that Window: nav and
   Dispatcher nav; transcript any/Other/ScrollView; composer any/Other. Log every
   local count and require equality with the guarded global counts BEFORE any
   frame is read. Given global uniqueness, this rejects hidden/role/ownership
   ambiguity and confirms the selected Window owns the exports subsequently
   retrieved globally. Input/assistant/Keyboard stay APP-GLOBAL because their
   owning Windows may differ. Missing/duplicate/changed shape fails closed.
5. Read the selected actual Window.frame in place of the former global index0.
   Keep finite-positive frame checks, actual Window intersect app, global full
   input/assistant/keyboard intersections, nav containment and reduced transcript
   versus native ScrollView geometry byte-identical thereafter. No clip, margin,
   hardcoded boundary, endpoint, direction or app-origin conversion changes.
6. Preserve the one original .05/default-velocity downward drag and original
   normalized(.5,.95) endpoint; preserve original pre/post screenshots, rejection
   screenshot/capped public hierarchy, and exact original five-second keyboard
   disappearance assertion. No waits, retries, taps, focus/state changes or
   allowance changes. Count retrieval is sequential, not an atomic snapshot.

## Scope, reconstruction and limits

Only the private `dismissKeyboard` helper changes. Reversing the recorded exact
replacements reconstructs the COMPLETE exact0103 Swift file byte-for-byte; every
byte outside the helper, both complete case bodies and every original line from
`let navigationFrame` through the helper end remain identical. Only selection,
count diagnostics/guards and selected Window.frame access differ. Shared support,
product, fixtures, assistive/Streaming/initial-tap tests, policies and all frozen
refs are untouched. Separate semantic and context candidates remain frozen.

Affected methods (unchanged bodies), only on a later independently reviewed
allocation:

- `testDesktopSwitcherKeepsSeparateDraftsAndScrollPositions`
- `testDraftSurvivesTabSwitchAndDisconnectAndOffMovesHomeOnce`

The positive short-tree ownership witness motivates a narrowly checked predicate;
it does not prove the long route, future exports, native gesture receiver,
keyboard dismissal, draft/scroll retention, timing or all later assertions.
A missing/ambiguous relation still fails before frame use or any drag. The original
full-input and current clip checks may reveal another unsupported precondition.
Runtime emitted YES/240/300 and long300/short240 timer resets are parent evidence,
not a hardkill guarantee or a reason to alter timeout settings. No runtime success
is inferred from source reconstruction. No new execution/probe is authorized.
