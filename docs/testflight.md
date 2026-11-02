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

Every type is **not linked** to the user (the service stamps a pseudonymous per-enrollment ID; there is no
account) and **not used for tracking**.

- Enrolling turns telemetry on, and Settings says so next to Developer feedback (Framebriar's rule).
  Before enrollment nothing is recorded or sent; clearing enrollment stops it and discards anything queued.
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
`diagnostics` field in outgoing reports. Keep it off until all three steps are complete:

1. Framebriar confirms the deployed report API supports diagnostics v1 and the 256-KiB request limit.
2. Framebriar tags a compatible SDK with synchronous frozen capture, durable retry persistence,
   bounded validation, availability/delivery status and the combined diagnostics off switch.
3. Go adopts and verifies that SDK, tests the actual outgoing payload against an authorized test
   destination, and explicitly enables the feature in a separate change.

The deployed 16-KiB endpoint strips unknown small fields and permanently rejects oversized reports,
which can block the local outbox. Do not add the proposed field manually. Local provider tests do not
prove server support. On adoption, review the included-content summary and enrollment disclosure
against App Privacy declarations; the off switch must remove entries, incident and flat trace/span
references while preserving the user's notes and reviewed image. A server `storage-failed` result
means the report was accepted but its diagnostics blob failed, so it must not be shown as a rejected
report. No new report data is transmitted by the preparatory provider.
