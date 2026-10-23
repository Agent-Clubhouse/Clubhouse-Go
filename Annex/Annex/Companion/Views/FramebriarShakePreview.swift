#if DEBUG
import SwiftUI
import Framebriar
import FramebriarUI

/// Isolated simulator fixture: in-memory enrollment/outbox and a transport that cannot use a socket.
/// Accessible only through the explicit debug launch flag; no paired desktop or Keychain is read.
struct FramebriarShakePreview: View {
    @State private var model: FeedbackModel
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var enabled = true
    @State private var showingSettings = false
    @State private var showingOther = false
    private let transport: PreviewFeedbackTransport
    init() {
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakePreferenceKey)
        let transport = PreviewFeedbackTransport()
        self.transport = transport
        let client = try! Client(configuration: Configuration(gameID: "simulator-fixture"), transport: transport,
                                 enrollmentStore: PreviewEnrollment(), feedbackStore: PreviewQueue())
        _model = State(initialValue: FeedbackModel(client: client))
    }
    var body: some View {
        NavigationStack {
            List {
                Text("Synthetic feedback fixture")
                Text("Queued: \(model.status?.queued ?? 0) · Network: \(transport.count)").accessibilityIdentifier("fixture-counters")
                Button("Simulate shake") { PreviewMotionProbe.shake() }.accessibilityIdentifier("fixture-shake")
                Button("Simulate repeated shake") { for _ in 0..<3 { PreviewMotionProbe.shake() } }
                Button("Settings") { showingSettings = true }
                Button("Present other screen") { showingOther = true }
            }.navigationTitle("Shake fixture")
        }
        .shakeToOpenFeedback(model: model, enabled: enabled, isPresenting: showingSettings || showingOther)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form { CompanionFeedbackSettings(model: model) }
                    .navigationTitle("Fixture settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } }
            }
        }
        .sheet(isPresented: $showingOther) {
            NavigationStack {
                List {
                    Text("Another presentation")
                    Button("Simulate shake while presented") { PreviewMotionProbe.shake() }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOther = false } } }
            }
        }
        .task { await model.setActive(true) }
    }
}

private struct PreviewEnrollment: EnrollmentStore {
    nonisolated func load(scope: String) throws -> EnrollmentRecord { EnrollmentRecord(enrolled: true, notice: .offline) }
    nonisolated func save(_ record: EnrollmentRecord, scope: String) throws {}
}
private final class PreviewQueue: FeedbackStore, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    nonisolated(unsafe) private var items: [QueuedFeedback] = []
    nonisolated func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    nonisolated func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { self.items = items } }
}
private final class PreviewFeedbackTransport: HTTPTransport, @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var requests = 0
    nonisolated var count: Int { lock.withLock { requests } }
    nonisolated func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { requests += 1 }; throw FramebriarError.network
    }
}
@MainActor private enum PreviewMotionProbe {
    static weak var responder: UIResponder?
    static func shake() {
        responder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.framebriarPreviewCaptureResponder), to: nil, from: nil, for: nil)
        responder?.motionEnded(.motionShake, with: nil)
        responder = nil
    }
}
private extension UIResponder {
    @objc func framebriarPreviewCaptureResponder() { PreviewMotionProbe.responder = self }
}
#endif
