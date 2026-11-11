# TestFlight releases

## Versions and tags

- The app version is `MARKETING_VERSION` in the Xcode project. Apple accepts only numbers (`2.0.0`).
- The build number is the commit count of the archived commit (`git rev-list --count HEAD`), set by
  `scripts/testflight.sh` at archive time. Later commits always get higher build numbers.
- The archive also sets `FRAMEBRIAR_BUILD_SHA` to the full commit, which Info.plist carries as
  `FramebriarBuildSHA`, so feedback reports and telemetry from the build carry `buildSha`.
- Each build sent to Apple comes from a commit with a release tag, following the desktop's convention:
  - A version-bump PR (`chore: bump version to 2.0.0-beta.1 (TestFlight)`).
  - An annotated, signed tag on its merge commit, e.g. `v2.0.0-beta.1`, with the release title as the
    tag message (`git tag -s v2.0.0-beta.1 -m "…"`, then `git push origin v2.0.0-beta.1`).
  - TestFlight betas use `-beta.N`. A build intended for the App Store drops the suffix (`v2.0.0`).

## Steps

1. Merge the version bump, then tag the merge commit as above.
2. Check out the tag and run `scripts/testflight.sh` to archive and export, or `scripts/testflight.sh --upload`
   to send it to App Store Connect. The script refuses a dirty tree or an untagged commit.
3. In App Store Connect, add the processed build to the internal testing group. Export compliance is
   already answered by `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`.

## Next beta — release notes draft

Draft for the next candidate; this does not select a build or authorize an upload, installation,
privacy declaration change or feedback send. Fill in the chosen version/build and desktop version
before copying these notes to TestFlight.

### What's new

- Chat is easier to read: routine activity folds away while keeping sender faces visible. Previous
  and next reply controls, Latest, and remembered reading positions help you move through long chats.
- Dispatcher has its own first tab. Choose your preferred Start screen in Settings.
- Helper presets, Auto provider choices, plan limits and context-window controls appear when your
  desktop supports them. Agent and project icons load through a bounded cache.
- Feedback adds screenshot zoom, four pen colors, opaque redaction, Undo, Clear edits and an
  Include screenshot switch, alongside the existing capture and held-report recovery routes.
- Startup and view-lifetime fixes protect 24 reviewed classes from an iOS 26.0 runtime abort.

### Known limits

