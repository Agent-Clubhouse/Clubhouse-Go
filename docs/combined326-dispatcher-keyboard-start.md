# Unapplied Dispatcher transcript keyboard-drag geometry proposal

Status: source-only candidate, NOT applied, parsed, typechecked, built, tested,
committed or pushed. No simulator/app/device/provider probe or execution is
allocated. Root retains CI artifact/pixel/native-receiver review and Dispatcher
retains allocation. All frozen checkpoints/evidence remain unchanged.

## Base and exact scope

Base: `dfb6f4c13196f0ca3f1d70d266ceb8cc37b20dda` (#326 frozen head).
Only proposed Swift change is replacement of the private `dismissKeyboard`
helper in `Annex/AnnexUITests/CompanionDispatcherUITests.swift` (base16–24).
Both callsites, both entire case bodies and every other byte outside that helper
are unchanged. Proposed documentation path:
`docs/combined326-dispatcher-keyboard-start.md`.

Affected selection, only if subsequently reviewed and allocated:

- `ClubhouseGoUITests/CompanionDispatcherUITests/testDesktopSwitcherKeepsSeparateDraftsAndScrollPositions`
- `ClubhouseGoUITests/CompanionDispatcherUITests/testDraftSurvivesTabSwitchAndDisconnectAndOffMovesHomeOnce`

Shared UITestSupport, CompanionKeyboardDismissalUITests (including initial
transcript taps, Streaming and assistive cases), product, fixture, policies,
launch attempts, timeouts and all original downstream assertions remain intact.
The helper has exactly these two callers. This proposal creates no shared
keyboard/focus owner or fix for #264/#278/#304 and changes no other sublane.

## Evidence and cause boundary

CI42237380626 attempt1/job127959570933 on iPhone17/iOS26.5 retained SIX actual
failures: each affected method failed three executions at the original helper's
five-second keyboard-disappearance predicate. Preserve all six; do not replace
them with one representative success or reinterpret source helper attempts as
observed CI counts.

The old start was app-origin + (first window.width/2, first
`companion-chat-header`.maxY+35). That ID moved from an in-content status row on
main814dc293 to a navigation-principal disclosure Button. It no longer measures
the transcript's reduced top boundary. Product transcript interactive dismissal
and explicit focus/resign handlers were preserved. Native raw ScrollView bounds
may extend under actual bar reservations; they are not the reduced visible clip.

Root's retained final hierarchies export a same-ID Other reduced viewport plus a
native ScrollView. Parent reports synthesized down(201,141)/up(201,830.3), final
Other(0,197.7,402,273.3), ScrollView(0,141.3,402,732.7), and River banner in the
upper reservation. Final numeric frames are NOT contemporaneous pre-drag
hit-test evidence. Root's original/derived video review remains separately
qualified. No native event recipient or product inability to dismiss is proved.
No artifact/pixel investigation is duplicated by this candidate preparation.

## Exact helper contract

1. Read/log keyboard count. Preserve the no-keyboard no-action return. With a
   keyboard require exactly one actual Keyboard, Window, global NavigationBar
   and Dispatcher NavigationBar. Guard all counts before indexed retrieval.
2. For `companion-transcript`, require exact global counts any-role=2, Other=1,
   ScrollView=1. Thus no third role, hidden duplicate, arbitrary first element,
   raw-frame fallback, header+35 fallback or synthetic marker can supply start.
   Require exactly one any-role whole `companion-composer-region`, exactly one
   `inputView`, at most one `SystemInputAssistantView`, at most one TabBar.
   These native roles/names are empirical FAIL-CLOSED preconditions for the
   reviewed normal Dispatcher shape, not a portable AX guarantee.
3. Source declares ONE ScrollView identifier in ConversationView448. It does
   not specify this native role pair or a parent-child direction. The candidate
   makes no ancestry claim. Require finite positive current frames and actual
   exports; require the raw ScrollView geometrically contains the reduced Other.
   Missing/ambiguous/nonfinite/inconsistent shape fails before any gesture.
4. Window = actual Window.frame intersect app.frame. Require a positive finite
   window and nav inside it. Intersect whole composer, Keyboard, inputView,
   optional assistant/tab with that window. Require positive composer/keyboard/
   input intersections, positive keyboard-input overlap and, when on-screen,
   assistant-input overlap. A finite assistant wholly off-screen contributes no
   obstruction; it is not treated as an alternative input region. Present tab
   must have positive window intersection. Invalid raw optional frames fail.
5. Bottom is the earliest measured top of whole composer, Keyboard, inputView,
   visible assistant, visible tab and window bottom. Top is max(window.minY,
   nav.maxY). Actual clip = reduced Other intersect raw ScrollView intersect
   actual app/window intersect the nav-to-bottom rectangle. Require positive
   finite clip and positive finite clip.inset12 interior. No guessed banner,
   keyboard or composer height; no hardcoded197.7; keys alone are insufficient.
6. Start is the inset interior midpoint. Require finite point, full membership
   in both transcript rectangles/interior/clip/window, below nav, above whole
   composer and outside every measured input/tab rectangle. Convert the global
   start to app-relative offsets by SUBTRACTING the measured app origin from
   both coordinates. There is no assumption that app/window origins are zero.
7. Preserve the original app-normalized(.5,.95) endpoint. Derive its diagnostic
   global point as (app.minX+.5*app.width, app.minY+.95*app.height); require finite,
   in-window and strictly below start. It deliberately need not remain inside
   the transcript: the original native interactive down-drag continues toward
   the bottom through composer/input space. Existing dedicated keyboard drag
   coverage also uses this endpoint. Unsupported direction/window fails; there
   is no guessed alternative endpoint, shortened gesture or dismissal shortcut.
8. Log counts, exports, all raw/visible frames, individual finite/overlap/clip/
   exclusion/direction predicates and actual proposed start/end before failure.
   Editor count and, only when exactly one, its frame are diagnostic-only; no
   focus assertion/repair is added. Ambiguous diagnostic editor is not selected.
   A rejection retains an original full screenshot and capped64KiB public
   hierarchy before XCTFail; description text never drives actions. Retrieval
   is sequential and may be slow; a cap on text size does not bound SDK lookup.
9. Capture ORIGINAL full-app pre-drag PNG, execute the original ONE
   `start.press(forDuration:0.05,thenDragTo:end)` without custom velocity, then
   capture ORIGINAL immediate post-drag PNG before the original assertion.
   Keep the original `app.keyboards.firstMatch.waitForNonExistence(timeout:5)`
   assertion byte-identical. The one-keyboard gate precedes action; the preserved
   final firstMatch is the original disappearance query, not a new selection
   fallback. No new explicit wait, tap, focus action, retry, loop or allowance.

## Preservation and limits

Replacing only the new helper with the original reconstructs the COMPLETE base
Swift file byte-for-byte. Original drag line, normalized endpoint line and
five-second assertion are retained verbatim. The short-route Settings/reports/
Home/off behavior and long-route Latest/desktop/draft/scroll/tab assertions are
not weakened, removed, reordered or newly executed by source comparison.

The exact native exports, current measured clip, native gesture recognition,
actual keyboard dismissal and downstream behavior still require independently
reviewed runtime evidence. Sequential queries are not an atomic hit-test snapshot;
containment does not prove which child recognizer receives a future drag. Native
role changes, missing full-input exports, duplicate hidden pages, invalid frames,
insufficient inset area or out-of-window endpoint FAIL CLOSED with no gesture.
A software-keyboard absence returns without exercising dismissal, as before.
Existing fast-mode inheritance does not prove production animation/focus timing.
Source reconstruction/guard review is not parse/typecheck/runtime/visual proof.
