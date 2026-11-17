Home rendering and Recent sessions (Refs #528, Refs #549)

Home's State owner stays in its Tab and NavigationStack. The expensive List unmounts ONLY when the Home TAB is deselected. The Clubhouse title, toolbar, project-error alert and pending sheets stay on the owner. Root badges, connection reconciliation and Dispatch remain live.

User-approved shipping limit: Returning to Home from another tab scrolls to the top; scroll restore follows in #557. There is no ScrollViewReader, anchor owner, row marker, geometry recording or partial restore in this change. Native pushed-route transitions keep the existing List mounted. This scroll-reset behavior is an explicit accepted tradeoff, not a claim that native scroll position is preserved.

Before constructing pushed Home content, a lazy non-published render session captures display values once: hosts/catalog, attention, layout, finished runs, row context, palette/helper labels, status/activity and menu presentation. All Home value copies consult that session, including old lazy List closures. The Equatable content boundary avoids per-stream layout/content construction; descendants receive optional captured values. Nil is the existing live path for non-Home callers. Ordinary labels/tree rows use value agents and Preferences. The frozen Dispatcher row receives its captured execution callback explicitly; only the live wrapper reads the Environment action.

This does NOT prove that every pushed child remains idle. #557 preserves the original strict regression byte-for-byte: rows/menus still have a one-shot first-batch rebuild, and host/catalog events can cause an extra content/child construction. A linked case also shows content23→24. Those failures are disclosed and deferred; no complete pushed-row zero-work claim is made.

Settings/Wake/Terminal menu queries receive frozen display values. Activation rechecks the existing live Store predicates, identity and capabilities. Existing Root open-agent/Review handles write mounted State, and new live Environment handles replace the snapshot on pop. Display never authorizes an action. The render session's nonisolated deinit retains actions/snapshot inside a real MainActor Task, avoiding the reproduced isolated-deinit StateObject teardown crash; exact fields and body are policy-gated. No task handle is stored.

The first pop construction reads current connection/status/permission inputs. Recent ordering persists across push/pop, so Back refreshes text/badges without shuffling peers. One visible content construction computes ONE layout for projects and the animation hold. Header dots reuse computed group activity. Entering a push captures exactly one display snapshot, budgeted to at most two content constructions. Per-agent predicate capture covers displayed scope/groups, visible helpers/open folds, attention and Dispatchers, not the entire catalog. Memoizing the visible display projection remains a separate follow-up.

Recent uses CompanionListHold for the whole Home TAB session. Activity/status/text changes update in place, newcomers append after held peers, helpers stay under their own parent, and removed peers disappear. A tab exit, scope/sort change or .background ends the hold. Temporary .inactive interruptions preserve it. Name/custom and structural Pin/Inactive/active/quiet/idle behavior are unchanged. Scope/sort/generation stamps reject callbacks from an earlier session. No pull-to-refresh or newcomer cue is added.

Home's shared project-error alert stays mounted, does not present over a pushed page, and clears on pop because the Project page already showed it inline. Project-page error behavior is unchanged from main.

DEBUG-only Bool Environment input enables actual Home child counters; it is false elsewhere and absent from Release. Counters cover content/scope/attention/layout/header/quiet, actual rows/menu children, banner, app-update links, chips, linked rows and Dispatcher content. The finished-row independent60s TimelineView label tick is explicitly excluded. No scroll object or geometry is used to enable counting.

Tests and split:
- The hidden-Dispatch test still requires zero expensive work across100 accepted streamed chunks in ten rendered batches, a hidden host update, and a fresh rendered title/status on return.
- The NEW `testPushedHomeKeepsLayoutStableAcross100RenderedChunksWithinSnapshotBudgetAndReturnsFresh` covers the narrower layout/content/header/quiet/snapshot construction contract across100 rendered chunks, snapshot/push cost, retained scope/session and fresh first-pop status. It does not stand in for #557's all-row/per-event regression.
- Frozen-action authority, inactive/background lifecycle, Recent/new/removed peers, sort/scope resets and Pin/idle moves remain covered. The alphabetical test waits for an actual alphabetical content render before switching back to Recent.
- The original pushed-row and anchor methods move byte-for-byte, with their shared fixture, to #557's draft PR. Zero-counter,8pt alignment, real-row containment and no-top-reset assertions remain intact there. No skip or weakened version is substituted.
- Existing AgentRow/AgentTree/shared-menu/linked/ProjectPage/LargeCatalog checks remain in the manifest. A real UI edge swipe checks title/back label/nonblank content before and after; mid-gesture recording is visual evidence only.

Original failed bundles and the deinit crash evidence remain retained. No CPU-percentage, battery or installed-device improvement is inferred from hosted counters alone.
