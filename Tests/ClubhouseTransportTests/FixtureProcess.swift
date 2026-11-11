#if os(macOS)
import Darwin
import Foundation
import Testing

final class FixtureProcess {
    let process = Process()
    let output = Pipe()
    private let termination = DispatchGroup()

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"), arguments: [String]) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Register before launch: waitUntilExit can miss a wake-up on an async test's run loop.
        termination.enter()
        let termination = termination
        process.terminationHandler = { _ in termination.leave() }
        do {
            try process.run()
        } catch {
            closeOutput()
            throw error
        }
    }

    func waitForExit(timeout: DispatchTimeInterval) -> Bool {
        termination.wait(timeout: .now() + timeout) == .success
    }

    func stop(gracePeriod: DispatchTimeInterval = .seconds(2), killTimeout: DispatchTimeInterval = .seconds(2)) {
        defer { closeOutput() }
        if process.isRunning { process.terminate() }
        if waitForExit(timeout: gracePeriod) { return }
        if process.isRunning, Darwin.kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            Issue.record("Could not kill fixture process \(process.processIdentifier): errno \(errno)")
        }
        if !waitForExit(timeout: killTimeout) {
            Issue.record("Fixture process \(process.processIdentifier) did not report termination before the deadline")
        }
    }

    private func closeOutput() {
        do { try output.fileHandleForReading.close() }
        catch { Issue.record(error) }
        do { try output.fileHandleForWriting.close() }
        catch { Issue.record(error) }
    }
}
#endif
