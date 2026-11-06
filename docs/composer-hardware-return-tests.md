# Composer hardware Return test plan (#309)

The regression is absence of unmodified hardware Return submission in the focused vertical TextField. Keep the
SwiftUI editor and its native identity; do not equate text insertion with hardware key delivery.

Focused hosted suite: `ClubhouseGoTests/CompanionComposerReturnTests`.

- Invoke the actual advertised `UIKeyCommand` responder action on the hosted `CompanionConversationComposer`.
  Expect one synthetic service request, no inserted newline, retained focus/input, and store pending protection.
- Return completes a named slash prefix first. Bare `/` and fully spelled commands submit (existing `returnPicks`
  does not select these). Shift Return inserts a native newline even in a slash prefix and replaces selections.
- Direct native multiline insertion remains text; software Return retains existing slash completion.
- Empty/whitespace, offline, unsupported, resync and pending sends preserve the draft without dispatch.
- Actual UIKit marked text suppresses command advertisement and action validation; cached actions must not
  confirm it. Cached unfocused or uneditable actions also do nothing. Other text views remain unchanged.
- The native hook handles no Command Return chord. Existing SwiftUI Command Return and touch Send remain on
  their shared guarded store path. Retention is covered here; parent owns actual keyboard/touch UI regression.

Parent coordinates serial bounded simulator validation. No build/test jobs run by the implementation helper.
Suggested validation after building test products, using the parent's simulator and derived data:

```sh
xcodebuild test-without-building -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<owned-simulator>' -derivedDataPath <parent-derived-data> \
  -only-testing:ClubhouseGoTests/CompanionComposerReturnTests \
  -only-testing:ClubhouseGoTests/CompanionComposerPasteTests \
  -only-testing:ClubhouseGoTests/CompanionComposerIsolationTests \
  -parallel-testing-enabled NO
```

Also run existing `CompanionSlashCommandUITests` and `CompanionComposerPasteUITests`, parent's hardware Return
UI regression, and normal CI validation. Synthetic actions verify the hook/store contract; real iPhone Mirroring
event routing and real IME confirmation still need observation. No live sends, installs, uploads or device control.
