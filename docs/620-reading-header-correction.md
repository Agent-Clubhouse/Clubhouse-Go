# Reading clearance and Header readiness correction

This child of reviewed `3770acdd9` retains that menu correction unchanged. The
product change is limited to the other-agent banner; the two UI test changes
retain their original presence, geometry and sample gates.

## Original evidence

Scope4 job `137271104610`, run `45042340062`, artifact `14765560468` ran on
`25b3f7ece`. XXXL Reading failed the unchanged clearance assertion three times
(26.407s, 23.599s, 26.943s). Each **post-test** single-snapshot diagnostic reports
accessibility5, iOS26.5, iPhone18,3 and a 402×874pt app. These are later samples,
not a claim to have captured the precise failed predicate instant.

All three have the same geometry: View River ends at y289; the native scroll
track spans y320.6667–429.3333; Show earlier spans y344.6667–447. Its top is below
the banner, but its bottom exceeds the track by 17.6667pt. Latest spans
y362.6667–421.3333 and overlaps it. The two recorded native tracks have identical
frames; the diagnostic retains both, along with two transcript nodes, instead of
claiming unique snapshot owners. The original predicate's bottom containment
therefore fails on these frames despite the separate live hittability result.

The original first paused screenshot shows the large three-line River banner
and wrapped View action. The first movie's actual PTS18.1783s shows Show earlier
under Latest after the status-bar tap. Requests at 19s and 24s both decode that
same frame; they are one visual observation, not two samples. Neither image nor
later diagnostic alone establishes the exact failed SDK query state.

Header push/pop produced 95 and 98 samples before a 109-sample retry pass in the
same 14s window. All three report zero missing elements, geometry violations and
whole-app fallbacks. The first two retain their failed minimum-sample verdicts.
Activity starts show partial-drag-to-next-sample spans of 2.504/2.381/2.361s and
Back-readiness-to-reopened-next-sample spans of 5.278/4.588/4.418s. Those spans
include native work and route checks, not isolated query CPU cost. The other
four Header cases passed first; the retry does not supply first-attempt credit.

The relevant banner/fixture geometry source was already on main: #620 moves
the conversation background and adds diagnostics. No introduced-layout cause is
proved by this comparison. Scope1 sender-fold first76.932s pass and cold-launch
first30.111s failure/retry166.642s pass remain separately parent-attributed.

## Bounded change

At accessibility sizes without a keyboard, horizontal ViewThatFits keeps the
full banner when its natural-width name, status and View action fit; otherwise
it uses the existing full-width compact action. Dynamic Type remains enabled.
The compact nonkeyboard label can wrap without the keyboard's two-line cap.
Its visible name/status, glass button appearance, minimum44pt height and exact
`openAgent(other.id)` destination are retained. Nonkeyboard accessibility keeps
the View-name label and exposes status as its value. The keyboard keeps its
existing combined label, two-line cap and forced compact presentation. Regular
text sizes keep the full banner.

Only XXXL's clearance predicate additionally rejects overlap with Latest and
requires the banner to be hittable with a target at least44×44pt. Complete
Earlier containment below the banner/inside the native track, the unchanged
spoken label/identifier, real status-bar tap and original five-second assertion
remain. Other callers retain their original predicate through the default flag.
Shrinking the banner is not accepted as proof of clearance: both conditions
must pass on the candidate's actual native layout.

The three push/pop readiness checks first query actual existence and wait only
if absent. A monotonic deadline debits that first query from each original5s
budget. An exhausted budget fails; no retry, sleep, fabricated frame or longer
sample window is added. The native partial swipe, required Back tap/root check,
reopen check, 14s window, minimum100 snapshots, one-second grace and all geometry
assertions are unchanged. Requested timeout budgeting does not interrupt an SDK
call or prove actual elapsed savings or a future sample count.

## Proof limits

Source inverses reconstruct the untouched Reading/Header code and production
code outside the banner. Nineteen exact-extracted Swift controls use real
Foundation/CoreGraphics with fake XCUI elements and a fake monotonic clock:
presence/refusal/remaining budgets, the three saved geometries, stricter Latest
overlap rejection, original clipping and hittability, and the44pt target.
Frontend parsing proves syntax only. These controls do not execute SwiftUI
ViewThatFits, native selection/geometry, SDK queries, gestures or VoiceOver.

The parent owns hosted proof of actual adaptive selection, full name/status,
keyboard/nonkeyboard accessibility, correct destination, Earlier containment
and nonoverlap, all Header first outcomes and final required checks. No new
native/simulator run, hosted submission, deadline/threshold expansion or shared
publication is part of this isolated correction.

## Follow-up on exact 7a4f hosted originals

