# Provider V2 hosted routing prototype

This candidate starts at #616 head `434e6a969a4e12adb3dceec2e6c0ab59710596c0`.
It keeps eight macOS UI jobs, their names, the catch-all, unit placement, 55-minute
job limit, native execution allowances, retries and result verification. It moves
existing cases into smaller whole-class routing units so the seven provider cases
and archive-header control can begin in an existing lane with observed headroom.
It changes no product or shared test helper. Source checks are not hosted acceptance.

## Source and fixture equivalence

The seven `testProviderV2*` methods move from `CompanionPreviewSmokeTests` to
`CompanionProviderV2UITests`, retaining each method name and body byte-for-byte.
Their ten required private helpers/types are copied verbatim; the old helper
copies remain so other preview cases do not change. The method
`testPausedTranscriptArchiveHeaderStillOpensAndClosesAfterStreaming` moves from
`CompanionReadingOpeningUITests` to `CompanionReadingArchiveHeaderUITests`, with
its four fixture helpers copied verbatim. Only these eight methods are removed
from their original classes. No method is selected by an individual-method flag.

Both original and new classes are `@MainActor` direct `ReliableUITestCase`
subclasses. Neither original class defines setup/teardown overrides or stored
class state. The unchanged base creates and terminates the app, requests portrait,
adds `--ui-testing-fast`, configures the execution deadline, and retains its launch
and gesture policy. All fixture arguments, environment, accessibility identifiers,
expected labels, checked commands, consent/cancellation and no-replay assertions
remain in the copied bodies/helpers. All eight cases use their unchanged default
240-second launch allowance and one explicit launch attempt. Moving a source file
changes diagnostic file locations, and moving a class intentionally changes its
XCTest selector; no old result is attributed to the new selector.

The project uses a filesystem-synchronized AnnexUITests group on the existing
UI target; the project file and base helper remain byte-identical. Discovery has
447 test methods before and after, with exactly one occurrence of every moved
method. The existing CI discovery reports 79 classes before and 81 after. The CI coverage check retains complete
whole-class partitioning, a future-class catch-all and exactly one unit lane.
The move audit reconstructs both entire original files by reversing only these
eight removals and checks every copied member against the base bytes. Hosted
build discovery must still establish that the new classes compile and execute.

## Observed first run and placement

Run `44708573878` tested a merge with tree identical to 434. Its provider job
`136210713708` reached six first passes: ordinary 127.775s, Accessibility Large
182.645s, no-Start capability 86.766s, Large capture 92.449s, unsupported capture
68.959s and lost Apply 116.124s. Lost Start began but had no terminal result at the
55-minute cutoff. A separate preview method's first failure and successful retry
remain separate. The artifact ZIP contains staging data, not a finalized result
bundle or independent pixel acceptance. Archive job `136210713696` also reached
the 55-minute limit, with zero starts/outcomes for the archive-header method.

The prototype assigns the new provider and archive classes to unicode/home,
leaving UnicodeFocus and MarkdownFile there. It moves AppUpdate to composer/sheets,
and moves HomeSubtitle, HelperPresets and LinkedProject plus AppLifetime and
ComposerPaste to dispatcher/terminal. The preview lane retains PreviewSmoke,
SpawnVisual and ShakeDiagnostics. Other lanes and all assertions remain unchanged.
Dispatcher's observed run was red; its available elapsed budget is not green proof.

## Headroom sensitivity, not a duration guarantee

These calculations use this same run's actual job timestamps and terminal method
elapsed times, including observed retries. They retain each observed job's setup
and other overhead. They do not forecast new retries or slow scheduling.

| Lane | Observed job elapsed | Prototype calculation | Estimated elapsed |
| --- | ---: | --- | ---: |
| unicode/home | 2124s | minus AppUpdate 455.391, HelperPresets 227.372, HomeSubtitle 101.046, LinkedProject 134.717; plus eight unchanged 240s first allowances | 3125.474s (52m05s) |
| composer/sheets | 2685s | plus AppUpdate 455.391 | 3140.391s (52m20s) |
| dispatcher/terminal | 2412s | plus HelperPresets 227.372, HomeSubtitle 101.046, LinkedProject 134.717, AppLifetime 150.264, ComposerPaste 153.190 | 3178.589s (52m59s) |
| preview/project | 3392s including cancellation cleanup | minus six provider terminal durations 674.718, incomplete Lost Start active interval 78.450551, AppLifetime 150.264, ComposerPaste 153.190; plus twelve unobserved cases at 60s | 3055.377s (50m55s) |

The twelve unobserved cases are five remaining PreviewSmoke methods
(`testScratchAndHomeTextOpenInApp`,
`testSleepIsSeparateFromInterruptAndSettingsKeepProviderLockedOnRefusal`,
`testSleepingAgentOffersWakeAndResumeAndStartNewSession`,
`testUnsupportedProviderChangesDoNotOfferAnUnsafeGenericMenu`,
`testWakeSheetAcceptsTextWithoutTapping`), all five SpawnVisual methods and both
ShakeDiagnostics methods. The 60s reserve follows the existing estimate policy;
it is not measured evidence for these cases. At 90s each, preview becomes
3415.377s (56m55s); at 120s each it becomes 3775.377s (62m55s). The break-even
average is about 80.4s each before any additional retry/overhead. One additional
240s attempt in the other three affected lanes would also exceed 55 minutes.
Eight first allowances reserve neither all retry time nor arbitrary load.

