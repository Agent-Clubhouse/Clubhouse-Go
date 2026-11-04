#if DEBUG
import SwiftUI
import FramebriarUI

/// Hosted tests install synthetic stores and transports before any runtime is made.
@MainActor enum CompanionSceneTestSupport {
    static var ready = false
    static var makeFeedback: (() -> (model: FeedbackModel, telemetry: CompanionTelemetry?))?
    static var didCreateRuntime: ((CompanionRuntime) -> Void)?
}

struct CompanionSceneTestRoot: View {
    @State private var ready = false
    var body: some View {
        Group {
            if ready { CompanionAppRoot() }
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