Run 45053284647, job 137307511037, preserves three XXXL Reading failures at
line 59 (25.086, 27.920 and 25.375 seconds) and the SE first pass (22.120).
Three post-test single-snapshot diagnostics agree: banner bottom 240.3333,
native track 246.3333–429.3333, Earlier 270.3333–372.6667, Latest
362.6667–421.3333. Earlier is wholly within the track and below the banner;
the banner's 370×116.3333 target exceeds 44×44. Earlier and Latest overlap
vertically by approximately 10 points. Both track records are retained as
identical records, not forced into a unique owner. These are late supporting
observations, not the exact assertion instant. The first recording's decoded
frame at actual PTS 22.628333 seconds visibly supports that overlap (requested
23 seconds is not relabelled as the actual timestamp).

The nonkeyboard accessibility compact banner now uses explicit four-point
vertical chrome insets around the unchanged caption label and minimum target,
with the existing palette-backed interactive glass helper. It retains the full
name/status, Dynamic Type, actual other-agent destination, accessibility
label/value and horizontal/bottom spacing. Keyboard presentation keeps the
native glass style and its two-line contract. Regular/full banners and all
other conversation code are unchanged. The entire native Reading test,
including full Earlier containment, Latest nonoverlap and banner hittability/
44-point requirements, is unchanged. A smaller resulting banner and clearance
on the candidate require actual native proof; source geometry is not that proof.

### Agent menu: lookup and allowance are separate

In job 137307511032, the first XXXL invocation reached its one Juniper press,
opened its real menu, activated Details, dismissed it and returned Home. It
then stopped at line 41 before looking for Cedar because the time budget had
already expired; this does not demonstrate a wrong Cedar route. Its terminal
was failure at 341.445 seconds, after the four-minute annotation. Default
light reached the Cedar menu and Details/Done sequence, but also exceeded four
minutes. The raw restart/timeout dispositions remain red.

The first XXXL record spent an observed 89.879 seconds in a nominal two-second
generic Any lookup for Quiet, with internal SDK existence retries. Later native
records identify the fold, Juniper and Cedar as Buttons. Those three queries
now use their actual Button type; the Details sheet remains the existing
generic query. No time saved is inferred yet.

The previously independent light/dark app launch/terminate iterations have four
explicit method owners: standard light/dark and XXXL light/dark. Every method
retains the complete Juniper → Details → Home → Cedar → Details sequence,
ordered sleeping/running action sets, absent stale Wake/Start actions, full
agent/desktop preview identity, original panel/current collection binding,
one 1.2-second press per target, clipping/hittability and eight-drag bounds.
The helper body is identical after the three typed-query substitutions; all
menu validation/reveal helpers are byte-identical. The inherited 240-second
allowance, waits and attempts are unchanged; splitting does not establish that
any individual invocation fits. All four methods have one full-matrix owner
under the unchanged whole-class routing. No theme, target or action is omitted.

### Header: fresh samples with current owner binding

The five first counts were 71/86/81/69/44 with zero recorded missing frames or
geometry violations. Only push/pop and back eventually passed; a low count is
not reflow acceptance. Leading's three attempts had 44/59/93 bar queries.
Adjacent top-level activity timestamps assign 6.277/6.318/7.774 seconds to those
query-to-next-action intervals and 7.784/7.707/6.241 seconds to the two drag
intervals. These are observed intervals, not isolated query CPU or savings.

Header now binds exactly one current native navigation bar that owns the real
header button before the window and after each disturbance. Each sample still
calls the SDK's `snapshot()` afresh on that bound element. No frame or snapshot
is reused. A missing/ambiguous/lost owner or incomplete bar snapshot takes the
same fresh whole-app fallback. After real Back/root/reopen or activation guards,
the bar is rebound inside the unchanged observation window; the existing
grace deadline is set before this lookup. The complete frame walker, five
native test methods, disturbances, 14-second window, one-second grace, at least
100 samples, missing/reflow assertions and geometry thresholds are unchanged.
Logs add actual snapshot-request counts and sampled bar identifiers. Native
current-owner behavior and whether 100 samples fit remain hosted obligations.

### Bounded checks and retained limits

Real local iOS 26.0 SDK checks type-check the exact affected Header/menu sources
against actual XCTest/XCUI APIs with only a ReliableUITestCase base stand-in,
and the production banner slice against actual SwiftUI with explicit app/glass
dependency stand-ins. They do not build or execute the app. The first UI harness
omitted XCTest's Swift overlay search path and failed to find its Swift assertion
functions; that harness failure is preserved. Adding the SDK's actual developer
Swift-module path makes both unchanged inputs type-check. A source-control
comparison initially included an extra blank line and was corrected without a
source change. No compiler result substitutes for native layout or timing.

Ten extracted provider/walker controls with explicit stand-in SDK objects verify
fresh snapshots, changed frames, replacement owner rebinding, ambiguous/missing/
lost owners and leading/header fallback. The same tests do not prove native AX
identity or cadence. Parent owns the next reviewed hosted candidate, actual
strict Reading result, all four menu invocations and five Header sample counts.
No retry, deadline, gate, workflow or optional #629 optimization is changed.
