# History refresh ownership after recovery (#631)

## Behavior

A pending read admitted on an operable desktop can keep a conversation in Refreshing after that connection is lost. The Store now retires that desktop’s active reads on actual loss of an operable connection. On explicit resync, it retires reads admitted while the connection could operate. Cached items and drafts are preserved; a replacement read can start, and the retired owner cannot apply a late success or error.

Each owner captures a unique identity and whether the connection could operate at admission. A buffered startup resync can arrive after a cold read begins, even after a connected report. That cold read is already fetching authoritative history and keeps ownership through startup resync. It still finishes through the existing success/error path. If an operable connection is subsequently lost, the cold read is retired too. Unchanged unavailable catalog reports cannot invalidate their own successful read.

The normal thrown-history handler already clears loading and exposes an actionable refresh. Successful empty history still completes normally. Existing transport limits, retries, command authority, snapshot formats, view/header code and wire-test deadlines are unchanged. The original mixed timeout window in report4bee43f3/build77b24899 does not identify which request caused its occurrence; its single cause remains open.

## Proof and preserved failures

The original reconnect regression fails on unchanged9600 product source and passes with retirement. Its24 controlled interleavings cover empty/cached state, old success/error before/during/after replacement, and an unaffected desktop’s pending read. Normal thrown-error and empty-success controls remain. The original3c focused selection passed113 related tests, but did not cover successful catalog publication or loaded startup resync.

The first PR run45304162338 on3c introduced initial-history failures in the wire tests. A successful LiveService read can publish its own catalog while still connecting; the original unconditional unavailable-host rule discarded that read. Both affected wire methods pass on exact9600 main (six parameter cases), and fail on3c at the unchanged sequence7 assertion. The new five-state catalog-publication regression fails on3c and passes after narrowing retirement to actual connection loss.

Revisiond24 passed a FILTERED121-test selection, but independent full-suite review failed seven non-terminal startup assertions in all three runs. Its own PR run45689971431 confirmed those same seven failures. This was a real regression, not a deferred flake. The d24 review is FAIL; its filtered pass is not acceptance. The terminal-only wait workaround was reverted: the entire wire test file, including initial ordering, deadlines and sequence7 oracle, is again byte-identical to main.

The admission-bound owner correction adds a held cold-read test covering all five unavailable starting states. Startup resync is delivered both before and after connected is reported. That test fails all five cases (25 issues) on the d24 product and passes with the correction. A separate control proves a cold read is still retired when an operable connection is later lost. Warm-read retirement, late-owner fencing, host isolation and all existing assertions remain.

Three consecutive FULL `swift test --jobs 2` runs pass1814 tests/215 suites each:12.083s,12.123s and12.126s of test execution. There is no test filter or execution-policy override; jobs2 bounds compilation only. The existing package FIFO is used. These full runs include the actual transport/service/store wire paths and the original wire fixtures. They are local macOS SwiftTesting proof, not an iOS/device or paired-desktop reproduction. Independent final-head review and the final head’s own PR CI remain landing gates.

Full text logs remain private:

| Evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| Original3c PR package failure |766220|4fd55d61df1d81776a8c2da81cc5e892dffb8e441c6eab9bda3b0a4cc9f16e4e|
| Exact-main local wire control |114532|44140edb7e911a3e3f72df4b944e02e517f498b384ab979a91b5161a099fe9a5|
| Original3c local wire failure |4459|4240418f1e8431fc87132daaf19b5e7b1cb939f5205d4a759fa87e7f1865cfb9|
| d24 own PR package failure |788306|017f3ea1f72f672cc7c15b6e505391420eb695b054994e9f93ddcc524bc344f1|
| Cold-start resync fail-before |11892|b6a264f7f569bd3cbf8d1b362bf279cc64beb2e46916d5ff137f2f8bf23c2645|
| Full corrected run1 |444029|3c1bf1ec68cff5dcd05380de7a7c46414d11223837911b95d2ad11419015f9ea|
| Full corrected run2 |444036|bc3c360f7791db9d183290b2b04f2d3ee9464922ad441c1df00d8c11b9a151c1|
| Full corrected run3 |444022|0620fdec78410272e0b2c2f3531948f10736c85e4ffa41f8d4b6e16d04474c0c|

The original PR’s separate same-socket ScheduledConditionTimeout has a verified main precedent in44990988347. Exact9600 main45079382106 failed a related snapshot-grace timeout but passed the same-socket case and affected wire methods. No wire-recovery failure is absorbed into that known scheduling signature. Any final CI exception must be verified against main and named in the merge note. No screenshots, manual CI reruns, deadline changes, beta/release or install are part of this work.
