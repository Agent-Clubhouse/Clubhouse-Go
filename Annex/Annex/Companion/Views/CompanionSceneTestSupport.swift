#if DEBUG
import SwiftUI
import FramebriarUI
import ClubhouseTransport

/// Hosted tests install synthetic stores and transports before any runtime is made.
@MainActor enum CompanionSceneTestSupport {
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
