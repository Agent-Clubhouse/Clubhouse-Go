# Header contrast after the #548 recurrence

Issue #534 records a text-only device recurrence on build `77b24899` after
#548. The name capsule and trailing action capsule appeared light with light
foregrounds. The platform cause remains unproven; telemetry is not rendered
color evidence. The parked #620 source has the same header renderer as this
main baseline and supplies no contrast fix.

This correction reuses the unlanded `3490dc977` fallback: only the two toolbar
capsules draw an opaque palette card, hairline and shadow. Their content stays
outside glass rendering, while #548's palette color-scheme pin remains. Generic
card glass, native bar controls, avatars, typography, frames, targets, details
expansion, context sheet and action handlers are unchanged. This is a deliberate
opaque-card fallback; a device fix cannot be inferred from source alone.

`CompanionGlassSchemeUITests` retains its three original theme identities and
adds nine cases. Bright-wash dark, Mocha and Latte each cover connected,
synchronizing and offline. Three additional bright-wash cases request a Light
UIKit window independently of the dark app palette. A DEBUG-only fixture probe
reads the mounted palette, actual Store connection, view/window appearance and
UIScreen traits. The independent cases require both window and screen to report
Light; an unavailable or dark screen fails rather than claiming the requested
flag established system appearance. The fixture does not change simulator or
phone settings. Its non-flag path keeps the original theme/appearance behavior.

Each case OCR-recognizes the actual `Header worker` text inside the native
identity frame. Pixel contrast is measured separately in that text box, the
ellipsis center and the context-ring center. The avatar, chevron and other
controls cannot compensate for unreadable name text. The decoded RGBA sampler
requires the entire region, a median fill on the expected palette side and at
least 4.5:1 measured ink-core contrast. It does not clip missing regions. Real
enabled states are reported; no test overrides disabled controls. The connected
independent case also taps the actual identity twice and opens the actual
conversation menu without invoking a mutation. Launch attempts and the existing
allowance remain unchanged. Evidence emitted by these tests is numerical text;
no screenshot attachments are added by this class.

Local checks type-check the complete UI test source against real iOS 26.0
XCTest/UIKit/Vision APIs with an explicit unchanged-base stand-in, and the actual
identity/card/probe slices against SwiftUI/UIKit with explicit app-type stand-ins.
They are not a full app build or rendering. Eleven controls execute the exact
RGBA/statistics helper with CoreGraphics synthetic images: readable dark/light,
unreadable white-on-white, outside-region contrast, blank/one-hot-pixel regions,
and unusable regions/scales. A first harness had top-level visibility errors;
putting the harness variables in a local function fixed the harness without a
product-source change. Synthetic ratios are not header measurements.

The initial compiler/control proof had no approved native lane. The PR landing
assignment subsequently authorized a fresh, private iOS 26.0 simulator and
xcodebuild-managed test installs. The PR records those actual contrast/visual
outcomes, original failures and main controls separately from compiler checks.
The owner deletes only that fresh simulator and private derived data afterward;
result bundles and text metrics remain private. No user's device app is installed
or replaced, and no release is authorized by these tests.

An AX target measured as 43.99999999999999 points needs one floating-point step
to represent its requested 44 points. The target checks permit that single ULP,
not a pixel or subpoint allowance; 43.99 points still fails the control.

The ordinary PR plan may omit this contrast class. Its actual manifest must be
read and local method inventory supplies omitted-case proof; CI selection is not
changed here. iOS 26.0 results do not establish an iOS 27 device cure or reproduce
the reported white capsules. Physical Light-system/dark-app confirmation remains
separate. Issue, PR and chat evidence stays text-only. No screenshots are
published or #620/#629 source changed here.
