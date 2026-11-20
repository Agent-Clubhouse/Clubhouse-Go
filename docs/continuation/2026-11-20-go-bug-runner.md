# go-bug-runner continuation: 2026-11-20

**Initial preservation snapshot, not an ownership transfer or execution approval.**

Repository: `Agent-Clubhouse/Clubhouse-Go`. Preservation branch:
`bold-gazelle/proof-runner-continuation-nov20`. Owner: `go-bug-runner`
(workspace alias `bold-gazelle`). Mini identity/link is pending. Retain ownership
until the authorized counterpart fetches the exact preservation commit and
explicitly accepts it by direct message. Begin wrap by 05:00 Pacific; corrected
hard cutoff is 06:15 Pacific / 14:15Z.

Mini is quota-blocked; Tael coordinates verified readiness after the stated 04:00
Pacific reset. Hold Mini messages/wakes until readiness is verified.

No product/test implementation belongs to this runner. This branch preserves
sanitized notes and passive harness source only, not app changes, private
captures, AX archives, logs, compiled products, or executable configuration.
No PR or landing is requested by this snapshot.

## Current assignments and gates

| Assignment | Exact source / current status | Next action |
| --- | --- | --- |
| Footer/Preview successor | `026688254361e5cb1ee09ee5430df6973462a179`, tree `dc093496ee0c92ae3d375d60f7aee255ca5e92c0`; source review accepted, owned execution configuration **pending**, no build/native invocation | Obtain genuine independent configuration acceptance; then fresh A, independent full-five-product A acceptance, then T. Do not queue before the gates. |
| Provider VPHONE originals | `434e6a969a4e12adb3dceec2e6c0ab59710596c0`, tree `7bafe7ebde4cb761495e5224fbc1f4ffe64b49c5`; 69 immutable entries rehashed, all ten entire PNGs viewed; remaining original bindings/closure audit **in progress** | Finish independent canonical VPHONE review. Owner's prose corrected to three TOTAL events: two previews + one Apply, zero Start/replay; unchanged reviewed expectation. No rerun. |
| AppUpdate T originals | `b3d95526800b91101b435c75ff6a01633b9c59b6`, tree `59b1ec636da07a40a3f8da839c4ed31ff7642ea5`; 54-entry request received, **not independently accepted** | Review all eight entire PNGs, original actions, two unique runs, source/config/A/receipt/cleanup bindings. No rerun. |
| f47 iPad diagnostics | `f47cfeff3b54fb4fdaf9028fd72d1e03c31d9d78`, tree `593d6f7b4fbe64941d1bec1ad0cad129b83ac370`; fresh A and first H independently accepted | Complete scoped non-reproduction only; no extra A/H. No screenshots/movie existed for H. Hosted cause remains unresolved. |
| Provider A / SE Large originals | Exact `434e6a969a4e12adb3dceec2e6c0ab59710596c0`; A and first SE Large originals independently accepted, including all 18 entire PNGs | Owner's SE pair waits for actual phone-original gate. No reviewer native execution. |
| AppUpdate A originals | Exact `b3d95526800b91101b435c75ff6a01633b9c59b6`; A originals independently accepted, compiled products reviewed as metadata only | T acceptance remains separate. No stage/Idle action or pixel credit from build acceptance. |
| Transport timing / NeedsYou capture attribution | Exact transport `c53876fb2ddf0ed5128132a659277b3389c6663b`; focused P accepted. NeedsYou first-red screenshot timeout independently corroborated | Closed scoped reports; no reruns or causal cure claim. Transport PASS emitted no failed-wait timing counters. |

Source owners must preserve their own implementation branches. Remote availability
of these exact source commits is not established by a hash in this note.
Never substitute a newer/main/rebased head for an accepted exact head.

## Preserved custom harness source

`go-bug-runner-harness/source/` contains byte-for-byte source snapshots with
`.txt` suffixes and non-executable permissions. `SHA256SUMS` records full digests.
They contain no proof payloads or captured runtime data.

Seven lifecycle components were previously accepted in owned configurations:
supervisor, worker, outer supervisor, cleanup, auditor, ordinary FIFO, package
FIFO. The Provider verifier and two legacy adapters are retained for historical
hash verification. These snapshots are **not** permission to install, overwrite,
or execute any shared-host helper.

`run-proof.py.txt` is the prospective Footer adapter:
`e5dce9ceea9c6cbe97aaeea81f01b4383408f3f6c6cdcc6a7bb3fc82d0275f01`.
Its sole change removes `go-bug-runner` from the prior-A reviewer whitelist,
leaving `go-bug-pass` and `Clubhouse-Go-Orchestrator`. Its configuration is
**UNRUN / awaiting independent review**. Legacy adapters are historical only:
their caller-specific reviewer whitelists must not be reused as authority for
the current executor.

