# Bound optional failure-log collection

On exact64c393fa run44975684940, Header lane137066163289 produced all42 expected
native terminal identities. The required test-verdict/inventory step was red and
ended03:19:17Z. The subsequent optional preview-log read ran until03:21:28Z
(131s) and was cancelled. Result upload ran afterward, then the job closed cancelled.
This is a directly observed finalization cost. It does not identify the interrupted
stage of the older f7a Preview cancellation, which remains unknown.

The correction retains the same owned-device `simctl spawn log show`, last-hour
window, compact style, three event-prefix predicates and artifact path. It places
a20s timeout on the owned local read client and a1-minute outer step bound. Output
streams directly to `TestResults/chat-follow.log`; all bytes received before a
timeout/failure stay available for the existing always-upload step. A sidecar
status JSON reports completion, client return code, elapsed time and byte count.
It does not label a partial/empty log complete or mutate a native result bundle.
Only the owned local client is killed on timeout; no app/device/peer lifecycle
operation is added. Remote utility termination is not an independently observed
guarantee of this local-client bound.

The step remains optional, only after failure, and `continue-on-error: true`.
The required native pipeline, result and inventory verdicts and all other job
checks/timeouts/retries are byte-unchanged. A failed native verdict stays failed;
no coverage, Release or inventory gate is waived. Always-upload still includes
TestResults and original xcodebuild logs. A timed-out diagnostic is explicitly
incomplete supplemental evidence.

Five cheap controls verify the unchanged command and predicates, complete output,
partial output on timeout, failed/missing clients, required-verdict/upload wiring,
and one real owned Python child that writes bytes then sleeps until its400ms test
timeout kills it. They execute no app/simulator/SDK command. The historical131s
step is not all credited as saved time: hosted launch/kill/upload/cleanup overhead
and the corrected step's actual time remain to be measured. This bound helps
reserve verification/results time; it cannot make a failed native suite green or
prove completion under55/60minutes.
