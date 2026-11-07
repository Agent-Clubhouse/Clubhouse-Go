# Unapplied Dispatcher-only transcript-point proposal

Status: SOURCE-ONLY, UNAPPLIED against exact
`dfb6f4c13196f0ca3f1d70d266ceb8cc37b20dda`. No frontend parse, SDK/typecheck,
build, test, simulator/app/provider probe, branch/source modification, commit or
push. This proposal allocates no execution and infers no current9107 result.
Root retains current runtime/artifact/pixel review. Separate Dispatcher drag,
context/semantic/AgentTree candidates and all historical refs remain preserved.

## Exact scope and intended interaction

Only `Annex/AnnexUITests/CompanionKeyboardDismissalUITests.swift`: insert private
optional-coordinate `dispatcherTranscriptPoint(_:stage:)` and replace the TWO
`transcriptPoint` calls inside private `dispatcher(_:)`. First call still makes
one blank transcript tap. The second still supplies the start of the original
`.press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:
CGVector(dx:0.5,dy:0.95)))` with default velocity. Add immediate original full-app
post-tap/post-drag screenshots; every helper invocation captures an original
full-app image BEFORE geometry queries, including unsupported geometry.

The original shared `transcriptPoint`, `focus`, `assertDismissed`, every other
helper and the entire Streaming/assistive/card-content test methods remain
byte-identical. Original launch allowance/attempt inheritance, focus setup,
typing, no-extra-control predicates, every five-second dismissal/draft/focus
assertion, Home/Dispatcher navigation, the separately measured bottom tap and
all later screenshots/actions remain unchanged. No shared helper replacement,
new focus rescue, retry, tap, wait, looped gesture or timeout change. The overlay
iteration performs at most three read-only frame queries, not gestures.

Affected method selection if independently reviewed and later allocated:

- `testEmptyDispatcherCanDismissAndReturnHome`
- `testShortDispatcherCanDismissAndReturnHome`
- `testLongDispatcherCanDismissAndReturnHome`

Both replaced callsites are in that common Dispatcher-only method. Later
bottom-tap geometry remains original and may fail separately; this candidate
does not silently repair it or validate any later phase.

## Source rationale and cause boundary

Exact dfb6 ConversationView364 pads the ENTIRE inner timeline horizontally14
at accessibility sizes and22 otherwise, before maxWidth860 and centered infinity
frames373–374. This supports a source-padding gutter candidate at raw-left+8
when actual raw/reduced/window clipping retains it. The native ScrollView's
exported origin, inner content placement and delivered hit recipient are not
source-guaranteed. No hardcoded viewport Y or header-relative offset is used.

The background ReadingTouchObserver444 is hit-disabled. The ScrollView has a
rectangular contentShape and simultaneous tap452 that calls dismissComposer;
interactive scroll dismissal447 is preserved. The independently positioned
bottomTrailing overlay453–475 contains Previous/Next assistant-message Buttons
(explicit IDs) and an optional Button exactly labelled `Latest`. It is outside
the padded timeline and can widen at accessibility sizes. Therefore trailing
alignment alone DOES NOT prove an unobstructed leading gutter. The candidate
independently checks each optional actual exported overlay action frame.

The prior review's native transcript Other/ScrollView pair and content-Window
ownership are empirical, fail-closed prerequisites, not SwiftUI AX promises.
The original principal header no longer supplies the transcript top boundary;
raw native ScrollView geometry alone can include reserved banner/composer/input
space. Historical CI initial-tap failures remain failures, with their actual
attempt counts; no current-run result, native receiver or universal inability
to dismiss is inferred. No artifact/pixel/media investigation is duplicated.

## Exact geometry and cardinality contract

1. Preserve explicit current software-keyboard requirement: exactly one global
   Keyboard. Unlike the other no-keyboard Dispatcher helper, this method runs
   AFTER original `focus` and typing, so absence fails rather than skips.
2. Use the reviewed chain ON `app.windows`: containing Dispatcher NavigationBar,
   transcript Other, transcript ScrollView, composer-region Other. Require one
   content-owning Window BEFORE retrieving it; global Window count is diagnostic
   only. Never use first/largest/same-frame/Main-label selection or text parsing.
