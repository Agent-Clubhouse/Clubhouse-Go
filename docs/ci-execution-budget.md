# CI execution budget and first failure reporting

The current composed candidate retains eight iPhone jobs, the hosted bundle once
on each device, three intentional iPad UI repeats, packages/coverage, Release and
all inventory/result gates. The targets remain **under 60 minutes of all-checks
execution critical path and under 10 minutes to actionable failure feedback**.
Neither target is accepted by a forecast, a native pass before cancellation, or a
passing retry. Queue, pre-Plan, wall and summed compute are separate quantities.

## Closed original measurement

The sole initial full validation was PR #629 opened-event attempt 1,
[run 44962660538](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44962660538),
exact `f7a483f5c38c863711717f3e18280fcd4bc3820d` on main
`b1ff00b4ea3ca612b47925c47b4e402646b91b8e`. Its downloaded Plan manifest selected
full mode. Plan, Build, Release, packages and coverage passed; CompanionDomain
coverage was 14843/15968 (92.95%). Eight iPhone jobs and iPad actually emitted.
The overall run was cancelled and CI result failed.

The execution-weighted DAG critical path was **3803s (63m23)** through incomplete
verification: Plan10 + Build362 + Other3428 + result3. Creation-to-final-check wall
was6954s (115m54), summed job execution27975s (466m15), pre-Plan2s. Five physical
macOS slots cause additional waves; their resource wait is not execution-DAG time.

Of426 planned iPhone UI identities,415 had terminal log rows:379 last passing,
12 last failing and24 skipped. Skips are not native behavior coverage. Ten
UnicodeFocus methods and one FeedbackMenuAttachment method lacked a terminal;
two started but never finished and nine were unreached. Completed native UI
attempts totaled21530.169s, including2331.701s of completed later attempts.
All original first failures, retry outcomes and missing identities remain evidence.
No speed, green suite or corrected-head runtime claim follows.

| Original lane | Assigned execution | UI terminal / planned | Workflow result |
| --- | ---: | ---: | --- |
| Preview/project |3337s|47/47|cancelled|
| Feedback/needs you |3331s|53/53|cancelled|
| Dispatcher/terminal |3400s|53/54|cancelled|
| Unicode/home |3290s|49/49|failed|
| Search/permissions |2767s|55/55|passed|
| Composer/sheets |2972s|73/73|failed|
| Reading/grants + hosted |3232s|47/47|passed|
| Other |3428s|38/48|cancelled|
| iPad hosted + smoke |1268s|3/3 UI|passed|

Preview had47 native passes, no completed repeats and `TEST EXECUTE SUCCEEDED`
at00:38:16.959Z, then cancellation at00:38:26.145Z. Its retained ZIP has neither
pipeline-status nor tests-details JSON. **Final workflow verdict and interrupted
stage are unknown**; do not relabel it a verified pass or attribute all time to
one exporter. Search's native-success-to-test-step-end interval was about104s,
including several operations; it is not the duplicate query's measured cost.

The first recovered warning was AgentRowMenu's
`testNativeHomeAgentMenuAtAccessibilityXXXLAcrossThemes`, assertion24, at
23:49:42.762623Z. It was388.763s after lane assignment plus372s Plan/Build:
**760.763s (12m40.763) execution-path**, versus767.763s run wall. The7s difference
was pre-Plan2 + Build queue2 + device queue3. This misses10 minutes even with
immediate visibility. The server log timestamp is not a precise dashboard
visibility timestamp: the last empty annotations read was00:21:25.529Z and the
closed nonempty response provides no annotation creation time.

## Measured-cost placement

`scripts/ci/full_execution_observations.json` binds full raw-log lengths/digests,
415 complete all-attempt totals, ten prior same-source missing-method costs and
the single remaining unknown. It supersedes the initial297-method/114-unknown
estimate for placement. The original cost assets remain unchanged for provenance.
The fifteen ordinary offline LiveE2E skip identities are observed skips, with
unchanged guard/fixture setup; no live coverage or other unknown is inferred.

Ten missing UnicodeFocus IDs use prior4cd same-native-source observations. The
last FeedbackMenuAttachment case keeps60s rather than pretending its unfinished
20.883s is a completed cost. All observed failed/passing attempts remain charged,
including312.293s across six Footer Dark/Light attempts and their199.161s retry
portion. **No unmeasured Footer, exporter or metadata saving is deducted.**

`python3 scripts/ci/ci_execution_budget.py --suggest` reproduces deterministic
whole-class LPT plus bounded max-load-improving swaps. Four known first-failure
classes occupy the earliest current lexical class in separate lanes: HeaderReflow,
AgentRowMenu, AppUpdate and Footer. No passing work precedes those classes in the
current lexical route. This uses the order observed in original XCTest logs,
not an SDK ordering guarantee; realized method order and first warning timing
must be checked on the composed hosted head. A future class still belongs to the
catch-all once and may sort before its current first class. No test is split.

