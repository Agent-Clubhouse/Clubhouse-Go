#!/usr/bin/env python3
"""Inert Foundation model of publisher completion versus Store event delivery.

Extracts the exact hosted test's post-join block and existing wait helper. The
consumer gate deliberately models a delayed listener; it is not a UIKit run,
the full production Store, or a replay of a particular hosted scheduler.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = "Annex/AnnexTests/CompanionAppUpdateViewTests.swift"


def body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="Read the exact source from an immutable Git revision instead")
    parser.add_argument("--baseline", action="store_true",
                        help="Counterfactual old immediate assertions; delayed positive must still fail")
    args = parser.parse_args()
    if args.baseline and not args.ref:
        parser.error("--baseline requires an explicit --ref")
    source = (subprocess.check_output(["git", "show", f"{args.ref}:{SOURCE}"], cwd=ROOT).decode()
              if args.ref else (ROOT / SOURCE).read_text())
    test = body(source, "    func testCheckingFlowsIntoLiveDownloadAndReadyInTheHostedViewWithoutCreatingAnApproval()")
    post_join = test[test.index("        await checking.value"):test.rindex("\n    }")]
    wait = body(source, "    private func wait(")
    program = r'''
import Foundation

enum AnnexTransportError: Error { case disconnected }
enum State: Equatable { case downloading, ready }
struct Update { var state: State; var downloadProgress: Double? }
struct Host { var appUpdate: Update?; var appUpdateApproval: String? = nil }
@MainActor final class EventStore {
    var hosts = [Host(appUpdate: Update(state: .downloading, downloadProgress: 50))]
    var appUpdateChecksInFlight: Set<String> = []
    func apply(_ update: Update) { hosts[0].appUpdate = update }
}
enum Issue: Equatable, CustomStringConvertible {
    case state, percentage, inFlight, approval, wait(String), thrown(String)
    var description: String {
        switch self {
        case .state: return "original state assertion"
        case .percentage: return "original percentage assertion"
        case .inFlight: return "original in-flight assertion"
        case .approval: return "original approval assertion"
        case .wait(let message): return "wait helper: \(message)"
        case .thrown(let message): return "unexpected throw: \(message)"
        }
    }
}
@MainActor var issues: [Issue] = []
@MainActor func XCTFail(_ message: String) { issues.append(.wait(message)) }
@MainActor func XCTAssertEqual(_ actual: State?, _ expected: State?) {
    if actual != expected { issues.append(.state) }
}
@MainActor func XCTAssertEqual(_ actual: Double?, _ expected: Double?) {
    if actual != expected { issues.append(.percentage) }
}
@MainActor func XCTAssertTrue(_ value: Bool) { if !value { issues.append(.inFlight) } }
@MainActor func XCTAssertNil<T>(_ value: T?) { if value != nil { issues.append(.approval) } }

actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        let ready = waiting; waiting.removeAll()
        ready.forEach { $0.resume() }
    }
}

@MainActor func verifyPostJoin(_ store: EventStore, _ checking: Task<Void, Never>) async throws {
POST_JOIN
}
@MainActor
WAIT_HELPER

@main struct Controls {
    private static let baseline = BASELINE_MODE
    enum Scenario: String {
        case delayed = "delayed ready/100", dropped = "dropped final delivery", wrong = "ready with wrong progress"
    }
    @MainActor static func run(_ scenario: Scenario, final: Update?) async -> Bool {
        let store = EventStore()
        let gate = Gate()
        let stream = AsyncStream<Update>.makeStream()
        let listener = Task { @MainActor in
            await gate.wait() // Explicit scheduling control, not production instrumentation.
            for await event in stream.stream { store.apply(event) }
        }
        var publisherFinished = false
        let checking = Task { @MainActor in
            if let final { stream.continuation.yield(final) }
            publisherFinished = true
        }
        await checking.value
        guard publisherFinished, store.hosts[0].appUpdate?.state == .downloading,
              store.hosts[0].appUpdate?.downloadProgress == 50 else {
            print("FAIL publisher completion control"); return false
        }
        print("OBSERVED \(scenario.rawValue): publisher finished, Store still downloading/50")
        issues.removeAll()
        let release = Task {
            try? await Task.sleep(for: .milliseconds(20))
            await gate.open()
        }
        var helperThrew = false
        do { try await verifyPostJoin(store, checking) }
        catch AnnexTransportError.disconnected { helperThrew = true }
        catch { issues.append(.thrown(String(describing: error))) }
        // Classify at the observation boundary, BEFORE finish/open/join can deliver a later value.
        let captured = issues
        let observed = store.hosts[0].appUpdate
        let ready100 = observed?.state == .ready && observed?.downloadProgress == 100
        let ready50 = observed?.state == .ready && observed?.downloadProgress == 50
        let downloading50 = observed?.state == .downloading && observed?.downloadProgress == 50
        let correct: Bool
        switch scenario {
        case .delayed:
            correct = captured.isEmpty && !helperThrew && ready100
        case .dropped:
            correct = baseline
                ? captured == [.state, .percentage] && !helperThrew && downloading50
                : captured == [.wait("The synthetic desktop did not publish its update state")] && helperThrew && downloading50
        case .wrong:
            correct = baseline
                ? captured == [.state, .percentage] && !helperThrew && downloading50
                : captured == [.percentage] && !helperThrew && ready50
        }
        stream.continuation.finish()
        await release.value
        await listener.value
        print("\(correct ? "PASS" : "FAIL") \(scenario.rawValue): issues=\(captured), helperThrew=\(helperThrew), observed=\(String(describing: observed?.state))/\(String(describing: observed?.downloadProgress))")
        return correct
    }
    static func main() async {
        let delayed = await run(.delayed, final: Update(state: .ready, downloadProgress: 100))
        let dropped = await run(.dropped, final: nil)
        let wrong = await run(.wrong, final: Update(state: .ready, downloadProgress: 50))
        if !delayed || !dropped || !wrong { exit(1) }
        print("APP_UPDATE_DELIVERY_CONTROLS PASS")
    }
}
'''.replace("POST_JOIN", post_join).replace("WAIT_HELPER", wait).replace("BASELINE_MODE", str(args.baseline).lower())
    build = ROOT / ".build"
    build.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="app-update-delivery-", dir=build) as directory:
        work = Path(directory)
        swift = work / "controls.swift"
        executable = work / "controls"
        swift.write_text(program)
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(swift), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == "__main__":
    main()
