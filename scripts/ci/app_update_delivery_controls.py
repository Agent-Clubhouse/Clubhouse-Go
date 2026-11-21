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
    args = parser.parse_args()
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
@MainActor var issues: [String] = []
@MainActor func XCTFail(_ message: String) { issues.append(message) }
@MainActor func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    if actual != expected { issues.append("equality: \(actual) != \(expected)") }
}
@MainActor func XCTAssertTrue(_ value: Bool) { if !value { issues.append("not true") } }
@MainActor func XCTAssertNil<T>(_ value: T?) { if value != nil { issues.append("not nil") } }

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
    @MainActor static func run(_ name: String, final: Update?, shouldPass: Bool) async -> Bool {
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
        print("OBSERVED \(name): publisher finished, Store still downloading/50")
        issues.removeAll()
        let release = Task {
            try? await Task.sleep(for: .milliseconds(20))
            await gate.open()
        }
        do { try await verifyPostJoin(store, checking) }
        catch { if issues.isEmpty { issues.append("threw \(error)") } }
        let accepted = issues.isEmpty
        let captured = issues
        stream.continuation.finish()
        await release.value
        await listener.value
        let correct = accepted == shouldPass
        print("\(correct ? "PASS" : "FAIL") \(name): accepted=\(accepted), issues=\(captured)")
        if name == "ready with wrong progress" {
            // In the candidate this reaches the unchanged percentage assertion after real model delivery.
            guard store.hosts[0].appUpdate?.state == .ready,
                  store.hosts[0].appUpdate?.downloadProgress == 50 else { return false }
        }
        return correct
    }
    static func main() async {
        let delayed = await run("delayed ready/100", final: Update(state: .ready, downloadProgress: 100), shouldPass: true)
        let dropped = await run("dropped final delivery", final: nil, shouldPass: false)
        let wrong = await run("ready with wrong progress", final: Update(state: .ready, downloadProgress: 50), shouldPass: false)
        if !delayed || !dropped || !wrong { exit(1) }
        print("APP_UPDATE_DELIVERY_CONTROLS PASS")
    }
}
'''.replace("POST_JOIN", post_join).replace("WAIT_HELPER", wait)
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