The actual additional hosted span plus second UI startup was776.254348s. Completed
UI attempts + explicit missing-method costs total22150.907s. Default per-lane
planning charges315s for preparation/runner/upload/cleanup and a visible120s
verification reserve (435s total). Original residual non-test envelopes, after
subtracting hosted span and unfinished native intervals, were262.418..535.282s,
mean419.598s. They already include any completed verification; **435s is the
modeled total instead of adding120s to those residuals**. Cancelled jobs may omit
verification/upload, and a535s envelope shows435s is not a future upper bound.

| Retained job | UI methods | Body + hosted | Modeled assigned execution |
| --- | ---: | ---: | ---: |
|UI tests (preview, project pages)|42|2866.231s|3301.231s|
|UI tests (feedback, needs you)|36|2866.854s|3301.854s|
|UI tests (dispatcher, terminal)|48|2862.238s|3297.238s|
|UI tests (unicode, home)|74|2866.292s|3301.292s|
|UI tests (search, permissions)|48|2866.432s|3301.432s|
|UI tests (composer, sheets)|69|2866.789s|3301.789s|
|UI tests (reading, grants) + unit tests|46|2867.069s|3302.069s|
|UI tests (other)|63|2865.256s|3300.256s|

The maximum is3302.069s; modeled queue-excluded CP is3677.069s (**61m17.069**).
Even ideal packing has average2865.895s body+hosted, giving3675.895s CP with these
reserves. Eight55-minute lanes supply22920s of usable body budget versus22927.161s
of charged work. To meet the stricter60-minute all-checks CP with the measured
375s prefix/result, a lane must finish within3225s: the aggregate model still
needs **607.161s less work/overhead**. Routing alone cannot establish either limit.
Splitting only PreviewSmoke offered about6s improvement and was rejected.

A plausible five-slot work-conserving schedule is6978.300s (116m18.300) with matrix
order then iPad, or6977.663s with iPad then longest. It is a resource model, not
an observed queue bound. Unknown-case90s adds30s to its current owner; an extra240s
retry per lane adds240s to CP. Increasing verification reserve120→180 adds60s to
CP and removes480s of aggregate usable body budget. CLI switches expose these
sensitivities; none changes actual timeouts, selection or verdicts.

Actual non-hosted assignment-to-first-method cost varied177.380..340.159s; the
hosted lane first UI began1063.897s after assignment. With the372s Plan/Build
prefix this leaves variable headroom for a failure signal. Earlier placement
cannot guarantee10 minutes or repair an invalid/expensive native scenario.

## Composed bounded corrections and proof

The reporter forwards original stdout and assertion text, emits escaped advisory
warnings/JSONL before xcresult completion, and never decides the verdict. The
isolated identity correction uses available normalized source-file plus exact
Swift Testing display name, retaining both same-bare-name failures from different
files. Swift Testing elapsed/attempt are deliberately null because bare start
records cannot be attributed safely. Same-file same-display ambiguity remains;
this is not a universal structured identifier. XCTest qualified timing is retained.
Pipeline statuses, raw logs and final complete xcresult/inventory are mandatory;
passing retries never erase the first failed attempt.

`verify-xcresult.py --tests-json-output` removes stale output before SDK reads,
queries details once, and atomically exports the same fresh usable object for
both semantic verdict/retry checks and inventory. Requested malformed/empty/read
failure stays red without stale or partial JSON. A semantic red or summary error
still exports valid details for the independent inventory diagnostic. Standalone
callers without export keep their previous advisory-details policy. Both devices
retain strict hosted/iPad no-retry gates. This removes a duplicate export; measured
savings await hosted query/serialization telemetry.

The exact reviewed Footer carry changes only the two existing Dark/Light gesture
paths to use the visible transcript above footer/keyboard. All downstream pixel,
final-line, keyboard and inset assertions,140pan cap, fixture and allowances stay.
The original six failed attempts are historical costs, not promised savings;
passing paths reach additional assertions. Overflow oldline273 remains separate.
Next necessary hosted validation must retain Dark/Light first attempts, durations,
retries and reached/unreached downstream assertions.

Bounded parser metadata reuse and real20-fixture counts are documented in
[ci-deinit-metadata-reuse.md](ci-deinit-metadata-reuse.md). All86 scanner executions
and their canonical output hashes remain equal; only compiler-version/SDK metadata
queries are reused. Local fixture elapsed dropped6.165s. Hosted stage savings are
unmeasured, and even removing the entire old61s policy step leaves the observed
incomplete63m23 path at62m22. No threshold, ownership policy or scanner-result cache
is introduced.

Source controls retain all79 current UI classes /426 methods once across eight
iPhone jobs, the future-class catch-all, three intentional iPad UI repeats and
whole hosted bundles once per device. Full/selected/daily scope behavior, job names,
check gates, retries and timeouts remain unchanged. Cheap controls are not SDK
or native discovery. Independent delta reviews and one justified composed hosted
run must preserve missing IDs, first failures, actual complete inventories,
verification time, first signal vs visibility intervals, all-checks CP, queue,
wall and summed compute before any performance/green/landing claim.
