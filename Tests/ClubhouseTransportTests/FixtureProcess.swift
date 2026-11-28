#if os(macOS)
import Darwin
import Foundation
import Testing
import ClubhouseTransport

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

    /// The fixture's next output line, without its newline. Malformed past `limit` bytes.
    func readLine(limit: Int = 4096) async throws -> Data {
        try await offCooperativePool { handle in
            var line = Data()
            while let byte = try handle.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
                line.append(byte)
                guard line.count < limit else { throw AnnexTransportError.malformedResponse }
            }
            return line
        }
    }

    /// `FileHandle.read(upToCount:)` on the fixture's output, off the cooperative pool.
    func read(upToCount count: Int) async throws -> Data? {
        try await offCooperativePool { try $0.read(upToCount: count) }
    }

    /// Runs a blocking pipe read on a Dispatch thread, never on a Swift concurrency thread. A fixture can take
    /// seconds to start (node, then an openssl key), and swift test runs every test in parallel on a cooperative
    /// pool only as wide as the runner's cores. Reads that blocked those threads stalled every other test,
    /// including ones that measure their own deadlines on the live clock.
    private func offCooperativePool<T: Sendable>(_ read: @escaping @Sendable (FileHandle) throws -> T) async throws -> T {
        let handle = output.fileHandleForReading
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try read(handle) }) }
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
