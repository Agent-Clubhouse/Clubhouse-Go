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
    @State private var lastResponder = "none"
    @State private var selection: String?
    private let companionLayout = ProcessInfo.processInfo.arguments.contains("--framebriar-shake-companion-layout")
    private let transport: PreviewFeedbackTransport
    // SwiftUI can recreate this value after a settings or scene update. Seed the
    // fixture once per process, never overwrite the user's toggle on recreation.
    private static let initializePreference: Void = {
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakePreferenceKey)
    }()
    init() {
        _ = Self.initializePreference
        let transport = PreviewFeedbackTransport()
        self.transport = transport
        let client = try! Client(configuration: Configuration(gameID: "simulator-fixture"), transport: transport,
                                 enrollmentStore: PreviewEnrollment(enrolled: !ProcessInfo.processInfo.arguments.contains("--framebriar-shake-unenrolled")),
                                 feedbackStore: PreviewQueue())
        _model = State(initialValue: FeedbackModel(client: client))
    }
    var body: some View {
        fixtureRoot
        .shakeToOpenFeedback(model: model, enabled: enabled, isPresenting: showingSettings || showingOther)
        .shakeToExplainFeedbackEnrollment(model: model, enabled: $enabled, isPresenting: showingSettings || showingOther)
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

    @ViewBuilder private var fixtureRoot: some View {
        if companionLayout {
            // Mirrors CompanionRootView: split view, searchable sidebar, detail with a focusable composer.
            NavigationSplitView {
                List(selection: $selection) {
                    fixtureControls
                    NavigationLink("Fixture conversation", value: "conversation")
                }
                .searchable(text: .constant(""), prompt: "Find an agent or task")
                .navigationTitle("Shake fixture")
            } detail: {
                if selection != nil { FixtureConversation(lastResponder: $lastResponder) }
                else { Text("Choose a conversation") }
            }
        } else {
            NavigationStack {
                List { fixtureControls }.navigationTitle("Shake fixture")
            }
        }
    }

    @ViewBuilder private var fixtureControls: some View {
        Text("Synthetic feedback fixture")
        Text("Queued: \(model.status?.queued ?? 0) · Network: \(transport.count)").accessibilityIdentifier("fixture-counters")
        Button("Simulate shake") { lastResponder = PreviewMotionProbe.shake() }.accessibilityIdentifier("fixture-shake")
        Button("Simulate repeated shake") { for _ in 0..<3 { lastResponder = PreviewMotionProbe.shake() } }
        Text("Responder: \(lastResponder)").accessibilityIdentifier("fixture-responder")
        Button("Settings") { showingSettings = true }
        Button("Present other screen") { showingOther = true }
    }
}

private struct FixtureConversation: View {
    @Binding var lastResponder: String
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    var body: some View {
        List {
            Text("Fixture conversation")
            Button("Simulate shake in conversation") { lastResponder = PreviewMotionProbe.shake() }
            Button("Dismiss keyboard") { composerFocused = false }
            Text("Responder: \(lastResponder)").accessibilityIdentifier("fixture-detail-responder")
        }
        .safeAreaInset(edge: .bottom) {
            TextField("Fixture composer", text: $draft).focused($composerFocused)
                .textFieldStyle(.roundedBorder).padding().background(.bar)
        }
    }
}

private struct PreviewEnrollment: EnrollmentStore {
    let enrolled: Bool
    nonisolated func load(scope: String) throws -> EnrollmentRecord {
        enrolled ? EnrollmentRecord(enrolled: true, notice: .offline) : EnrollmentRecord()
    }
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
    /// Delivers a shake the way UIKit does: to the current first responder (if any).
    /// Returns that responder's type so tests can see who would actually receive a real shake.
    @discardableResult static func shake() -> String {
        responder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.framebriarPreviewCaptureResponder), to: nil, from: nil, for: nil)
        let name = responder.map { String(describing: type(of: $0)) } ?? "none"
        responder?.motionEnded(.motionShake, with: nil)
        responder = nil
        return name
    }
}
private extension UIResponder {
    @objc func framebriarPreviewCaptureResponder() { PreviewMotionProbe.responder = self }
}
#endif
