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