- **Do not roll back to an older feedback SDK.** Older versions can lose enrollment binding and held
  state, or send a report under a later enrollment. Follow the [rollback guidance](#unsafe-older-sdk-rollback)
  before any planned downgrade.
- **12 class teardown paths retain actor isolation** to preserve UI safety and remain exposed if the
  affected runtime/release conditions occur. iOS 26.1–26.4 are untested. Simulator controls reproduce
  the abort on 26.0 and pass on the observed 26.5 compiler/runtime pair; that does not establish a
  fixed-version boundary or prove phone safety. See [runtime evidence](isolated-deinit.md).
- Terminal history is bounded; older scrollback may be missing. A disconnected project/worktree
  shell is replaced on reconnect, rather than resumed. Do not use it for work that must survive a
  connection loss.
- Auto provider and quota displays need a matching desktop that advertises those features. Unknown
  or stale quota is not a promise of remaining capacity. Context controls and presets also depend
  on the desktop's advertised support.
- The new icon-reference fetch path needs a desktop that offers icon references. Older desktops
  use legacy inline icons; unavailable or invalid images fall back to initials or other default faces.
- General report diagnostics stay off. Only a deliberately prepared **Diagnostics test report** can
  attach recent transport records. Notes and images may contain private information; review them.
  Reports queued just before the app is suspended can wait until foreground; queued does not mean sent.
- Real-phone shake, screenshot Full-Screen Previews, feedback URLSession delivery and Azure read-back
  still need the user's chosen candidate and deliberate test below. The SDK iPad timeout was explained
  by its harness limit, not a confirmed hang; one passing rerun does not exclude an intermittent stall.
  The separate secure-keyboard flake is unexplained.

Regenerate the class counts from `scripts/isolated-deinit-policy.json` at the chosen candidate head:

```sh
python3 - <<'PY'
import collections, json
with open('scripts/isolated-deinit-policy.json') as f:
    counts = collections.Counter(c['policy'] for c in json.load(f)['classes'].values())
print(f"{counts['arc_only']} ARC-only; {counts['main_actor_task']} deferred MainActor; "
      f"{counts['main_actor'] + counts['generated']} retained isolated")
PY
```

### Phone hand test — highest risk first

For the user, after choosing a candidate to install. Record its version/build, phone/iOS, desktop
version, and the time of any failure. Use a disposable conversation and harmless requests; stop if
typing loses text, the app stalls, or an action affects the wrong agent. Mark unsupported features
or absent test data as **not exercised**, rather than passed. Leave enrollment unchanged during the
main pass. This checklist is not an instruction for an agent to operate a phone.

1. **Reconnect and foreground.** Briefly disconnect and reconnect, then background and return a few
   times, including while opening a chat. Look for recovery without a freeze, duplicate content or
   a stuck connecting state. Record any unusual delay.
2. **Long chat, typing and scrolling.** During a long streamed reply, type a distinctive sentence,
   pause, scroll, show/hide the keyboard and continue typing. Every character must remain in order;
   the keyboard must keep focus and the view must remain responsive. In both Dispatcher and an ordinary
   chat, try an empty and a long conversation: tap transcript text and blank space, drag down to dismiss
   interactively, including blank space near both the top and bottom of empty and short chats. The draft and
   selection must remain intact. On iPhone, dismissing must reveal the tabs so Home and back to Dispatcher work.
   On a real phone with VoiceOver, use the composer's **Dismiss Keyboard** action and two-finger Z scrub while
   editing; after dismissal, the scrub must retain normal Back behavior. With VoiceOver or Switch Control running,
   a labelled **Dismiss Keyboard** button appears beside the composer: reach it from transcript focus and activate it.
   Check the narrowest phone with Interrupt, Attach and Send visible. With a hardware keyboard, Esc must close
   the slash menu first. With Voice Control, try a numbered/grid tap
   on blank transcript space and the composer's named action; verify what spoken commands are available.
3. **Latest and reply jumps.** Read above the bottom while new text arrives: it must not pull you down.
   Tap Latest: reach the actual bottom and resume following. Try previous/next reply repeatedly;
   land on assistant replies or questions, without stopping at routine tool traffic.
4. **Folded activity and faces.** Expand/collapse a run with several senders; check their faces and
   order, and that expansion survives leaving/returning. Failures, approvals and questions must stay
   visible. Known icons should load or fall back cleanly, without disturbing chat.
5. **Tabs and reading position.** Check Dispatcher is first, then change Settings → Start screen and
   check the next normal launch. Restore your preference. Switch tabs and conversations while reading
   mid-history; return to the same text and offset. A process restart need not preserve the bookmark.
6. **Queued messages.** With an agent busy, queue a harmless message. Check queued/pending/delivered
   states across reconnect and foreground; there must be no silent loss, duplicate send or false success.
7. **Approvals and questions.** Use a harmless pending approval and a structured question; answer once
   and check both phone and desktop agree. Long-press the **center of an agent row**, then its **label**
   separately; note which opens the menu, whether the finger target is obscured, and whether it belongs
   to the right agent. Repeat each press and record any press that opens the chat instead of the menu,
   with iOS version and the point used ([investigation #247](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/247)).
   Check agent navigation and Needs you lead to the pending item.
   Open **Wake with a message** a few times: record whether the keyboard and caret appear before
   touching the field ([intermittent autofocus investigation #246](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/246)).
   Then tap the field, type a distinctive harmless sentence and check every character before waking.
   A successful field tap does not count as an autofocus pass.
8. **Terminal.** Open a disposable shell, type a harmless command, scroll and copy output, then close.
   Reopen/reconnect and check clear state and working input; older scrollback may be absent and a shell
   may be new. Do not judge reconnect as continuity of the old shell.
9. **Presets, Auto and quota.** On a matching desktop, check saved/effective choices, an intentional
   preset change and reset, Auto scope/inheritance, and quota source/age/unknown states. Confirm on the
   desktop and restore choices. Unsupported controls must not pretend a change succeeded.
10. **Context window.** Compare usage with the desktop. Where offered, inspect the setting's choices,
    default and when it takes effect; only change it on a disposable agent. Distinguish saved from
    applied state and restore the default. Missing desktop support should be explained.
11. **Feedback entry points — cancel.** Check the button, a shake after dismissing the keyboard, and
    a screenshot with their settings on. Accept the screenshot prompt; each route should open only one
    composer. Home and chat's ⋯ → **Send feedback** should pre-attach the screen from before the menu
    opened; Settings → **Send feedback** should attach the screen from before Settings opened, even
    with the shake attachment setting off. Check the picture contains neither menu nor Settings nor
    feedback UI. Tap the image: under **Move**, pinch, pan and double-tap; under **Pen**, try red,
    yellow, blue and white, then use **Redact** to cover harmless text. A pen is not redaction. Check
    Undo, Cancel and Done, reopen the editor, then **Clear edits** and its original-restoration
    confirmation. Before the first Send, Clear restores covered pixels too; the first Send makes
    edits final even if saving fails or enrollment changes. Later Clear removes only later marks.
    Turn **Include screenshot** off: Included must say screenshot left out; turn it on again to
    recover the edited image. Check the controls on the smallest supported iPhone and iPad at large
    Dynamic Type sizes and with VoiceOver. Inspect/remove the image, check **Add screenshot** still
    opens Photos, and cancel without Send. Photos replacement can show/send sideways; edited
    wide-gamut images flatten to sRGB. Record these SDK limits instead of assuming orientation or
    original colors are preserved. At the largest accessibility text size, the pinned Included/logs
    bar can occupy over half the smallest phone screen; record any control you cannot reach.
    Also dismiss the menu without selecting feedback, or choose another action, then
    reopen it from a changed screen: feedback must use the new screen. Settings may briefly show
    **Preparing feedback…** after choosing feedback. A secure-field or failed capture should open
    text-only with Photos available and say whether a secure field prevented capture or capture
    failed. Early menu highlight cleanup can intentionally open text-only without a capture-problem
    message; it must never reuse old pixels. In Settings, type a note or make an edit, then try Back,
    an edge-back swipe and swiping the Settings sheet away: only explicit Cancel should discard it.
    With iOS Full-Screen Previews on, return
    from its editor and look for the prompt then. Shake should not interrupt typing; secure fields must
    suppress capture. Record settings and timing if absent.
12. **Held feedback — inspect first.** If reports are held from an earlier enrollment, check count,
    **Send with this enrollment…**, its destination/count confirmation, and Cancel. Check **Clear held
    reports** and **Clear queued feedback** are reachable, without confirming deletion merely to test.
    Clear confirms the displayed held count. If that set changes before confirmation, nothing is
    deleted; the SDK explains the change and Go asks again with the refreshed count.
    Release or clear only reports you intend to send/delete. Release queues delivery; partial results
    and held counts must be honest, never called Sent. No held reports means this path is not exercised.
13. **One labeled diagnostics report — last, only when requested.** If safe, repeat a brief
    disconnect/reconnect within five minutes of opening this report and note its time. While enrolled,
    open Settings → Feedback diagnostics test → Prepare one diagnostics test report… → Prepare test
    report. Check the pinned **Diagnostics test report** label; start the note with **Diagnostics test**
    and include candidate/build and test time. Review Included's event count/availability, What this
    means, and the screenshot before choosing Send once; individual entries are checked in read-back.
    If capture was off, records are missing, or enrollment changes, record that state;
    cancel and ask before another attempt. This permission does not carry to ordinary reports. Keep the
    app foreground until delivery status settles; save the report ID and status. Do not send a second
    copy to work around a delay.

### Framebriar read-back for that one report

Framebriar must inspect the accepted report body **and its stored diagnostics blob in Azure**, not
just the feedback marker or a portal summary, and return:

- The report ID, **Diagnostics test** note prefix, app identity (`gameId`), `buildSha`, `sessionId`, capture time,
  receive time and delivery/storage outcome. Match the chosen version/build via the candidate record
  and correlated telemetry resource (`service.version`); the report does not have dedicated app-version
  and build-number fields. A `storage-failed` outcome means the report was accepted but its blob failed.
- `diagnostics.v`, `state`, `reason`, `windowStart`, `windowEnd`, `lines`, `bytes`, `dropped`,
  `droppedAttrs`, and optional `delivery.queued` (integer count) / `lastResult`. Go keeps at most 200
  newest entries within 64 KiB. `bytes` is the UTF-8 JSON size of `entries`, not the entire report.
- The frozen entries (`at`, `level`, `ns`, `event`, allowlisted `attrs`), including any captured
  connection failure, retry attempt and backoff around the noted interruption. If none were captured,
  explain the explicit none/unavailable/left_out state or missing window; do not infer that delivery
  succeeded merely because a marker exists. Records created after opening must not appear in this capture.
- Incident ID, phone instance, host/connection IDs and trace/span refs when included; entry attempt/
  connection/trace/span IDs where available. Correlate the times and IDs with the desktop's records,
  and list missing matches. References do not guarantee the desktop exported the corresponding spans.
- Only the `feedback.submitted` marker as report-specific telemetry, with no second attached excerpt
  copied through that path. Ordinary consented telemetry is separate. Check diagnostic fields contain
  only approved tokens/numbers/IDs, with no prompts, agent content, names, paths, addresses or URLs;
  user-written notes and the reviewed image are separate content.

Until that read-back succeeds, real-device capture, Azure storage and the feedback URLSession path
remain unproven. Privacy-store changes in the draft below still require the user's separate approval.

### Device compilation and signing check — 2026-11-02

Current-main source `a8c1964dea8d513940efdba9b4c94a8ff8769be3` builds successfully as **Release,
iphoneos arm64**, with Xcode 26.0.1 (17A400) / iOS SDK 26.0. The resulting app is **2.0.0 (175)**,
minimum iOS **26.0**, with that exact `FramebriarBuildSHA`. Build 175 is the source commit count,
using the same override convention as the release script; the project default alone would produce 1.

```sh
xcodebuild build -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos \
  -derivedDataPath build/beta-candidate/Device \
  -clonedSourcePackagesDirPath build/framebriar-070/source-packages \
  CURRENT_PROJECT_VERSION=175 \
  FRAMEBRIAR_BUILD_SHA=a8c1964dea8d513940efdba9b4c94a8ff8769be3 \
  CODE_SIGN_IDENTITY='Apple Development' \
  ASSETCATALOG_COMPILER_SKIP_MIGRATION_CHECK=YES
codesign --verify --deep --strict \
  build/beta-candidate/Device/Build/Products/Release-iphoneos/ClubhouseGo.app
```

Signature verification passes with an Apple Development identity and the app's team provisioning
profile; signed entitlements and profile both have `get-task-allow=true`. This proves development
compilation/signing, not a distribution archive or TestFlight eligibility. The ignored local log is
`build/beta-candidate/device-release.log`. No device was accessed, no app was installed, and no
archive/export/upload or feedback send was performed. A later candidate needs its own SHA/build count.

## Declarations

### Export compliance

`ITSAppUsesNonExemptEncryption` is `NO`. The app uses only Apple's TLS (URLSession) and CryptoKit and
Security framework primitives, to authenticate and encrypt connections to the user's own computer.

### App privacy

`Annex/Annex/PrivacyInfo.xcprivacy` declares the following. Everything reaches the developer only through
opt-in developer feedback (Framebriar), after the user redeems an invitation:

| Data type | Where it comes from | Purposes |
|---|---|---|
| **Other User Content** | Feedback notes, sent only when the user taps Send. | App functionality |
| **Photos or Videos** | A screenshot attached to feedback, reviewed (or removed) before Send. | App functionality |
| **Other Diagnostic Data** | Incident references on feedback (trace and span IDs, random process and connection IDs, a time window), and telemetry while enrolled: operation names, error classes and random IDs. | App functionality, Analytics |
| **Performance Data** | Telemetry while enrolled: connection, pairing and chat timings, counts and ping summaries. | App functionality, Analytics |
| **Crash Data** | Telemetry while enrolled: MetricKit crash, hang and resource-exception reports (classes and numbers, no call stacks). | App functionality, Analytics |

The current manifest marks every type **not linked** and **not used for tracking**. The service stamps
a pseudonymous per-enrollment ID and has no account; the future linkage assessment below still needs review.

- Enrolling turns developer telemetry on, and Settings says so next to Developer feedback (Framebriar's rule).
  Before enrollment no developer telemetry is captured or sent. Clearing enrollment stops that telemetry
  and discards its in-memory queue; saved feedback reports remain until delivered or explicitly cleared.
  Separately enabled Connection diagnostics can retain local records without feedback enrollment.
- Telemetry carries closed enum values, numbers and random UUIDs only: no prompts, agent content, names,
  file paths, addresses or URLs. See `docs/opentelemetry.md`.
- Feedback reports are sent only when the user taps Send.

Required-reason APIs:

- **System boot time**, reason `35F9.1`: the shake shortcut measures time between shakes.
- **User defaults**, reason `CA92.1`.

Optional OpenTelemetry diagnostics sent to a collector the user configures go to the user, not the
developer, so they are not declared as collected data.

App Store Connect's privacy labels have no "opt-in" field. To say that collection is opt-in:

- Answer the questionnaire to match the table above: each type collected, not linked, not tracking, for
  App Functionality and Analytics as listed.
- State in the privacy policy that feedback and its telemetry are voluntary and invitation-only, and
  stop when the user clears enrollment.
- Put the same in the App Review notes.

### App Transport Security

`NSAllowsArbitraryLoads` is on so the app can reach the user's computer at Tailscale addresses
(100.64.0.0/10), which iOS doesn't treat as local. Suggested App Review / Beta App Review note:

> Clubhouse Go connects only to the user's own computer at addresses the user pairs with, including VPN
> (Tailscale) addresses, over TLS pinned to the certificate exchanged at pairing. Every connection also
> presents a client certificate. The app's other connections (opt-in feedback and optional diagnostics)
> use https only and refuse redirects.

Internal TestFlight testers don't need review. External testers go through Beta App Review, which uses
the note above.


## Report diagnostics release gate

Framebriar is re-vendored unchanged from the approved v0.9.0 tag
`b2976ce33ea1df57c24a72eb501e07a989e95b37`; all 48 file hashes verify. API diagnostics v1 and the 256-KiB
request cap are confirmed. General report diagnostics remain **OFF**, explicitly at both model and
ordinary composer boundaries. OFF calls no provider and sends no diagnostics key, whether the
telemetry/incident switch is on or off. Ordinary consented telemetry remains separately enrolled.

A single test is deliberately available under **Settings → Feedback diagnostics test → Prepare one
diagnostics test report… → Prepare test report**. The confirmation and pinned **Diagnostics test
report** banner explain that this draft alone may attach bounded recent transport records. The user
is instructed to start the note with “Diagnostics test”; Go does not enforce that text in the SDK's
editor. The server readback for the user's deliberate report will verify its label/body. Cancel
leaves ordinary reports OFF. Enrollment-change recovery ends this grant, keeps only text/image,
creates a fresh OFF draft and incident refs, and requires another Send. Another ON test needs another
explicit preparation. Nothing is sent by opening the form or toggling its switch.

The provider captures once, synchronously and without I/O, then the SDK persists its frozen value
through retries/holds. It keeps connection-failure/backoff entries independently of delivery/access
state and does not duplicate them as a report-specific telemetry excerpt. The user switch removes
report entries plus incident/flat trace/span fields. Missing/unavailable entries are explicit in
Included; capture-off is called out in the test banner. If feedback telemetry setup is unavailable,
the test action is disabled and ordinary feedback still works.

Remaining release checks:

1. Review the actual included summary and enrollment/test disclosures against the privacy draft below.
   Store declaration changes need the user's approval; this adoption changes no manifest/store answer.
2. The user chooses any candidate installation and deliberately sends their own labeled report;
   Framebriar reads the body back from Azure. Real phone, Azure readback and feedback URLSession
   delivery remain unproven. No production send or phone/host-app installation is authorized here.

The legacy 16-KiB endpoint stripped unknown small fields and permanently rejected oversized reports.
Do not bypass the SDK to add the field. A diagnostics `storage-failed` result means the report was
accepted but its blob failed; do not show that as report rejection. The combined off switch must
remove entries, incident and flat trace/span references while preserving the user's notes/image.

### Unsafe older-SDK rollback

Release-note draft: “Saved feedback is bound to its enrollment. Reports held after a connection
change need an explicit decision before delivery. **Going back to an older Framebriar SDK is
unsafe.** A report still bound when downgraded can send under a later enrollment on that old SDK.
Held reports are fenced, but an older Swift writer drops their refs/held marker on a queue save;
after upgrading, those reports can only be cleared, not released. Before a planned downgrade,
let bound reports deliver and explicitly release or clear held reports. Follow the tagged
[rollback guidance](https://github.com/masra91/framebriar/blob/b2976ce33ea1df57c24a72eb501e07a989e95b37/docs/general-feedback-v2.md#rollback-to-an-older-sdk);
changing only the dependency pin is not a supported rollback.” This draft is not a release announcement.

For the 0.8.0 adoption, a synthetic queue and enrollment serialized by the actual 0.7.1 SDK
are tested through the new file store: report IDs, image bytes, enrollment identity, retry state
and held recovery survive. This does not authorize a downgrade or prove device Keychain behavior.
Older Swift ignores the new rejected-response notice. Unsent editor source/marks exist only in
view memory; saved reports contain flattened images. After an unconfirmed save, a copy may already
be on disk and send on relaunch. In the documented store-write/read-back double failure, that copy
can contain superseded pixels even if later edits were never successfully saved. Do not treat
reverting the vendor pin as recovery for that state; review the tagged SDK
[failed-save contract](https://github.com/masra91/framebriar/blob/b2976ce33ea1df57c24a72eb501e07a989e95b37/adapters/swift/README.md#failed-saves)
and settle queued/held reports before any planned rollback.

Migration limit: older queued reports have no enrollment ref. On first load the SDK binds them to
an enrollment present then, which may differ from the one used when they were captured. If no
enrollment is present, they become unbound/held instead. The new guarantee cannot reconstruct
missing legacy attribution; include this limit in candidate/release review.

### Draft App Privacy update — NOT EFFECTIVE

This is a release-review draft for future tagged-SDK adoption, not a change to
`PrivacyInfo.xcprivacy`, App Store Connect, a privacy policy or the currently shipped data flow.
The user must approve store declaration changes before they take effect. Enrollment binding and a
one-report diagnostics test do not themselves authorize broader collection.

| Existing category | Proposed clarification at adoption | Proposed purposes |
|---|---|---|
| Other User Content | Notes intentionally submitted; notes can contain private content despite the app's guidance. | App functionality |
| Photos or Videos | A kept, reviewed screenshot/image; the image can contain private content. | App functionality |
| Other Diagnostic Data | Optional frozen report entries, availability/loss counts, operation/failure enums, correlation IDs and delivery summary, in addition to existing incident references and enrolled telemetry. No content, raw error text, names, paths, addresses or URLs in automatic diagnostics. | App functionality; Analytics where actually used |
| Performance Data | Existing enrolled timings/counts; optional reviewed report entries can include bounded transport timings and byte counts. | App functionality; Analytics where actually used |
| Crash Data | Existing enrolled MetricKit classes/numbers; this preparation adds no stack or crash-body upload. | App functionality, Analytics |

Before approval, reconcile the exact tagged wire body, server retention and privacy policy with this
table. Review whether app actions belong under Product Interaction, and whether enrollment/process
identifiers require User ID or Device ID disclosure. **Do not infer “not linked” merely from a random
or pseudonymous identifier:** review actual server linkage and use with the user. The current manifest's
linked/tracking answers remain unchanged here; any revised answers are a separate approved release
change. Tracking is not proposed.

Apple requires declarations to reflect the app and its SDK partners, and links identity assessment
to account, device or other details. Voluntary feedback is not automatically exempt from disclosure;
ongoing telemetry after initial permission also needs assessment. See
[Apple's App Privacy details](https://developer.apple.com/app-store/app-privacy-details/).

Draft policy/review-note language: “Developer feedback is voluntary and invitation-only. Enrollment
enables automatic usage and diagnostic telemetry. Notes and images are shared only when you submit
them and may contain private information; review them first. Optional report diagnostics show what
is included before sending. Clearing enrollment stops automatic telemetry but does not delete saved
feedback. Saved reports can be cleared on this device; clearing local reports does not remove copies
already received by the service.” Adopt only after matching this wording to the tagged SDK's disclosure
and the approved release behavior; it is not a claim that the current composer has the future summary.

### SDK iPad timeout assessment

**Closed as a harness time limit, not an app hang.** Framebriar's exact v0.6.0 sequence took
11m00s against the original ten-minute background-command limit, explaining the kill. The original
combined build plus three sequential simulator command ended around 10m25s, with iPad about 3m20s
into its run; `sort`/`tail` hid progress, and its original evidence was unreadable with no stack,
sample or crash.

Framebriar reports iPad Pro 13 M4 / 8GB on iPadOS 26.0: **32 pass, 0 skip**, slowest 18.4s. Its timestamped
artifacts are under `release-review/ipad-harness-evidence/repro-dd63bc6` in Framebriar's evidence tree;
this is the team's result, not a Go-local reproduction. Limits: one exact-sequence run on a new
simulator, no original stack, and an intermittent stall is not disproved. This explains the command
kill; it is not an app hang fix or a general device/runtime guarantee.

- [x] Record the exact-sequence outcome and original harness limit separately from app behavior.
- [ ] Track Framebriar's one-off secure-keyboard issue separately; it remains unexplained. Verify typing
  and secure-field capture/presentation suppression on the adopted tag, without claiming it fixed.
- [ ] On the eventual candidate, check iPad full-screen/split-view settings, enrollment, saved-report
  confirmations, composer, image picker/cancel, keyboard and rotation. A simulator result does not
  prove physical shake, Full-Screen Previews or real-device delivery. If a future stall occurs, retain
  timestamps and a process sample/stack before classifying it.

The approved identity-binding SDK is now pinned to v0.7.1 unchanged. General report diagnostics
remain OFF; only the explicitly prepared test draft can opt in. No Go iPad run is claimed here;
the 0.6.0 evidence belongs to Framebriar's harness, and real-device checks remain separate.
