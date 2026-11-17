DRAFT #567 — unvalidated anchor experiment, split from #558 after the agreed hard stop.

The original strict anchor method is preserved byte-intact. At166284ca it failed before
restoration because no non-summary bookmark arrived. QA source diagnosis: nil-bookmark
first mount still starts a delayed settle/scroll-to-summary, which can override a scroll
that occurs in the meantime. Short-circuiting nil-bookmark resume is a proposed next
starting point, NOT applied or validated here. Pixel restoration and cross-bar-state
correctness remain unproven. No run or PASS is credited to this Draft.

Home rendering and Recent sessions (Refs #528, Refs #549)

Home's State owner stays in its Tab and NavigationStack. The expensive List unmounts ONLY when the Home TAB is deselected. The Clubhouse title, toolbar, project-error alert and pending sheets stay on the owner. Root badges, connection reconciliation and Dispatch remain live.

Main #551 ships with this user-approved limit until #557 is proved and merged: Returning to Home from another tab scrolls to the top; scroll restore follows in #557. This follow-up proposes public ScrollViewReader restoration to the first visible full-target row and its saved fractional alignment. Root suspends the value-only anchor at the navigation write, before departure geometry; a weak, generation-checked main-queue request runs after List layout. Native pushed-route transitions retain the existing List. A removed or folded-away target explicitly falls back to the summary. No UIKit introspection ships in the product.

Before constructing pushed Home content, a lazy non-published render session captures display values once: hosts/catalog, attention, layout, finished runs, row context, palette/helper labels, status/activity and menu presentation. All Home value copies consult that session, including old lazy List closures. The Equatable content boundary avoids per-stream layout/content construction; descendants receive optional captured values. Nil is the existing live path for non-Home callers. Ordinary labels/tree rows use value agents and Preferences. The frozen Dispatcher row receives its captured execution callback explicitly; only the live wrapper reads the Environment action.

The initial #557 diagnostics reproduced two distinct failures: new lazy row instances during the native push, and residual host/catalog-triggered work after freezing. The owner now projects plain host/catalog/attention and per-project display values before the lazy Content/List/ForEach builders, including while Home is live; while pushed it reads the existing snapshot only. The new contentInputs counter measures that projection, and remains in every strict zero-work comparison. It does not build a live per-agent permission snapshot. Settings/Wake/Terminal per-agent presentation capture remains once per push. The agent-row modifier short-circuits its existence check when Details guarantees a menu; Wake choices and Terminal availability then belong to the native menu-content child, preserving the same items and action guards without subscribing the row to those Store queries. No final runtime PASS is claimed until the exact-head proof closes.

Settings/Wake/Terminal menu queries receive frozen display values. Activation rechecks the existing live Store predicates, identity and capabilities. Existing Root open-agent/Review handles write mounted State, and new live Environment handles replace the snapshot on pop. Display never authorizes an action. The render session's nonisolated deinit retains actions/snapshot inside a real MainActor Task, avoiding the reproduced isolated-deinit StateObject teardown crash; exact fields and body are policy-gated. No task handle is stored.

The first pop construction reads current connection/status/permission inputs. Recent ordering persists across push/pop, so Back refreshes text/badges without shuffling peers. One visible owner construction computes ONE layout and passes that value to content, projects and the animation hold. The content boundary never evaluates the live conversation-activity projection; while pushed the owner reads the captured layout from the render session. Header dots reuse computed group activity. Entering a push captures exactly one display snapshot, budgeted to at most two content constructions. Per-agent predicate capture covers displayed scope/groups, visible helpers/open folds, attention and Dispatchers, not the entire catalog. Memoizing the visible display projection remains a separate follow-up.

Recent uses CompanionListHold for the whole Home TAB session. Activity/status/text changes update in place, newcomers append after held peers, helpers stay under their own parent, and removed peers disappear. A tab exit, scope/sort change or .background ends the hold. Temporary .inactive interruptions preserve it. Name/custom and structural Pin/Inactive/active/quiet/idle behavior are unchanged. Scope/sort/generation stamps reject callbacks from an earlier session. No pull-to-refresh or newcomer cue is added.

Home's shared project-error alert stays mounted, does not present over a pushed page, and clears on pop because the Project page already showed it inline. Project-page error behavior is unchanged from main.

DEBUG-only Bool Environment input enables actual Home child counters; it is false elsewhere and absent from Release. Counters cover the owner, the expensive input projection/content/scope/attention/layout/header/quiet, actual rows/menu children, banner, app-update links, chips, linked rows and Dispatcher content. The finished-row independent60s TimelineView label tick is explicitly excluded. No scroll object or geometry is used to enable counting. Home-only ForEach data IDs use the full CompanionHomeAnchor enum, so List can resolve unrealised rows; non-Home loops preserve their original data IDs. Project sections use the catalog's emitted-unique CompanionProjectTarget, rather than assuming malformed duplicate link IDs cannot occur. Quiet-fold string keys retain their existing behavior; malformed duplicate link IDs can still make a quiet restore ambiguous. Attention/project/cached occurrences of the same target have distinct IDs.

Tests and split:
- The hidden-Dispatch test still requires zero expensive work across100 accepted streamed chunks in ten rendered batches, a hidden host update, and a fresh rendered title/status on return.
- The NEW `testPushedHomeKeepsLayoutStableAcross100RenderedChunksWithinSnapshotBudgetAndReturnsFresh` covers the narrower layout/content/header/quiet/snapshot construction contract across100 rendered chunks, snapshot/push cost, retained scope/session and fresh first-pop status. It does not stand in for #557's all-row/per-event regression.
- Frozen-action authority, inactive/background lifecycle, Recent/new/removed peers, sort/scope resets and Pin/idle moves remain covered. The alphabetical test waits for an actual alphabetical content render before switching back to Recent.
- The anchor method remains byte-identical to the original preserved failure. The pushed-row method has one explicitly approved setup change: baseline after native navigation and lazy realisation settle. Within a failing 5s timeout, transition completion and two unchanged row/menu samples at least250ms apart are required. The stream sequence must be unchanged across the wait; no chunk is delivered until after the baseline. All original zero-counter comparisons,100-chunk checks, live-return assertions,8pt alignment, real-row containment and no-top-reset assertions remain. The exact test diff is disclosed in the PR; it is no longer claimed byte-identical. No retries, skip or weakened replacement is introduced.
- Existing AgentRow/AgentTree/shared-menu/linked/ProjectPage/LargeCatalog checks remain in the manifest. A real UI edge swipe checks title/back label/nonblank content before and after; mid-gesture recording is visual evidence only.

Original failed bundles and the deinit crash evidence remain retained. No CPU-percentage, battery or installed-device improvement is inferred from hosted counters alone.

Follow-up #557 remains DRAFT pending independent static review and exact-head guarded proof. Historical failing bundles are retained; the original #551 top-on-tab-return release-note disclosure remains applicable to installed main until this follow-up lands.

Uncredited visible-Home comparison at 73707b4e failed: both visible-dispatcher and loaded-outside-scope streams caused four owner/content/layout/input projections,96 headers and328 scope evaluations per ten-chunk batch. Main67b8e5b8 was three/72/246 steadily (visible batch0 was four/96/328). Idle high-level work was zero. The correction removes conversation activity and Wake/Terminal predicates from the live owner projection. Those are captured only on push; ordinary live menus/Dispatcher activity keep their leaf-level reads and nil display inputs, as on main. Concrete native-menu and live-Dispatcher children own those subscriptions, so the frozen parent does not inherit a previous live read. Labels, availability rules and execution guards are unchanged. Visible-Home baseline-wide invalidation remains separately tracked on #528; no new-head performance PASS is claimed before repeating the identical measurement.

The same73707b4e proof passed the strict pushed rows/menus/event test, but anchor restoration failed its original8pt contract:160pt error after tab return and about202pt after push/pop, with restoring left active. The next uncredited diagnostic records the List geometry, safe areas, native content/adjusted insets, offsets, requested id/alignment and actual target frame; no hard-coded offset or tolerance change is proposed.

### #557 measured restoration correction

The logging-only 77d1cfaa diagnostic reproduced the original 8pt assertion failure:
row y251.667 returned at411.667 (then453.333 after a push). Native List geometry
showed that the generic SwiftUI frame already excluded the title/tab bars; applying
safe-area insets again doubled them. The identity scroll also landed inconsistently
while the large title and tab-bar insets changed. The correction uses one public
ScrollGeometry source and row frames in the nearest `.scrollView` space. After eight
unchanged geometry samples (25ms apart), it realises the saved data identity, then
corrects the measured delta with ScrollPosition, at most twice. The bounded handshake
always completes or cancels within60 samples; departure/user interaction cancels it.
No UIKit introspection or fixed pixel compensation is used. The original anchor
method and8pt assertion remain byte-identical. Runtime proof is pending.

The same diagnostic's visible streaming batch1 still exceeded main (4/96/328 against
3/72/246 owner-content-layout/header/scope); all other batches met main. Logging CPU
is not comparable. Final clean measurement is twice per side, with both head runs
required to meet the approved per-batch main bar. Dispatcher content now equality-gates
its displayed agent/host/tag/detail, excluding its live execution action. Temporary
DEBUG row-menu counters attribute modifier/native/items/terminal work separately.

LargeCatalog's existing hosted test remains unchanged. Its explicit DEBUG observer
constructs the same pure linked-state menu value factory inside real Home, once per
header when the hook is set, without history/Wake/Terminal work. This proves menu
value/authority behavior, not native popup presentation; native popup coverage is
still a gap tracked by#564. Normal Home fixtures leave the hook nil.
