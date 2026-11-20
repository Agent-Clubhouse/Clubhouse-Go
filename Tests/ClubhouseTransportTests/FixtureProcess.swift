#if os(macOS)
import Darwin
import Foundation
import Testing

/// A Node (or other) fixture process. Every blocking wait on it (its first output line, other pipe reads and
/// its exit) runs on a private dispatch queue and resumes the caller through a continuation, never on
/// Swift's cooperative pool: Swift Testing runs the whole package concurrently on that small pool, and a slow
/// Node start or exit blocking it stalls every other test's tasks (#611, #622). Deadlines are unchanged.
/// Unchecked Sendable: `Process`, `Pipe`/`FileHandle` and `DispatchGroup` are used from one waiter at a time.
final class FixtureProcess: @unchecked Sendable {
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

    private static let blocking = DispatchQueue(label: "FixtureProcess.blocking", attributes: .concurrent)

    /// Runs blocking `work` on the private queue and awaits its result without holding a cooperative thread.
    private func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.blocking.async { continuation.resume(with: Result { try work() }) }
        }
    }

    func waitForExit(timeout: DispatchTimeInterval) async -> Bool {
        let termination = termination
        return (try? await offPool { termination.wait(timeout: .now() + timeout) == .success }) ?? false
    }

    /// Reads one byte at a time up to the first newline (excluded) or end of output; throws `overflow()` once
    /// the line reaches `maxLength` bytes.
    func readLine(maxLength: Int, overflow: @escaping @Sendable () -> Error) async throws -> Data {
        let handle = output.fileHandleForReading
        return try await offPool {
            var line = Data()
            while let byte = try handle.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
                line.append(byte)
                guard line.count < maxLength else { throw overflow() }
            }
            return line
        }
    }

    func read(upToCount count: Int) async throws -> Data? {
        let handle = output.fileHandleForReading
        return try await offPool { try handle.read(upToCount: count) }
    }

    func stop(gracePeriod: DispatchTimeInterval = .seconds(2), killTimeout: DispatchTimeInterval = .seconds(2)) async {
        defer { closeOutput() }
        if process.isRunning { process.terminate() }
        if await waitForExit(timeout: gracePeriod) { return }
        if process.isRunning, Darwin.kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            Issue.record("Could not kill fixture process \(process.processIdentifier): errno \(errno)")
        }
        if !(await waitForExit(timeout: killTimeout)) {
            Issue.record("Fixture process \(process.processIdentifier) did not report termination before the deadline")
        }
    }

    /// Blocks the calling thread for at most `gracePeriod + killTimeout`. Only for timing the kill path itself
    /// (fixtureProcessKillsAChildThatIgnoresTermination), where an awaited stop would also time the resumption.
    func stopBlocking(gracePeriod: DispatchTimeInterval, killTimeout: DispatchTimeInterval = .seconds(2)) {
        defer { closeOutput() }
        if process.isRunning { process.terminate() }
        if termination.wait(timeout: .now() + gracePeriod) == .success { return }
        if process.isRunning, Darwin.kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            Issue.record("Could not kill fixture process \(process.processIdentifier): errno \(errno)")
        }
        if termination.wait(timeout: .now() + killTimeout) != .success {
            Issue.record("Fixture process \(process.processIdentifier) did not report termination before the deadline")
        }
    }

    /// Runs `body`, then always stops the fixture, like the `defer { stop() }` it replaces (an async stop can't be deferred).
    func use<T>(_ body: () async throws -> T) async throws -> T {
        let result: Result<T, Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        await stop()
        return try result.get()
    }

    private func closeOutput() {
        do { try output.fileHandleForReading.close() }
        catch { Issue.record(error) }
        do { try output.fileHandleForWriting.close() }
        catch { Issue.record(error) }
    }
}
#endif
