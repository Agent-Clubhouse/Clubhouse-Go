Home rendering and Recent sessions (Refs #528, Refs #549)

Home's State owner stays in its Tab and NavigationStack. The expensive List unmounts ONLY when the Home TAB is deselected. The Clubhouse title, toolbar, project-error alert and pending sheets stay on the owner. Root badges, connection reconciliation and Dispatch remain live.

Returning to Home from another tab scrolls to the top, as the user accepted for #551.
Scroll restoration remains open in #557 / #567 and the separate Draft anchor PR. #558
contains no anchor owner, geometry, ScrollViewReader, ScrollPosition, row markers or
custom ForEach identities. AgentTreeRows is byte-identical to main67b8e5b8.

Before constructing pushed Home content, a lazy non-published render session captures display values once: hosts/catalog, attention, layout, finished runs, row context, palette/helper labels, status/activity and menu presentation. All Home value copies consult that session, including old lazy List closures. The Equatable content boundary avoids per-stream layout/content construction; descendants receive optional captured values. Nil is the existing live path for non-Home callers. Ordinary labels/tree rows use value agents and Preferences. The frozen Dispatcher row receives its captured execution callback explicitly; only the live wrapper reads the Environment action.

The initial #557 diagnostics reproduced two distinct failures: new lazy row instances during the native push, and residual host/catalog-triggered work after freezing. The owner now projects plain host/catalog/attention and per-project display values before the lazy Content/List/ForEach builders, including while Home is live; while pushed it reads the existing snapshot only. The new contentInputs counter measures that projection, and remains in every strict zero-work comparison. It does not build a live per-agent permission snapshot. Settings/Wake/Terminal per-agent presentation capture remains once per push. The agent-row modifier short-circuits its existence check when Details guarantees a menu; Wake choices and Terminal availability then belong to the native menu-content child, preserving the same items and action guards without subscribing the row to those Store queries. No final runtime PASS is claimed until the exact-head proof closes.

Settings/Wake/Terminal menu queries receive frozen display values. Activation rechecks the existing live Store predicates, identity and capabilities. Existing Root open-agent/Review handles write mounted State, and new live Environment handles replace the snapshot on pop. Display never authorizes an action. The render session's nonisolated deinit retains actions/snapshot inside a real MainActor Task, avoiding the reproduced isolated-deinit StateObject teardown crash; exact fields and body are policy-gated. No task handle is stored.

The first pop construction reads current connection/status/permission inputs. Recent ordering persists across push/pop, so Back refreshes text/badges without shuffling peers. One visible owner construction computes ONE layout and passes that value to content, projects and the animation hold. The content boundary never evaluates the live conversation-activity projection; while pushed the owner reads the captured layout from the render session. Header dots reuse computed group activity. Entering a push captures exactly one display snapshot, budgeted to at most two content constructions. Per-agent predicate capture covers displayed scope/groups, visible helpers/open folds, attention and Dispatchers, not the entire catalog. Memoizing the visible display projection remains a separate follow-up.

Recent uses CompanionListHold for the whole Home TAB session. Activity/status/text changes update in place, newcomers append after held peers, helpers stay under their own parent, and removed peers disappear. A tab exit, scope/sort change or .background ends the hold. Temporary .inactive interruptions preserve it. Name/custom and structural Pin/Inactive/active/quiet/idle behavior are unchanged. Scope/sort/generation stamps reject callbacks from an earlier session. No pull-to-refresh or newcomer cue is added.

Home's shared project-error alert stays mounted, does not present over a pushed page, and clears on pop because the Project page already showed it inline. Project-page error behavior is unchanged from main.

DEBUG-only Bool Environment input enables actual Home child counters; it is false elsewhere and absent from Release. Counters cover the owner, the expensive input projection/content/scope/attention/layout/header/quiet, actual rows/menu children, banner, app-update links, chips, linked rows and Dispatcher content. The finished-row independent60s TimelineView label tick is explicitly excluded. No scroll object or geometry is used to enable counting.
All ForEach loops keep main's original row identities.

Tests and split:
- The hidden-Dispatch test still requires zero expensive work across100 accepted streamed chunks in ten rendered batches, a hidden host update, and a fresh rendered title/status on return.
- The NEW `testPushedHomeKeepsLayoutStableAcross100RenderedChunksWithinSnapshotBudgetAndReturnsFresh` covers the narrower layout/content/header/quiet/snapshot construction contract across100 rendered chunks, snapshot/push cost, retained scope/session and fresh first-pop status. It does not stand in for #557's all-row/per-event regression.
- Frozen-action authority, inactive/background lifecycle, Recent/new/removed peers, sort/scope resets and Pin/idle moves remain covered. The alphabetical test waits for an actual alphabetical content render before switching back to Recent.
- The strict pushed-row method retains the approved setup change: baseline after native
  navigation and lazy realisation settle. Within a failing5s timeout, transition completion
  and two unchanged row/menu samples at least250ms apart are required. No chunks arrive
  before this baseline, and every zero-work assertion remains unchanged. For the anchor
  split, the SHARED fixture mount wait returns from `anchor != nil` to `scope != nil`;
  the pushed method itself is byte-identical. The original anchor method moves byte-intact
  to #567's Draft branch with its failing evidence, not a weakened replacement.
- Existing AgentRow/AgentTree/shared-menu/linked/ProjectPage/LargeCatalog checks remain in the manifest. A real UI edge swipe checks title/back label/nonblank content before and after; mid-gesture recording is visual evidence only.

Original failed bundles and the deinit crash evidence remain retained. No CPU-percentage, battery or installed-device improvement is inferred from hosted counters alone.

#558 remains Draft until independent static review and exact-head proof. The clean166284ca
build and deinit/policy gates passed. Strict pushed work passed, but the original anchor
method failed before restoration because no non-summary bookmark arrived. The hard stop
is honored: all anchor code is removed from #558, with the strict method preserved in #567.

Anchor history, not shipped behavior: the77d1 logging diagnostic showed double safe-area
subtraction and transient large-title/tab-bar insets, with160pt/202pt return errors.
QA's source diagnosis of166284ca found that nil-bookmark first mount waits≥200ms then
scrolls to summary, potentially overriding the test's intervening scroll. Short-circuiting
nil-bookmark resume is the next starting point in #567, not a validated fix. Pixel restore
and cross-bar-state behavior remain unproven; no fourth anchor round occurs in #558.

The73707b4e live-visible comparison failed: every stream batch caused four owner/content/
layout/input constructions,96 headers and328 scope evaluations; main was steadily3/72/246
(visible batch0 four/96/328). The77d1 correction removes conversation activity and Wake/
Terminal from the live owner projection; they are captured only on push. Live Dispatcher
activity stays in its native leaf, and native menu values retain their live guards. The
logging diagnostic improved nine visible batches and every outside-scope batch to main,
but visible batch1 still failed. No performance PASS is credited before final clean2x/main
and2x/head measurements, with each batch meeting the approved bar and inputs≤owner.

Dispatcher content equality covers its displayed agent/host/tag/detail, excluding the
execution closure that retains Root State storage and resolves live Store state. Temporary
DEBUG row-menu attribution splits modifier/native/items/terminal alongside aggregate counts.

LargeCatalog's test is unchanged. Its explicit DEBUG observer constructs the same pure
linked-state menu value factory inside real Home, once per header when the hook is set,
without history/Wake/Terminal work. This covers menu VALUE/authority behavior, not native
popup presentation. #564 remains an unimplemented popup-coverage gap; normal hooks are nil.


#567 / Draft #568 — unvalidated scroll restoration

Rebased onto main `ffcf13e8`, which includes #551/#558/#570. The installed/merged
behavior still starts at the top on tab return. This Draft restores the preserved
public ScrollGeometry / ScrollPosition experiment; no runtime PASS is claimed.

Source diagnosis A is fixed provisionally: resume enables capture but returns
immediately when there is no valid bookmark. A fresh List already starts at the top;
it must not schedule the old delayed summary scroll that can undo a user's scroll.
The original 29-line anchor method remains byte-intact, including its 8pt tolerance,
real-row containment, same-owner/scope and no-silent-top-reset checks. All eight main
HomeVisibility method bodies are also unchanged. Its shared fixture waits for the
anchor probe instead of only the scope binding; this setup change is disclosed.

With a saved bookmark, full Home-specific ForEach data identities allow lazy row
realisation. One public scroll geometry source and row frames in `.scrollView` space
feed the viewport. After stable geometry, identity scrolling realises the row; at most
two measured pixel corrections finish or cancel within a bounded generation-checked
handshake. Departure and user interaction cancel it. No UIKit introspection or fixed
pixel compensation ships. The anchor owns only value state; bookkeeping is not
observable and does not notify Home for every scrolling pixel.

Historical evidence: the old generic-frame implementation double-subtracted safe
areas and returned 160pt/202pt away while bars changed. The public two-phase version
then failed before restoration because the delayed nil-bookmark scroll prevented a
non-summary capture. The nil fix addresses that starting defect only; pixel accuracy
and correctness across different saved/restored bar states remain unproven. A bounded
logging-only anchor diagnostic comes before the clean strict/live/broad proof. The
original test is the contract, with no retry or tolerance change. The live measurement
must remain at or below current main's per-batch cost, twice per side.
