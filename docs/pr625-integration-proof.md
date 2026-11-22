# Retry pill integration and proof boundaries

The product slice from `af7bb4bc05bb3eafc63d3f35f7095488d571ddbb` is merged with
main `86f78daeeda80fdcd70b5c7effafff51b4592f88`. The integration keeps main's
fixtures, selective planning, eight iPhone lanes, iPad selection policy and
required checks. It changes neither Retry routing nor the UUID-owned per-host
latch. No optional CI optimization is included.

## Eligible original evidence

Original candidate run `44872012823` executed on af7bb4bc, before this integration.
Its cancelled aggregate does not erase completed first attempts:

| Original proof | Observed first result |
| --- | --- |
| iPhone Retry geometry, default / accessibility XXXL | PASS, 5.720 / 5.629 seconds |
| iPad Retry geometry, default / accessibility XXXL | PASS, 5.758 / 7.053 seconds |
| Three mounted Retry latch methods | PASS once each on both devices |
| Three OfflineBanner native methods | PASS once each |
| Four NeedsYouOffline native methods | PASS once each |
| Three HomeDesktopScope native methods | Zero starts in the cancelled original lane |

The mounted latch tests exercise the real banner callback and held reconnect
service, not a physical touch. The native single-offline test touches Retry and
checks its label and minimum target; it does not assert the reconnect service's
call count. NeedsYou cases check per-host/combined identity and progress state.
No physical VoiceOver session is claimed.

The saved original render set directly shows enabled Home and Needs you in
light, dark, Catppuccin Latte, Catppuccin Mocha and accessibility XXXL light.
One mounted light/default screenshot shows actual disabled Retry. These images
are evidence of those exact states, not a numerical contrast matrix or a pressed
state. Original shown/hidden geometry compares only the candidate against itself;
it is not baseline fail-before. The old PR body attributes a pair source review,
but an attributable canonical reviewer receipt was not recovered.

## Composed test-only proof

The two existing hosted geometry method identities now cover all five variants:
light, dark, Latte and Mocha at the standard size, and XXXL light. Each uses the
same real mounted banner, fixture, window, OCR and unchanged geometry oracle for
the candidate and the exact original fee5cd21 bordered-label/style expression.
A DEBUG-only opt-in selects that baseline expression. Release retains the
candidate expression and no baseline selector or observer.

Both renders must have finite, nonempty geometry, a recognized Retry label
inside the painted component, and a painted surface enclosing that label. The
candidate must pass the complete original oracle. The baseline must fail an
explicit size/aspect/card-clearance criterion from that same oracle. A missing
render or failed label recognition cannot supply fail-before credit. Shown and
hidden captures must preserve the control and card frames within each style;
style changes may legitimately resize the card.

For each variant, the mounted production callback acquires one real reconnect
latch. A DEBUG observer reads the Button's actual enabled environment without
overriding it. The test requires one service call, one held continuation, the
real disabled predicate and `isEnabled == false`. It saves the actual disabled
render, recognizes Retry, preserves its target/card frames, and requires changed
pixels within that target compared with the enabled render. Calling the stale
callback again must leave one call and one continuation. Releasing the attempt
must restore enabled state and leave no pending work before baseline capture.
These checks establish actual state and render differences, not a contrast-ratio
threshold or native activation result. Attachments and emitted `RETRY_GEOMETRY`,
`RETRY_STATE` and `RETRY_PAIR` records are required from hosted execution before
claiming these new checks passed.

## Pressed-state limitation

Pressed contrast remains **unobserved**. The installed Xcode 26.0.1 (17A400)
public XCUIAutomation `XCUIScreen` interface supplies screenshots, with no public
recording API found in its headers or XCTest interfaces. No checked-in capture
helper retains a real held Retry touch. The original runner used a different SDK;
this inspection makes no universal claim about every SDK. A screenshot after a
blocking press represents release, and callback activation does not represent
`ButtonStyle.Configuration.isPressed`. There is no synthetic pressed flag,
private capture API, deliberate failure or speculative concurrent XCTest query.
Landing disposition must keep this gap distinct from geometry, latch and native
tap outcomes.

## One supported exact-head hosted route

Independent routing receipt `61bb6a954956a0308e05494b3c05bc807ddd6d29`
(11,770 bytes, SHA-256
`3d9e8c3884b8773e0c27966c9aedc3792a82ac2fb1ed80eab26ef2c960bf64dc`)
materialized this integration on current main's actual selector. Ordinary broad
selection misses nine of the ten OfflineBanner/NeedsYouOffline/HomeDesktopScope
native cases and does not select iPad. A selected-method verifier cannot detect
cases that were never selected. The standalone CoreGraphics control is not
invoked by that workflow; its local result is separate.

The existing `ci:full` policy before one ordinary reviewed PR update is the
supported topic-head route covering all three never-started HomeDesktopScope
cases, all ten native cases and hosted tests on both devices. There is no custom
selector input; a scheduled run is on default main, not this topic. No selector,
workflow or dispatch changes are introduced. The integration publisher owns that
single submission, actual manifest verification, first outcomes, remaining state
and contrast disposition, and landing. Local syntax/source/CoreGraphics controls
are not hosted, native, rendering or integrated runtime acceptance.

## Debug compiler correction

The first composed head bcc31ae40 failed hosted Debug Build for testing in job
137315864152: the compiler could not type-check the observation modifier chain
at RecoveryStatusView line 205. The correction places that complete Debug chain
in an opaque-result helper. Its order is unchanged: styled button, enabled probe,
hide opacity, Retry geometry observation, disabled predicate, accessibility label
and identifier. The enabled probe remains inside the outer disabled modifier.
The original Release expression and the entire paired/latch test file are kept.
Expanding the helper recovers the complete prior Debug source modulo comments
and whitespace; removing Debug recovers the prior Release source.

A resource-admitted, ordinary-FIFO targeted type-check used the installed real
SwiftUI/Observation simulator SDK (Xcode 26.0.1, Swift 6.2, iOS 26.0 target). The
exact CompactBanner/DesktopBanner/probe/style slice from bcc reproduced the same
compiler diagnostic, located on the banner body in that slice. The corrected
Debug slice and corrected Release slice both type-checked successfully under the
same conditions. Only app-specific Store/host/notice/palette/glass/probe
implementations were stand-ins. This is compiler-slice evidence, not a full app
build, rendering result or native execution; the hosted runner uses Xcode 26.5.
No extra CI submission or simulator execution was made. The existing paired,
state and pressed-contrast acceptance boundaries above remain unchanged.