3. Require original guarded global counts nav1/Dispatcher1, transcript
   any2/Other1/ScrollView1, whole composer any1/Other1, inputView1, assistant<=1,
   tab<=1. Require global Previous-ID/Next-ID/exact-Latest Button counts<=1.
   Before ANY frame use, require selected-window local nav/Dispatcher,
   transcript any/Other/ScrollView, composer any/Other and these three overlay
   Button counts to equal guarded globals. This proves common ownership and
   rejects ambiguous/off-window exports. Input/Keyboard/assistant stay app-wide
   because separate native input windows are valid.
4. Retrieve only guarded indexed exports. Require current existence and finite
   positive actual app/window/nav/transcript/composer/Keyboard/input and optional
   assistant/tab frames. For each PRESENT overlay Button, guard its count first,
   require exists and a finite positive actual frame; no index on a zero count.
   Native names/roles are empirical requirements, not generalized fallbacks.
5. Window is selected Window.frame intersect app.frame; require finite positive
   window, nav contained, raw ScrollView contains reduced Other, visible whole
   composer/Keyboard/input and Keyboard-input overlap. A visible assistant must
   overlap input; wholly offscreen finite assistant contributes no obstruction.
   A present tab must have positive window intersection. All global/local count
   and finite/overlap predicates are retained as named scalar diagnostics.
6. Bottom is earliest actual top of whole composer/fullinput/Keyboard/visible
   assistant/tab or window bottom; top is max(window.minY,nav.maxY). Clip is the
   intersection of actual reducedOther, rawScrollView, window and nav-to-bottom.
   Require finite positive clip and clip with TWELVE points removed vertically
   at EACH end. No horizontal inset12: it would discard raw-left+8. Midpoint Y
   is measured from this vertical interior, never header+35 or raw frame alone.
7. Sole candidate X is actual rawScrollView.minX+8. Require finite point strictly
   between actual raw minX and minX+14 (minimum source padding), inside BOTH
   transcript exports, vertical interior/clip/content window, below nav, above
   and outside whole composer, outside every actual full-input/tab obstruction,
   and outside every exported overlay Button frame. Unsupported horizontal
   clipping, missing/duplicate export, nonfinite geometry, no safe gutter or
   overlay intersection fails with NO coordinate/gesture/tap. No alternative X,
   guessed safe point, semantic dismissal shortcut or fallback.
8. Convert global point to app-relative offset by subtracting actual app.minX
   and app.minY. Never assume zero origin. Helper returns a coordinate only;
   outer optional guards prevent original action after an explicit rejection.
   Diagnostic editor count/frame remains nonselecting (frame only if count1).
9. Diagnostics include stage, every global/local count, raw/visible frames,
   each finite/existence/overlap/clip/point/overlay predicate BEFORE rejection.
   Reject captures another original screenshot plus capped64KiB public
   hierarchy before XCTFail. Text never determines a coordinate or action.
   Sequential public queries/captures are not atomic and may be slow. The
   pregeometry original and immediate post-action original are temporally
   labelled; they do not fabricate a contemporaneous native hit-test sample.

## Reconstruction and limits

Removing only the new helper, reversing the exact two coordinate-call changes
and removing their two post-action evidence shots reconstructs the COMPLETE
frozen dfb6 file byte-for-byte. The original one blank tap, native down-drag line,
normalized endpoint, separate bottom tap, all assertions and all external tests
are retained. Source/text equality is not parsing, compilation or runtime proof.

The source supports the chosen padding region, and actual exported frames
exclude known overlay actions. These facts DO NOT prove the native event
recipient, actual drawn child bounds or all possible system overlays. There is
no source-guaranteed exact content-frame export, OS hit test or device-pixel
proof. This narrowly checked candidate remains conditional on current measured
exports; absent/ambiguous/inconsistent shapes fail closed, without rescue.
A future independently reviewed allocation is needed to exercise all three
Dispatcher routes, native dismissal and original later behaviors. Inherited
fast-mode/launch attempts and original focus helper behavior remain qualified.
No proof is inferred for the separate Streaming, assistive or bottom-tap paths.
