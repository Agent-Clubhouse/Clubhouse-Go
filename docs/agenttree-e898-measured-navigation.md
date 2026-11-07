# Proposed measured Home navigation for AgentTree e898

Status: unapplied SOURCE-ONLY candidate for independent review. No tracked source
change, branch change, commit, push, Swift parse, typecheck, build, test, simulator,
or runtime probe was performed. No execution is allocated by this proposal.

## Exact scope and provenance

Base: `e898ce52f9d917ca6eb3dad2418345e4f2bfc23f`.
Only proposed test source: `Annex/AnnexUITests/CompanionAgentTreeUITests.swift`.
One private local helper, `revealHomeTreeControl`, plus replacement of only the
navigation expressions inside the original XCTAssertTrue calls at base lines 57
(post-intentional-relaunch Cedar) and 83 (initial Clubhouse project link).
The enclosing assertions remain assertions. No other original line changes.
This proposed document would be `docs/agenttree-e898-measured-navigation.md`.

Evidence map: `b30f5869ae3709caccee19209b1fe4fdded1743f` (110 records), each
materialized only in this worktree's ignored build directory and independently
verified against its mapped bytes and SHA256. Source audit:
`8bbdd7152d62e9d0addb8103bfcce8e98003cda7`; validation record:
`3dd3244556445728fedefc46213f78d488452836`. No root filesystem access.
The map contains two original XCTest PNGs (pre-relaunch, not failure-time shots),
two original videos, and SIX separately classified full unedited derived video
frames. Derived requested times and actual AV sample times differ and remain
recorded in the original provenance JSON; derived frames are not XCTest PNGs.
No new image extraction or modification was performed for this proposal.

The allocated e898 Debug and binary ownership gate passed; both UI methods ran
once and failed (0/2). Both unsuppressed initial launches returned; the nested
case's intentional preferences relaunch returned too. Neither completion marker
was reached. This does not reproduce a historical cloud launch failure, prove
preference persistence, enter the Project route, or accept either scenario.
No causal connection to frozen content187/#325 or #326 is established.

## Evidence-supported boundary

At the failed nested navigation, the first old whole-app upward swipe exported
Cedar at `(32,17.5,44,44)` with activation `(-1,-1)` / unhittable. Six further
upward app swipes did not complete navigation. The Project case initially
exported its link at `(60,635.5,89,18)` / unhittable; the first coarse upward
swipe passed its usable position. The later snapshots do not provide every
per-step final CGRect. These support a coarse/fixed-direction navigation
assumption failure, not product-level unreachability or project behavior failure.

The original native hierarchy exports one Home CollectionView covering the
whole `(0,0,375,667)` window, a Clubhouse NavigationBar initially
`(0,20,375,106)`, and TabBar `(0,584,375,83)`. These are evidence, NOT constants
in the candidate. The proposed clip excludes freshly measured nav/tab chrome.

`CompanionRootView.projectSection` places its exact project header before the
active tree, then sleeping/finished folds. `CompanionPreviewService.hosts`
binds Cedar to preview-studio/clubhouse; helperTree makes River Cedar's awake
descendant. `CompanionAgentTreeRows` exports the specific disclosure Button.
Native AX flattens project header and rows into sibling Cells: there is NO
observed native Section ancestor. The candidate makes no such ancestry claim.
Its absent-Cedar prerequisite is explicitly this SOURCE-defined same-project
order plus the unique actual header/Cell/link relationship, not a fabricated
native section container or inferred target frame.

## Exact proposed algorithm

1. Accept only the two literal IDs at the replaced calls. Retain the existing
   `checkTimeLeft` call before initial measurement and within the local loop
   (existing helper deadline 210s; no new allowance). No added existence waits.
2. Every snapshot requires exactly one actual CollectionView, Window,
   NavigationBar, matching Clubhouse NavigationBar, TabBar, and selected Home
   tab Button. Counts are guarded before indexed retrieval. No `.first` or
   fallback collection. Require finite positive app/window/collection/nav/tab
   frames, nav and tab inside the app/window intersection, nav bottom < tab top.
   Clip = collection frame intersect app/window intersect measured nav-to-tab
   rectangle. Reject invalid/empty/nonfinite geometry.
3. Before target retrieval, require app-global and collection-local any-role
   exact-ID counts to equal their respective Button counts, with all FOUR counts
   equal and at most one. Log globalButton/globalAny/localButton/localAny before
   failure. This detects same-ID Other/wrapper ambiguity against the unchanged
   original any-role `.firstMatch` caller variables; it is not a role fallback.
   Four zero counts preserve the absent-Cedar witness path. An exported target
   must exist and have a
   finite positive actual frame. Success ONLY when its whole frame is within
   the current clip AND it is hittable. A contained-but-unhittable target fails
   immediately; no navigation/action rescue. Nonfinite existing target fails.
