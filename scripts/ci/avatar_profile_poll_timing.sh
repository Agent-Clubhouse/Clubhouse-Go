#!/bin/bash
# Exercises the exact AvatarProfilePoll text from CompanionAvatarRenderingTests.swift with a fake clock.
# Host-only and inert: no simulator, app, UIKit or real sleeps. Proves the poll keeps the original
# `repeat { capture; analyse; stop if passed; sleep } while now < deadline` acceptance, and that its
# trace separates a stall during capture from a stall during the final sleep.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Annex/AnnexTests/CompanionAvatarRenderingTests.swift"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed -n '/^\/\/ BEGIN AvatarProfilePoll/,/^\/\/ END AvatarProfilePoll/p' "$source_file" > "$work/poll.swift"
grep -q 'enum AvatarProfilePoll' "$work/poll.swift"
# Failure preservation: between the poll result and the original assertions, nothing may throw,
# suspend or capture again, so a failed poll always reaches its assertions with its measured frame.
between="$(sed -n '/print("AVATAR_PROFILE_PIXELS/,/XCTAssertGreaterThanOrEqual(rowArea/p' "$source_file")"
[ -n "$between" ] || { echo "FAIL: poll-to-assertion span not found"; exit 1; }
if grep -nE '\btry\b|\bawait\b|snapshot\(|profilePixelArea\(' <<<"$between"; then
    echo "FAIL: the poll-to-assertion span can throw, suspend or capture"; exit 1
fi
echo "AVATAR_PROFILE_FAILURE_PATH PASS"
cat > "$work/main.swift" <<'SWIFT'
import Foundation

func ms(_ value: Int) -> Duration { .milliseconds(value) }
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

/// `readyAt` is when both avatars would be drawn; a capture shows readiness at its start.
struct Case {
    var name: String
    var readyAt: Int
    var capture = 1, analysis = 1, sleep = 10
    var captureStall: (sample: Int, cost: Int)? = nil
    var sleepStall: (afterSample: Int, cost: Int)? = nil
    var start = 0
}

@MainActor func run(_ c: Case) async throws -> (passed: Bool, trace: AvatarProfilePoll.Trace) {
    var now = ms(c.start)
    var captures = 0
    let result = try await AvatarProfilePoll.run(budget: .seconds(2), elapsed: { now }, capture: { () -> Bool in
        captures += 1
        let ready = now >= ms(c.readyAt)
        now += ms(c.captureStall?.sample == captures ? c.captureStall!.cost : c.capture)
        return ready
    }, passes: { ready in
        now += ms(c.analysis)
        return ready
    }, sleep: {
        now += ms(c.sleepStall?.afterSample == captures ? c.sleepStall!.cost : c.sleep)
    })
    print(result.trace.summary)
    check(result.passed == result.value, "\(c.name): passed must be the last analysed value")
    check(result.trace.steps.count == captures, "\(c.name): one step per capture")
    return (result.passed, result.trace)
}

@MainActor func main() async throws {
    // A. Ready at once: one sample, no sleep, no loop-condition read.
    var r = try await run(Case(name: "immediate", readyAt: 0))
    check(r.passed && r.trace.steps.count == 1 && r.trace.lastCheck == nil, "immediate")

    // B. Never ready on a normal clock: stops at the first post-sleep check at or after 2s.
    r = try await run(Case(name: "never", readyAt: Int.max / 2))
    let checks = r.trace.steps.compactMap { $0.sleep?.end }
    check(!r.passed, "never: must fail")
    check((checks.last ?? .zero) >= .seconds(2) && checks.dropLast().allSatisfy { $0 < .seconds(2) }, "never: exits on the first check >= deadline")
    check((r.trace.steps.last?.postAnalysis ?? .seconds(99)) < .seconds(2), "never: last measured frame precedes the deadline")

    // C. Ready during a final sleep that stalls across the deadline: original acceptance still fails,
    //    and the trace locates the stall in that sleep (not in capture).
    r = try await run(Case(name: "stall-final-sleep", readyAt: 1_600, sleepStall: (afterSample: 125, cost: 5_000)))
    check(!r.passed, "stall-final-sleep: semantics unchanged, no post-deadline frame is accepted")
    let finalSleep = r.trace.steps.last?.sleep
    check(finalSleep.map { $0.start < ms(1_600) && $0.end >= ms(6_000) } == true, "stall-final-sleep: final sleep spans readiness and deadline")
    check(r.trace.steps.allSatisfy { $0.postCapture - $0.preCapture <= ms(1) }, "stall-final-sleep: no capture stall")

    // D. Capture stalls past the deadline before readiness: the long capture is visible, then one sleep ends the poll.
    r = try await run(Case(name: "stall-capture", readyAt: 6_500, captureStall: (sample: 100, cost: 5_000)))
    check(!r.passed, "stall-capture: must fail")
    check(r.trace.steps.count == 100, "stall-capture: poll ends after the stalled capture's sleep")
    let stalled = r.trace.steps.last
    check(stalled.map { $0.postCapture - $0.preCapture == ms(5_000) && $0.sleep.map { $0.end - $0.start == ms(10) } == true } == true, "stall-capture: stall attributed to capture")

    // E. Boundary: a check exactly at the deadline stops (`<`); one just before it samples again.
    r = try await run(Case(name: "check-at-deadline", readyAt: Int.max / 2, capture: 0, analysis: 0, sleep: 500))
    check(r.trace.steps.count == 4 && r.trace.lastCheck == .seconds(2), "check-at-deadline: 4 samples, stop at exactly 2000ms")
    r = try await run(Case(name: "check-before-deadline", readyAt: 1_999, capture: 0, analysis: 0, sleep: 1_999))
    check(r.passed && r.trace.steps.count == 2, "check-before-deadline: samples again at 1999ms and passes")

    // F. Ready between samples before the deadline: passes on the first frame that shows it.
    r = try await run(Case(name: "ready-mid-poll", readyAt: 305))
    check(r.passed && (r.trace.steps.last?.preCapture ?? .zero) >= ms(305) && r.trace.steps.dropLast().allSatisfy { !$0.passed }, "ready-mid-poll")

    // G. A nonzero start offset still uses a deadline relative to the first read.
    r = try await run(Case(name: "offset-start", readyAt: Int.max / 2, start: 10_000))
    check((r.trace.lastCheck ?? .zero) >= ms(12_000) && r.trace.steps.compactMap { $0.sleep?.end }.dropLast().allSatisfy { $0 < ms(12_000) }, "offset-start")

    print(failures == 0 ? "AVATAR_PROFILE_POLL_TIMING PASS" : "AVATAR_PROFILE_POLL_TIMING FAIL \(failures)")
    if failures != 0 { exit(1) }
}
try await main()
SWIFT
xcrun swiftc -swift-version 5 \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature DisableOutwardActorInference \
    "$work/poll.swift" "$work/main.swift" -o "$work/timing"
"$work/timing"
