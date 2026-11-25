# Header width during native toolbar transitions

Refs #554. The header requested a fixed principal width derived from asynchronously
sampled native bar geometry. While that sample still describes a wider bar, UIKit
can already propose a narrower title slot. A fixed SwiftUI frame ignores that
proposal, leaving the name and side items competing for more space than the bar.
Streaming body updates can reevaluate this state; no name text change is required.

The principal now treats the measured width as its ideal and maximum, with the
existing 44pt minimum. It accepts the native slot's narrower proposal immediately;
the unchanged side measurements still establish the balanced settled width. This
uses normal tail truncation rather than a clip, mask, smaller font or delayed
visibility. Back, the trailing action targets, name accessibility and expansion,
theme cards, side reservations and measurement lifecycle remain unchanged. The
existing overflow telemetry still describes requested reservations separately from
actual observed item extents; a stale requested sum is not proof of visible clipping.

The hosted regression uses the actual identity button and production width modifier.
On the mechanically equivalent fixed-frame baseline, all five constrained proposals
failed: a 706pt request returned 706pt for 64/143/190pt slots; a 190pt request returned
190pt for 64/143pt slots. Its wide-slot control preserves the requested balanced width,
and its target-height assertion preserves 44pt. The exact same test is used after
the fix. This reproduces the layout mechanism, not the user's unavailable iOS 27
session or a particular UIKit transition on that device.

Local proof uses a newly created private simulator, the header UI/visual/contrast
and streaming frame-sampling suites, and the full Swift package suite. Actual results
and original failures are recorded in the PR and private evidence. Existing native
geometry tolerances, streaming window/sample count, gestures and deadlines are not
relaxed. No composer/footer, selector, workflow, capability or routing code changes.
