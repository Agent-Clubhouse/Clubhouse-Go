# Sample the native header without repeatedly traversing the transcript

The closed f7a full run spent379.594s in fifteen HeaderReflow attempts: first
attempts129.433s and completed retries250.161s. Thirteen attempts reached their
summary, with17..35 samples each (351total), all missing0/violations0, then failed
the unchanged100-sample minimum. The other two push/pop attempts failed before
summary when the required Back button was absent. They remain distinct native
failures; a faster query is not a repair for a missing Back action.

The original sampler has **no deliberate sleep between samples**. Its real14s
window includes the two gestures/background or push/pop disturbances and native
SDK idling/query work. Raw logs show successive snapshot-related Find Application
records and gesture idle waits, but no precise SDK snapshot-return timestamps.
Their spacing cannot be relabeled as removable sleep or isolated query duration.
The exact original log is job137026198361 /1026426B /
SHA25615967b39633c7dca2ce54fb20af5138d7e57ff836a41a549b4f27045f77cd49c.

Even an impossible zero-overhead first-pass implementation must retain at least
five14s windows. Thus the old379.594s cost could supply **at most309.594s** against
the modeled607.161s aggregate gap (50.99%), before launches, disturbances, captures
and auditing. Removing only the old completed retries would be250.161s (41.20%);
no retry removal is credited. This change alone cannot establish the60m target.
The observation window itself is required work, not an optimization opportunity.

The real product places the identity and actions in principal/trailing ToolbarItems
in CompanionConversationView. The fixture's leading menu is a leading ToolbarItem
in its single NavigationStack; pushed cases use its native Back button. The
correction snapshots the **unique navigation-bar element** once per sample and
runs the exact original immutable-snapshot walker. Identity, actions and leading
frames still come from that one snapshot, with screen-coordinate geometry and
unchanged comparisons. No element-frame queries are combined across moments;
there is no cached sample, averaging, rounding, slower cadence or stable-frame
filter. A failed/ambiguous bar query is a missing sample under the existing rule.

After the original window, attachments and geometry assertions, an additional
full-app snapshot audits scope. It requires one bar, rejects matching items outside
it, and compares the original whole-tree walk with its navigation subtree using
**the same captured hierarchy and exact frames**. This adds a conservative gate;
it does not claim sequential full-app and bar SDK queries are the same AX revision.
It is an end-of-window scope audit, not a dump of every sampled hierarchy.
A transient that is never captured still cannot be diagnosed; the preserved sample
minimum/window and actual capture cadence remain required hosted evidence.

All five public test bodies, launches, stream fixture,14s window,100sample minimum,
two disturbance schedules,1s missing-item grace, geometry inequalities, attachments
and assertions are unchanged. The source fixture streams for20s; no pre-window
comparison delays observation. New aggregate telemetry separates snapshot query
seconds, local walk seconds, query count and the one post-window scope-audit cost.
It makes no claimed comparison with unmeasured old query return times.

A cheap Mac control compiles the actual extracted walker, scope audit and original
geometry-problem block with CoreGraphics and stand-in immutable snapshots. It
checks menu/Back same-tree equality, missing/ambiguous/outside rejection, all four
original geometric problems and a one-sample transient between100good snapshots.
It does not execute XCTest, a simulator, an app or an accessibility query. Linux
Plan skips only that new Mac-only control; all existing Python ownership/model
controls still run. DEBUG frontend parsing is syntax-only, not an SDK typecheck.

The next necessary composed hosted run must show actual query counts/costs,
all five first outcomes and retries,100samples within the original window,
same-tree scope audit, realized method order and time to the first warning. The
two prior Back-action failures and any newly reached geometry failures remain red.
Hosted performance and exact native scope/query behavior are still unaccepted.
