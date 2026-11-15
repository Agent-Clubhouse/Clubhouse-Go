#if DEBUG
import SwiftUI
import FramebriarUI
import ClubhouseTransport
import os

/// Opt-in E2E stdout capture; reserve lifecycle evidence even if routine connection records reach their cap.
nonisolated final class CompanionLiveConnectionTrace: Sendable {
    private let budget = OSAllocatedUnfairLock(initialState: (connection: 256, lifecycle: 64))

    func line(for record: AnnexDiagnosticRecord) -> String? {
        let lifecycle = [.foreground, .background, .disconnect].contains(record.operation)
            || record.events.contains(AnnexDiagnosticEvent.socketCancelStarted.rawValue)
            || record.events.contains(AnnexDiagnosticEvent.socketCancelCompleted.rawValue)
        guard lifecycle || [.pairing, .connection, .reconnect, .backoff, .identity, .capabilities,
                            .tls, .websocket, .http, .handshake].contains(record.operation) else { return nil }
        let remaining = budget.withLock { value in
            let remaining = lifecycle ? value.lifecycle : value.connection
            if remaining >= 0 {
                if lifecycle { value.lifecycle -= 1 } else { value.connection -= 1 }
            }
            return remaining
        }
        guard remaining >= 0 else { return nil }
        if remaining == 0 { return "[live-connect] capture-limit group=\(lifecycle ? "lifecycle" : "connection")" }
        let value: [String: Any] = ["at": record.startedAt.timeIntervalSince1970,
            "operation": record.operation.rawValue, "durationMs": record.durationMs,
            "failure": record.failure.rawValue, "events": record.events]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            return "[live-connect] \(String(decoding: bytes, as: UTF8.self))"
        } catch { return "[live-connect] encoding-failed" }
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