Any resumed configuration must bind the actual new executor and exclude it and
all its aliases from original-A reviewers. Genuine peer/parent review is required.
Do not rename a reviewer, self-certify, skip hashes, or edit an allowlist to consume
an otherwise unconsumable report. Source/configuration/original gates are separate.
Do not execute Python with assertions disabled.

Verify the archive without importing or executing its modules:

```sh
cd docs/continuation/go-bug-runner-harness
shasum -a 256 -c SHA256SUMS
```

## Setup and exact invocation shape

Observed toolchain: Xcode 26.0.1 / 17A400; Apple Swift 6.2
(`swiftlang-6.2.0.19.9`); arm64; simulator SDK/runtime iOS 26.0 / 23A343.
Local iOS 26.0 is not hosted iOS 26.5 evidence. Required tools: Git, Python 3,
Bash, Xcode/xcrun, and an already installed compatible simulator runtime.
Do not install tools/runtimes, buy capacity, change accounts, or restart services
without the applicable authorization.

Prepare an exclusive checkout and private proof directory inside the new owner's
workspace. Verify repository remote identity and fetch the source owner's exact
published ref/SHA; verify HEAD, tree, clean status, full tracked source closure,
Git modes/blobs/SHA256, and binary full diff. Do not use an arbitrary workspace or
reuse another owner's products/simulator. Keep originals private.

The adapter requires `manifest.json`, `review.json`, canonical source/configuration
reports, all runtime/data digests, phase order files, and any required prior-phase
acceptance files. These are **private-only dependencies**, not included here.
Rebind owned paths and identities under a new independently reviewed configuration;
old configuration digests cannot approve changed paths/owners/bytes.
`known_native_outcomes` must be an object/dictionary, never historical prose.

Only after actual independent gates and authority are present, the existing
adapter invocation shape is:

```sh
env -u COPILOT_CONNECTION_TOKEN \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  python3 "$PROOF_ROOT/run-proof.py" launch A a-r1
```

A is fresh `build-for-testing`, jobs 2, parallel testing NO, signing NO,
generic iOS Simulator destination; followed by `scripts/check-isolated-deinits.py`
against the actual app dylib and `python3 -m unittest discover -s scripts/deinit/tests`.
Its entire actual five products and closed originals require independent A review
before T, then fresh equality checks against entry/pre/post hashes.

Prospective Footer T uses the same prefix and
`python3 "$PROOF_ROOT/run-proof.py" launch T t-r1`, only after A acceptance.
Its reviewed-plan bounds are A 900s / T 900s, five methods once, seven SUT launches
(six Footer + one Preview), no video, no retries, unchanged 240s native-method
allowance. Exact alphabetical selectors:

```text
ClubhouseGoUITests/CompanionComposerFooterSurfaceUITests/testDarkFooterMatchesChatSurfaceAndFinalLineRestsAboveIt
ClubhouseGoUITests/CompanionComposerFooterSurfaceUITests/testLightFooterMatchesChatSurfaceAndFinalLineRestsAboveIt
ClubhouseGoUITests/CompanionComposerFooterSurfaceUITests/testOverflowFooterWithKeyboardUpEvidenceInLightAndDark
ClubhouseGoUITests/CompanionComposerFooterSurfaceUITests/testPendingTrayFooterMatchesChatSurfaceInLightAndDark
ClubhouseGoUITests/CompanionPreviewSmokeTests/testContentPreviewDismissesWhileToolUpdatesStream
```

Native command shape is `xcodebuild test-without-building -project
Annex/Annex.xcodeproj -scheme ClubhouseGo -configuration Debug -jobs 2
-parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -derivedDataPath <owned-A-DD>
-destination platform=iOS Simulator,id=<owned-UUID> -resultBundlePath <private-result>
-test-timeouts-enabled YES -default-test-execution-time-allowance 240
-maximum-test-execution-time-allowance 240`, plus exactly the approved
`-only-testing:<selector>` arguments. The adapter, not an unbounded direct call,
owns resource admission, FIFO, outer bound, claims and cleanup. Never add
`-test-iterations 1`, retry flags, extra selectors, or a second attempt.

All heavy work uses the existing ordinary `/tmp/clubhouse-go-run.sh` lane, without
priority/any-slot/preemption/reservation. One Go simulator at a time. Admission:
`vm_stat` free + inactive >= 8 GiB, CPU idle >= 40%, swap growth <= 64 MiB / 10s;
retain actual raw samples. For a fresh owned simulator:

