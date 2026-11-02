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

## Declarations

### Export compliance

`ITSAppUsesNonExemptEncryption` is `NO`. The app uses only Apple's TLS (URLSession) and CryptoKit and
Security framework primitives, to authenticate and encrypt connections to the user's own computer.

### App privacy

`Annex/Annex/PrivacyInfo.xcprivacy` declares the following. Everything reaches the developer only through
opt-in developer feedback (Framebriar), after the user redeems an invitation:

| Data type | Where it comes from | Purposes |
|---|---|---|
| **Other User Content** | Feedback notes, sent only when the user taps Submit. | App functionality |
| **Photos or Videos** | A screenshot attached to feedback, reviewed (or removed) before Submit. | App functionality |
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
- Feedback reports are sent only when the user taps Submit.

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

The local `AnnexFeedbackDiagnostics` provider is preparation only. Report diagnostics sending is off
(`CompanionFeedback.reportDiagnosticsSendingEnabled == false`), and the pinned SDK does not put a
`diagnostics` field in outgoing reports. Framebriar has confirmed API deployment with diagnostics v1
and the 256-KiB request limit. **The user-approved identity-binding tag is v0.7.0 at
`f57b75fe5d38d7e2c3d221d246c9e01445da41dc`; adoption is a separate follow-up. Do not adopt 0.6.0 as an interim step.** Keep sending off until these remaining steps are complete:

1. The orchestrator supplies the exact identity-binding SDK tag, commit and public API. Re-vendor
   through `scripts/verify-framebriar-vendor.sh --refresh <exact-tag>` and verify SOURCE.json hashes;
   no direct vendor patches. Synchronous frozen capture, durable retries, identity binding, status
   and the combined diagnostics off switch must be included in that tagged contract.
2. Go adopts it and validates fake outgoing requests and enrollment changes. General emission stays
   off by default. A separate, explicitly requested, clearly labeled test-report path must be scoped
   to one draft; that exception is not implemented in this preparation. See the adoption checklist
   in [opentelemetry.md](opentelemetry.md#feedback-sdk-adoption-checklist).
3. The release owner reviews the included summary, enrollment disclosure and privacy draft below.
   Store declaration changes need the user's approval. No production send or phone/host-app installation is authorized
   by this checklist or by merging a preparatory PR.

The legacy 16-KiB endpoint stripped unknown small fields and permanently rejected oversized reports,
which could block the local outbox. Do not bypass the pinned SDK to add the field. Local provider tests do not
prove server support. On adoption, review the included-content summary and enrollment disclosure
against App Privacy declarations; the off switch must remove entries, incident and flat trace/span
references while preserving the user's notes and reviewed image. A server `storage-failed` result
means the report was accepted but its diagnostics blob failed, so it must not be shown as a rejected
report. No new report data is transmitted by the preparatory provider.

Release-note draft for the separate v0.7.0 adoption: “Saved feedback is bound to its enrollment;
reports held after a connection change need an explicit decision before delivery. **Going back to
an older Framebriar SDK is unsafe.** Follow the tagged SDK's rollback guidance; changing only the
dependency pin is not a supported rollback.” This preparation does not migrate the queue or adopt
the new SDK, and this draft is not a release announcement.

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

The user has approved the identity-binding v0.7.0 tag for the separate adoption follow-up. No iPad run or SDK adoption is performed by
this preparatory change; the 0.6.0 evidence is not permission to vendor that version.
