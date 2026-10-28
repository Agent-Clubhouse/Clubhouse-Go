# TestFlight releases

## Versions and tags

- The app version is `MARKETING_VERSION` in the Xcode project. Apple accepts only numbers (`2.0.0`).
- The build number is the commit count of the archived commit (`git rev-list --count HEAD`), set by
  `scripts/testflight.sh` at archive time. Later commits always get higher build numbers.
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

`Annex/Annex/PrivacyInfo.xcprivacy` declares:

- **Other User Content** and **Photos or Videos**: not linked to the user, not used for tracking, for app
  functionality. Both come only from opt-in developer feedback (Framebriar).
  - The user must redeem an invitation first.
  - They then write notes, may attach a screenshot they review (or remove), and tap Submit.
  - Nothing is sent otherwise.
- **System boot time** API, reason `35F9.1`: the shake shortcut measures time between shakes.
- **User defaults**, reason `CA92.1`.

Optional OpenTelemetry diagnostics are off by default. They are sent only to a collector the user
configures, not to the developer, so they are not declared as collected data.

App Store Connect's privacy labels have no "opt-in" field. To say that collection is opt-in:

- Answer the questionnaire to match the manifest above.
- State in the privacy policy that feedback is voluntary and invitation-only.
- Put the same in the App Review notes.

Apple's optional-disclosure criteria (infrequent, optional, user-initiated, not tracking or advertising)
may also exempt the feedback form from the labels. Declaring it is the conservative choice.

### App Transport Security

`NSAllowsArbitraryLoads` is on so the app can reach the user's computer at Tailscale addresses
(100.64.0.0/10), which iOS doesn't treat as local. Suggested App Review / Beta App Review note:

> Clubhouse Go connects only to the user's own computer at addresses the user pairs with, including VPN
> (Tailscale) addresses, over TLS pinned to the certificate exchanged at pairing. Every connection also
> presents a client certificate. The app's other connections (opt-in feedback and optional diagnostics)
> use https only and refuse redirects.

Internal TestFlight testers don't need review. External testers go through Beta App Review, which uses
the note above.