```sh
xcrun simctl spawn "$OWNED_UUID" defaults write \
  com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool YES
```

Preserve the bound 20s OS stabilization and fresh pretest admission check. Always
close and remove only the owned simulator/groups; no peer process/simulator actions.
Retain exact commands, heads, full xcresult, raw diagnostics/activities/AX snapshots,
attachments, receipts, outer/external closure, and actual post-FIFO elapsed time.

Footer acceptance additionally needs all 36 strips, actual measured contrast/
surface/final-line/control evidence, current native editable field frame and tap,
keyboard identity, and raw `hasKeyboardFocus`/`hasFocus` if present around each focus
and subsequent capture. Keyboard presence alone is NOT native field focus; absent
flags must remain deferred. Overflow's existing typeText is separate input evidence.
Preview needs actual native frames/events/follow trace, observed pause/movement,
unobscured target/clip, exactly the prescribed opens/dismissals in one app. Requested
drag or offset alone does not prove actual movement. Preserve unchanged source.

## Private evidence references and transfer dependencies

The following are locally retained immutable Git blob/report references, **not
remote GitHub objects supplied by this branch**. A SHA printed here is not an
originals audit or a remote fetch receipt. Authorized private delivery is required
before a counterpart can consume the payloads.

| Packet/report | Local Git object / SHA256 |
| --- | --- |
| Footer source acceptance | `ff8b4840abab3b37b7d763f21e0b236aa84dac0f` / `0f2033b7f3a60ddb2b8c1c51b1add19f546bd490532706a7bed0b4ecb5aece90` |
| Footer prospective 20-entry config | `2e216c01bda620a42858af232e74ddd9fd82f137` / `bdf5bee831bb4929466dd4fbcb5bfd761177d90cdace981d19e8f20d81f7e896`; manifest `c781589bd9967365173abde5eef57298b9dd24c18740c67a2573acee1dbe4eb6` |
| Provider phone 69-entry originals | `82a0c87277bb07bccd77c41b6b496a2e905a1abd` / `c0a9d86bad0864a2e22f7f9d8966c6de62c49ec0de17b65e3a007613a0ace175` |
| Provider SE Large acceptance | `51f4327e8e1a0e4050adb23fb23114782bfbcfdc` / `f8dfbef621c163477f3412ea558118eebbd7a482598f090bf677e579af6c0312` |
| Provider A acceptance | `aa5357c69424687326b2d7ac38f06162ecbf462e` / `b31825c5ca4f782f4903c8c1e5d1da20e7cf774dbc65b0e791611122b2cecb9d` |
| AppUpdate T 54-entry originals | `1f7758991a6fc4dfea39ba83269100dca6c474bd` / `d52abc6724b681457d4f6bb9742c4ce5f4b20b6e1e73f36dd68b21dc61d9ee4a` |
| AppUpdate A acceptance | `cf6b4e1fb7c487463e9a714a7f25154e17c9862b` / `724aac9be7db7ced951e82e3638f5b5d298c7b266ff0b1e02dd79f46f5dc052c` |
| f47 genuine parent A acceptance | `18b25b96e1e5b71ffd27a9581eb3c487b360f8ac` / `1663b73074babc2825c6de601250641be8410327e001b23eb5b1fa380744cba3` |
| f47 H acceptance | `d4e416b2f45144a92256ac451e3af2d210f63918` / `6e4838957eeaef3fb577c1e4ce139ec73ca43355e98c6d0db5d80ee156971595` |

Essential resume dependencies: actual source-owner remote refs; genuine canonical
source/configuration reports; full bound manifests/data/order/obligation files;
required prior-A reports/receipts/products; pending originals packets for reviews.
Historical accepted media/logs remain private retained evidence, not permission or
dependencies to rerun already closed jobs. Raw private evidence and generated
products must never be pushed to this public repository.

Keep first reds separate from historical retries. Preserve the preentry f47
reviewer-identity STOP, AppUpdate's held invalid map configuration, old provider
303.830s timeout, and original hosted failures. No local pass proves hosted 26.5,
causal cure, production provider handshake, arbitrary-load behavior, or a different
integrated head. Provider's 1.350s model-to-effort capture bracket includes gesture/
query/screenshot work and is not isolated lookup duration or API-return timing.

Final transfer requires: exact remotely fetched preservation SHA; verification of
all archived source digests; authorized receipt and rehash of essential private
inputs; explicit authorized Mini acceptance; task-specific ownership record.
Missing routes/inputs remain blockers, not implicit acceptance.