4. ONLY count-zero Cedar may use the source-defined Clubhouse header witness.
   Require exactly one global/local StaticText `project-preview-studio-clubhouse`,
   one global/local Button `open-project-preview-studio-clubhouse`, one Cell
   under that collection containing the exact header, and exactly one project
   Button beneath that header. Exact link label `Open Clubhouse`; finite header,
   Cell and link frames; Cell contains header; header contains link. The header
   must have actual below-clip overflow with no above overflow. It can guide
   ONLY approach of that measured header. Fully contained header with Cedar
   still absent fails. Missing/duplicate/above/unsupported witness fails.
   Absent Project is never searched for. No guessed Cedar frame or onward search.
5. One shared budget of at most SIX movements per replaced call covers both
   witness and actual-target navigation. At each iteration require guide full
   horizontal fit, height <= clip height, and exactly one vertical overflow.
   Choose direction from that CURRENT guide's measured overflow (above: drag
   downward; below: upward). Existing target geometry can change direction;
   there is no blind fixed-direction fling.
6. Overflow is max(clip.minY-guide.minY,0)+max(guide.maxY-clip.maxY,0).
   Interior = clip inset12. Clearance=min(12,(clip.height-guide.height)/2).
   Distance=min(overflow+clearance, clip.height/4, interior.height-2).
   Endpoints are centered vertically about the current interior midpoint and
   symmetrically separated by that distance, inside the same visible collection
   clip. Validate finite positive distance/velocity and both endpoints inside
   interior and clip. App-coordinate offsets subtract the measured app origin.
   Quarter-clip cap is a proposed short-movement bound, not observed delivery.
7. Record an ORIGINAL screenshot immediately before each movement, then exactly
   one coordinate press-drag with `.05` initial press, velocity=actual endpoint
   distance/nominal1s and `.2` terminal hold; immediately record an ORIGINAL
   post-movement screenshot BEFORE subsequent AX queries. These documented
   gesture parameters do not guarantee physical displacement, timing or settling.
8. Freshly re-read ALL counts, target, current chrome and clip after EVERY
   movement. Return only for a fresh unique fully contained+hittable target.
   Otherwise, independently re-query the SAME pre-movement guide in the current
   collection. A same-target guide requires the identical global/local any-role
   versus Button cardinality contract: all four counts exactly one, logged before
   retrieval/failure. The explicit header role/ancestry witness is unchanged.
   Require positive actual center displacement in the commanded
   content direction AND strictly reduced overflow using the NEW clip. Both
   predicates are necessary: nav collapse alone cannot establish progress.
   Witness change, target appearance without success, or disappearance alone
   never counts as progress. Missing/nonfinite same guide fails; there is no
   generic new-witness selection to evade the progress test. Then use the fresh
   actual target (if exported) or still-overflowing header for the next movement.
9. Log snapshot counts/frames/finite/chrome/Home-selected/clip predicates, target
   exists/hit/whole containment, witness counts/Cell/link relationship, every
   endpoint and distance/velocity, same-guide displacement, old/new clips and
   overflow before failure. Failure records an original screenshot plus capped
   64KiB public hierarchy text (later retrieval, no parsing/action derived from
   debugDescription), then fails closed. The original caller assertion remains.

## Preservation and proposed future matrix

Removing exactly the added helper and reversing the two expression replacements
reconstructs the e898 test file byte-for-byte. All original launch arguments,
initial launch attempts1, intentional terminate/launch, milestone calls, original
captures, disclosure/rollup/draft-free tree checks, persistence assertions, later
Needs-you/Project/Agents navigation, waitAndTap calls, shared helpers, product,
preview fixture, timeout settings and ownership policy remain unchanged. No new
wait, tap, focus action, state setter, direct navigation, retry or allowance.
Existing earlier/later helper attempts remain as they were; replacing these two
expressions does not establish globally single-attempt navigation or low-level
XCTest synthesis behavior.

If independently reviewed and separately allocated, affected selection is ONLY:

- `ClubhouseGoUITests/CompanionAgentTreeUITests/testNestedRowsCollapseRollupRelaunchAndNeedsYouNavigation`
- `ClubhouseGoUITests/CompanionAgentTreeUITests/testProjectUsesSameTreeAndCrossProjectCaption`

Review/future evidence must distinguish: initial target visible (zero movement),
measured below/above target, Cedar witness approach within the SAME six budget,
fully visible witness but absent Cedar (failure), nonfinite/duplicate/missing
geometry, contained-unhittable target (failure), witness loss/no displacement or
no overflow reduction (failure), actual six-movement exhaustion, and original
full behavior completion after successful navigation. Unsupported AX hierarchy,
custom gesture delivery, potential header pinning/virtualization and eventual
scenario completion are UNPROVEN. The accepted native header relationship is
historical evidence to be checked freshly, not a promised export shape.

No parser/compiler/runtime validation was performed. Source-only review cannot
establish Swift SDK availability, type correctness, gesture delivery, visibility,
or completion. Root retains independent diff review and Dispatcher allocation.
All prior refs and original evidence remain frozen; this candidate is not applied.
