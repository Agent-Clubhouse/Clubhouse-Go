# Routed Copy/Paste keyboard exit

This test-only correction is based on closed job `137205374336`, head `1b46f7b45`,
artifact `14755232985` (`test-results-0`). Its original three attempts failed at
the keyboard-dismissal assertion in 62.806, 64.312 and 64.284 seconds. Both raw-value
assertions and Back were unreached; those failures remain failures.

The saved River hierarchies show a visible transcript marker approximately
`(0,149.3,402,59.3)` after Paste expands the composer. The old reported drag origin
`(201,179)` overlaps Latest at `(153.7,156.7,94.7,44)`. This is frame-overlap evidence,
not identification of the actual touch recipient or recognizer. The failure-time
native snapshots contain the complete expected 367-byte composer value with keyboard
focus in all three attempts. They corroborate late Paste contents, not the unreached
pre-Back assertion or draft restoration.

Only this Copy/Paste case uses the new exit. A fresh, complete SDK snapshot must have
one River navigation bar, visible transcript marker, composer and keyboard. The point
is in the leading 8-point gutter, 24 points below the usable top. It stays in the first
48 points while the observed viewport shrinks from about 210 to 59 points. Finite
geometry, the existing greater-than-48-point height requirement, window bounds and
4-point clearance from snapshot buttons, links, text and other controls are checked
before one real tap. The app already dismisses editing on blank transcript taps;
KeyboardDismissalUITests use the same leading-gutter convention. Decorative images
are not a claim about hit testing, and a snapshot does not prove an identical layout
revision at touch delivery.

Real Copy and system Paste, launch flags, the shared drag helper and all its other
callers remain unchanged. The five-second keyboard predicate and both five-second
whole-raw-value predicates remain. There is no rescue tap, new gesture retry,
allowance increase, assistive-mode substitution, direct clipboard read or injected
draft value. No package/product, coverage-floor or routing change is included.

Source validation uses the actual extracted CoreGraphics point function against six
saved AX layouts and adverse geometry, plus Swift frontend parsing. These are Mac
source controls, not an iOS SDK typecheck or native UI execution. Two frames decoded
read-only from the original recording corroborate the River layout and expanded draft;
their movie presentation times are not asserted to be exact SDK-event timestamps.
The parent owns exact-head hosted execution of the tap, keyboard disappearance,
full raw completion before Back, and exact restoration after reopening.
