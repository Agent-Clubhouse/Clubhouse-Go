#if DEBUG
import SwiftUI
import FramebriarUI
import ClubhouseTransport
import os
import Darwin

/// Producers only touch the bounded ring. Encoding and nonblocking IO belong exclusively to the writer queue.
nonisolated final class CompanionLiveConnectionTrace: @unchecked Sendable {
    private struct Record: Encodable, Sendable {
        let at: TimeInterval
        let operation: AnnexDiagnosticOperation
        let durationMs: Double
        let failure: AnnexDiagnosticFailure
        let events: [AnnexDiagnosticEvent]
    }
    private enum Entry: Sendable {
        case record(Record)
        case limit(lifecycle: Bool)
    }
    private struct Buffer {
        var records = [Record?](repeating: nil, count: 64)
        var head = 0, count = 0
        var connection = 256, lifecycle = 64
        var connectionLimit = false, lifecycleLimit = false
        var dropped = 0, pendingDrops = 0, written = 0
        mutating func drop() { dropped += 1; pendingDrops += 1 }
        mutating func take() -> Entry? {
            if count > 0 {
                let record = records[head]!
                records[head] = nil; head = (head + 1) % records.count; count -= 1
                return .record(record)
            }
            if connectionLimit { connectionLimit = false; return .limit(lifecycle: false) }
            if lifecycleLimit { lifecycleLimit = false; return .limit(lifecycle: true) }
            return nil
        }
    }
    private struct Output {
        var opened = false, stopped = false
        var descriptor: Int32 = -1
    }
    struct Snapshot {
        let buffered: Int
        let dropped: Int
        let written: Int
        let outputAvailable: Bool?
    }
    private let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private let output = OSAllocatedUnfairLock(initialState: Output())
    private let queue = DispatchQueue(label: "com.Agent-Clubhouse.Go.live-trace", qos: .utility)
    private let timer: any DispatchSourceTimer
    private let openOutput: @Sendable () -> Int32

    init(openOutput: @escaping @Sendable () -> Int32 = CompanionLiveConnectionTrace.openStandardOutput) {
        self.openOutput = openOutput
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        let buffer = buffer, output = output
        timer.setEventHandler { Self.drain(buffer: buffer, output: output, openOutput: openOutput) }
        timer.setCancelHandler { Self.close(output) }
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.resume()
    }
    nonisolated deinit { timer.cancel() }

    func append(_ record: AnnexDiagnosticRecord) {
        let lifecycle = [.foreground, .background, .disconnect].contains(record.operation)
            || record.events.contains(AnnexDiagnosticEvent.socketCancelStarted.rawValue)
            || record.events.contains(AnnexDiagnosticEvent.socketCancelCompleted.rawValue)
        guard lifecycle || [.pairing, .connection, .reconnect, .backoff, .identity, .capabilities,
                            .tls, .websocket, .http, .handshake].contains(record.operation) else { return }
        let value = Record(at: record.startedAt.timeIntervalSince1970, operation: record.operation,
                           durationMs: record.durationMs, failure: record.failure,
                           events: record.events.prefix(32).compactMap(AnnexDiagnosticEvent.init(rawValue:)))
        buffer.withLock { buffer in
            let remaining = lifecycle ? buffer.lifecycle : buffer.connection
            guard remaining >= 0 else { return }
            if lifecycle { buffer.lifecycle -= 1 } else { buffer.connection -= 1 }
            if remaining == 0 {
                if lifecycle { buffer.lifecycleLimit = true } else { buffer.connectionLimit = true }
            } else if buffer.count == buffer.records.count { buffer.drop() }
            else {
                buffer.records[(buffer.head + buffer.count) % buffer.records.count] = value
                buffer.count += 1
            }
        }
    }

    var snapshot: Snapshot {
        let available = output.withLock { $0.opened ? $0.descriptor >= 0 : nil }
        return buffer.withLock { Snapshot(buffered: $0.count, dropped: $0.dropped, written: $0.written,
                                         outputAvailable: available) }
    }

    /// A synthetic test can wait for one writer turn without waiting for a reader or a successful write.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { [buffer, output, openOutput] in
                Self.drain(buffer: buffer, output: output, openOutput: openOutput)
                continuation.resume()
            }
        }
    }
    func stop() async {
        timer.cancel()
        await withCheckedContinuation { continuation in
            queue.async { [output] in Self.close(output); continuation.resume() }
        }
    }

    private static func openStandardOutput() -> Int32 {
        // dup+F_SETFL would change stdout's shared flags. XCTest supplies a PTY; open it independently.
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ttyname_r(STDOUT_FILENO, &path, path.count) == 0 else { return -1 }
        return Darwin.open(path, O_WRONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
    }
    private static func close(_ output: OSAllocatedUnfairLock<Output>) {
        output.withLock { value in
            value.stopped = true
            if value.descriptor >= 0 { Darwin.close(value.descriptor); value.descriptor = -1 }
        }
    }
    private static func drain(buffer: OSAllocatedUnfairLock<Buffer>, output: OSAllocatedUnfairLock<Output>,
                              openOutput: @Sendable () -> Int32) {
        let descriptor = output.withLock { value -> Int32 in
            guard !value.stopped else { return -1 }
            if !value.opened {
                value.opened = true
                value.descriptor = openOutput()
                if value.descriptor >= 0 {
                    let flags = fcntl(value.descriptor, F_GETFL)
                    if flags < 0 || fcntl(value.descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
                        Darwin.close(value.descriptor); value.descriptor = -1
                    }
                }
            }
            return value.descriptor
        }
        func write(_ line: String) -> Bool {
            guard descriptor >= 0 else { return false }
            let data = Data((line + "\n").utf8)
            return data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count
            }
        }
        // At most the fixed ring plus its two exhaustion markers; never wait for writable output.
        for _ in 0..<66 {
            guard let entry = buffer.withLock({ $0.take() }) else { break }
            let line: String
            switch entry {
            case .record(let record):
                do {
                    let data = try JSONEncoder().encode(record)
                    line = "\n[live-connect] \(String(decoding: data, as: UTF8.self))"
                } catch {
                    buffer.withLock { $0.drop() }
                    continue
                }
            case .limit(let lifecycle):
                line = "\n[live-connect] capture-limit group=\(lifecycle ? "lifecycle" : "connection")"
            }
            let written = write(line)
            buffer.withLock { value in
                switch entry {
                case .record:
                    if written { value.written += 1 } else { value.drop() }
                case .limit(let lifecycle):
                    if !written {
                        if lifecycle { value.lifecycleLimit = true } else { value.connectionLimit = true }
                    }
                }
            }
            if case .limit = entry, !written { break }
        }
        let drops = buffer.withLock { ($0.pendingDrops, $0.dropped) }
        // Coalesce a blocked/full writer into one pending numeric marker, not a message per lost record.
        if drops.0 > 0, write("\n[live-connect] dropped-count=\(drops.0) total=\(drops.1)") {
            buffer.withLock { $0.pendingDrops -= drops.0 }
        }
    }
}

/// Hosted tests install synthetic stores and transports before any runtime is made.
@MainActor enum CompanionSceneTestSupport {
    static var liveConnectionTraceInstalled = false
    static var restoreRegistrations: (() async throws -> [AnnexTransportRegistry.Registration])?
    static var ready = false
    static weak var runtimeLifetime: CompanionStateLifetime<CompanionRuntime>?
    static var makeFeedback: (() -> (model: FeedbackModel, telemetry: CompanionTelemetry?))?
    static var feedbackPumpChanged: ((Bool) -> Void)?
    static var didCreateRuntime: ((CompanionRuntime) -> Void)?
}

struct CompanionSceneTestRoot: View {
    let runtimeLifetime: CompanionStateLifetime<CompanionRuntime>
    @State private var ready = false
    var body: some View {
        Group {
            if ready {
                CompanionAppRoot(runtimeLifetime: runtimeLifetime)
                    .onAppear { CompanionSceneTestSupport.runtimeLifetime = runtimeLifetime }
            }
            else { Text("Waiting for isolated scene fixture") }
        }.task {
            while !CompanionSceneTestSupport.ready {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            ready = true
        }
    }
}
#endif