### Closed historical comparison for the twelve cases

All twelve have a closed first pass in run `44685281882` on #620 head `ab6c7149`.
The logs identify Xcode 26.5, iPhone 17 / iOS 26.5, serial execution, the same
three-iteration failure-retry policy and default native command allowance. The
five PreviewSmoke bodies and their complete file-local private helper closure are
byte-identical between ab6 and this candidate. Both other class files, the shared
ReliableUITestCase base and simulator boot helper are byte-identical. Thus their
fixture arguments, appearance/theme setup and native selectors match. The product
trees and lane scheduling differ (fifteen lanes, maximum eight parallel, versus
this eight-lane matrix), so these are comparable historical observations, not a
controlled performance measurement or current-head result.

| Class/method (prefixes abbreviated) | First pass seconds | Job |
| --- | ---: | --- |
| PreviewSmoke / ScratchAndHomeTextOpenInApp | 42.644 | 136135075449 |
| PreviewSmoke / SleepIsSeparateFromInterruptAndSettingsKeepProviderLockedOnRefusal | 69.068 | 136135075449 |
| PreviewSmoke / SleepingAgentOffersWakeAndResumeAndStartNewSession | 45.449 | 136135075449 |
| PreviewSmoke / UnsupportedProviderChangesDoNotOfferAnUnsafeGenericMenu | 65.656 | 136135075449 |
| PreviewSmoke / WakeSheetAcceptsTextWithoutTapping | 38.190 | 136135075449 |
| SpawnVisual / Accessibility | 33.406 | 136135075435 |
| SpawnVisual / CatppuccinLatte | 16.404 | 136135075435 |
| SpawnVisual / Dark | 16.846 | 136135075435 |
| SpawnVisual / Light | 17.981 | 136135075435 |
| SpawnVisual / SolarizedDark | 16.042 | 136135075435 |
| ShakeDiagnostics / CompanionLayoutShakeAcrossNavigationAndComposerFocus | 46.184 | 136135075543 |
| ShakeDiagnostics / UnenrolledShakeExplainsEnrollmentInsteadOfDoingNothing | 36.447 | 136135075543 |

Each has exactly one iteration-1 start and one passed terminal result in its full
closed job log. Their total is 444.317s; substituting those observations for the
720s reserve gives preview 2779.694s (46m20s), about 8m40s below the limit before
new overhead/retries. No case remains historically unsampled in this set, but all
twelve remain unobserved on the current 434 run. Keep the 60/90/120s sensitivity,
80.4s break-even and retry warning above: historical passes do not close successor
hosted gates or guarantee future timing.

Historical direct log SHA256 values, respectively:
`54a00926f4ca2a5ea71febe8ceb043826a6d75474398660d32a8ee9ce5b862e6`
(617954 bytes),
`262a395ba5e01c6765e0977baf6787e4e1b642b922f549cf5644952eb858a7ae`
(893302 bytes), and
`cc37a97fb1103b340f7aa33dcbab8b1fa04cbe11b3d4f1e0c4ef20ee6146cd21`
(555864 bytes). No historical job is rerun for this comparison.

Configured aggregate allowance stays eight times 55 minutes (440 runner-minutes),
with no additional runner setup or job. The estimates have only 2–4 minutes of
slack on the affected lanes and cannot close any hosted method or aggregate gate.
Do not increase deadlines or remove cases to make the forecast fit. Inspect actual
first starts/results, retries, complete artifacts and lane/job elapsed on the exact
successor. If a lane still exhausts its budget, use its newly observed evidence to
revise placement separately.

## Evidence and remaining gates

Original direct job log SHA256 values:

- provider: `c1f673c59ddf9f72a1fa5b49c02de6a914fbbca118a6be3b591290061f59ab23`
- archive/other: `20b93d388f5755595821eb2ddc89fe4f9d208f1856f3a0b7187cbeda3832ed57`
- unicode/home: `29fcd18c739235ed9099f1661af1b1a85619283a4aa83714dcaa59517e3a9c37`
- composer/sheets: `51966f3b985a72224ab89c3cfed8919a239561eb9101d760384ff338b28861c8`
- dispatcher/terminal: `5ddd97287d81bfa741a8af977626502f04a5ded2fa82a14d44a42de98be4351c`

Private originals stay private. This isolated prototype requires independent source,
fixture, inventory and budget review before publication. Python CI checks do not
compile Swift or run a simulator. No new local native/simulator execution is
allowed by this assignment. Normal hosted validation on the reviewed successor
must retain every first outcome and required check. All seven provider methods
and the archive-header control still need fresh exact integrated iOS 26.5 first
outcomes after the shared CI repair; #620 is unlanded and its later fifteen-lane
layout is not imported here. Integration invalidates this eight-lane forecast and
requires routing review again. Historical failures, incomplete methods and local
26.0 acceptance remain attributed to their actual heads.
