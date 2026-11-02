#if DEBUG
import SwiftUI
import Framebriar
import FramebriarUI
import ClubhouseTransport

/// Only injected into the isolated fake-wire fixture; never present in a normal app launch.
struct CompanionFeedbackFixtureControls {
    let changeEnrollment: @MainActor () -> Void
    let recordLater: @MainActor () -> Void
    let image: Data?
    let captureIsEnabled: @MainActor () -> Bool
}
extension EnvironmentValues {
    @Entry var companionFeedbackFixtureControls: CompanionFeedbackFixtureControls? = nil
}

/// Isolated simulator fixture: in-memory enrollment/outbox and a transport that cannot use a socket.
/// Accessible only through the explicit debug launch flag; no paired desktop or Keychain is read.
struct FramebriarShakePreview: View {
    @State private var model: FeedbackModel
    @State private var presenter: CompanionFeedbackPresenter
    @State private var password = ""
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var enabled = true
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var captureScreen = true
    @State private var showingSettings = false
    @State private var showingOther = false
    @State private var lastResponder = "none"
    @State private var selection: String?
    @State private var wireSummary = "{}"
    private var isWireFixture: Bool { ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing") }
    private let companionLayout = ProcessInfo.processInfo.arguments.contains("--framebriar-shake-companion-layout")
    private let transport: PreviewFeedbackTransport
    // SwiftUI can recreate this value after a settings or scene update. Seed the
    // fixture once per process, never overwrite the user's toggle on recreation.
    private static let initializePreference: Void = {
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakePreferenceKey)
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakeScreenshotPreferenceKey)
        UserDefaults.standard.set(true, forKey: CompanionScreenshotFeedback.preferenceKey)
    }()
    init() {
        _ = Self.initializePreference
        let (model, transport) = Self.fixtureModel(enrolled: !ProcessInfo.processInfo.arguments.contains("--framebriar-shake-unenrolled"))
        self.transport = transport
        _model = State(initialValue: model)
        _presenter = State(initialValue: CompanionFeedbackPresenter(model: model))
    }
    /// In-memory enrollment and outbox; the transport counts requests and never opens a socket.
    static func fixtureModel(enrolled: Bool) -> (FeedbackModel, PreviewFeedbackTransport) {
        if ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing") { return (wireFixture.model, wireFixture.transport) }
        let transport = PreviewFeedbackTransport()
        let config = try! Configuration(gameID: "simulator-fixture")
        let held = ProcessInfo.processInfo.arguments.contains("--framebriar-held-ui-testing")
            ? (0..<2).map { index in QueuedFeedback(feedback: try! ReviewedFeedback(configuration: config, notes: "Held fixture \(index)"),
                                                  blocked: true, enrollmentRef: "previous-fixture", heldForEnrollment: true) } : []
        let client = try! Client(configuration: config, transport: transport,
                                 enrollmentStore: PreviewEnrollment(enrolled: enrolled), feedbackStore: PreviewQueue(seed: held))
        return (FeedbackModel(client: client), transport)
    }
    var body: some View {
        fixtureRoot
        .companionFeedbackShake(presenter, enabled: enabled, captureScreen: captureScreen)
        .companionFeedbackEntryPoints(presenter)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Button("Simulate shake in Settings") { PreviewMotionProbe.shake() }
                    CompanionFeedbackSettings(model: model)
                }
                    .navigationTitle("Fixture settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } }
            }.environment(\.companionFeedbackFixtureControls, isWireFixture ? Self.wireControls : nil)
        }
        .sheet(isPresented: $showingOther) {
            NavigationStack {
                List {
                    Text("Another presentation")
                    Button("Simulate shake while presented") { PreviewMotionProbe.shake() }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOther = false } } }
            }
        }
        .task {
            await model.setActive(true)
            if isWireFixture {
                await model.tick() // synthetic refresh; establishes SDK telemetry eligibility
                while !Task.isCancelled {
                    let next = transport.wireSummary
                    if wireSummary != next { wireSummary = next }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
        }
    }

    /// One bridge/model per fixture process; view recreation cannot orphan its diagnostics sink.
    private static let wireFixture: (model: FeedbackModel, transport: PreviewFeedbackTransport, bridge: CompanionTelemetry, source: AnnexTelemetry) = {
        let transport = PreviewFeedbackTransport(wire: true), source = AnnexTelemetry()
        let config = try! Configuration(gameID: "simulator-fixture", buildSHA: "abcdef0", endpoint: URL(string: "https://fixture.invalid/api")!)
        let client = try! Client(configuration: config, transport: transport, enrollmentStore: PreviewEnrollment(enrolled: true), feedbackStore: PreviewQueue())
        CompanionFeedback.adoptSession(of: source)
        let bridge = try! CompanionTelemetry(client: client, configuration: config, source: source, transport: transport, observeAppLifecycle: false)
        recordRetry(on: source, failure: .timeout)
        let model = FeedbackModel(client: client, telemetry: bridge.telemetry, incidentProvider: {
            let value = CompanionFeedback.snapshotIncident(telemetry: source)
            transport.recordIncident(value)
            return value
        }, diagnosticsProvider: {
            let value = CompanionFeedback.diagnosticsSnapshot(from: source)
            transport.recordCapture(value)
            return value
        }, reportDiagnostics: .off)
        return (model, transport, bridge, source)
    }()
    private static func recordRetry(on source: AnnexTelemetry, failure: AnnexDiagnosticFailure) {
        let failed = source.begin(.connection)
        failed.identifier(.connectionID, UUID()); failed.identifier(.connectionAttemptID, UUID())
        failed.fail(failure); failed.end()
        let retry = source.begin(.backoff)
        retry.number(.attempt, 3); retry.number(.backoffMs, 30_000); retry.end()
    }
    private static var wireControls: CompanionFeedbackFixtureControls {
        let parts = wireFixture
        let image = ProcessInfo.processInfo.arguments.contains("--framebriar-wire-image")
            ? UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }.pngData() : nil
        return CompanionFeedbackFixtureControls(changeEnrollment: {
            Task {
                await parts.model.connect(String(repeating: "i", count: 43))
                parts.source.clear()
                recordRetry(on: parts.source, failure: .dns)
                parts.transport.changedEnrollment()
            }
        }, recordLater: {
            let later = parts.source.begin(.websocket); later.fail(.tooLarge); later.end()
        }, image: image, captureIsEnabled: { parts.source.isEnabled })
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
        if isWireFixture {
            Text(wireSummary).font(.caption2).lineLimit(1).accessibilityIdentifier("fixture-wire-summary")
        }
        Text("Queued: \(model.status?.queued ?? 0) · Network: \(transport.count)").accessibilityIdentifier("fixture-counters")
        Button("Simulate shake") { lastResponder = PreviewMotionProbe.shake() }.accessibilityIdentifier("fixture-shake")
        Button("Simulate repeated shake") { for _ in 0..<3 { lastResponder = PreviewMotionProbe.shake() } }
        Text("Responder: \(lastResponder)").accessibilityIdentifier("fixture-responder")
        Button("Settings") { showingSettings = true }
        Button("Present other screen") { showingOther = true }
        // What iOS posts after the side and volume buttons take a screenshot.
        Button("Simulate screenshot") {
            NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: UIApplication.shared)
        }.accessibilityIdentifier("fixture-screenshot")
        SecureField("Fixture password", text: $password)
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
        enrolled ? EnrollmentRecord(refreshToken: String(repeating: "r", count: 43), expiresAt: PreviewFeedbackTransport.enrollmentDeadline,
                                    enrolled: true, notice: .offline) : EnrollmentRecord()
    }
    nonisolated func save(_ record: EnrollmentRecord, scope: String) throws {}
}
private final class PreviewQueue: FeedbackStore, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    nonisolated(unsafe) private var items: [QueuedFeedback]
    init(seed: [QueuedFeedback] = []) { items = seed }
    nonisolated func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    nonisolated func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { self.items = items } }
}
final class PreviewFeedbackTransport: HTTPTransport, @unchecked Sendable {
    nonisolated static let enrollmentDeadline = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86400)
    nonisolated private let lock = NSLock()
    nonisolated private let wire: Bool
    nonisolated(unsafe) private var requests = 0
    nonisolated(unsafe) private var reports: [Data] = []
    nonisolated(unsafe) private var telemetryBodies: [Data] = []
    nonisolated(unsafe) private var captures: [Data] = []
    nonisolated(unsafe) private var incidents: [Data] = []
    nonisolated(unsafe) private var changes = 0
    init(wire: Bool = false) { self.wire = wire }
    nonisolated var count: Int { lock.withLock { requests } }
    nonisolated func recordCapture(_ value: FeedbackDiagnostics) {
        if let data = try? JSONEncoder().encode(value) { lock.withLock { captures.append(data) } }
    }
    nonisolated func recordIncident(_ value: FeedbackIncident?) {
        if let value, let data = try? JSONEncoder().encode(value) { lock.withLock { incidents.append(data) } }
    }
    nonisolated func changedEnrollment() { lock.withLock { changes += 1 } }
    nonisolated var wireSummary: String {
        lock.withLock {
            func objects(_ values: [Data]) -> [Any] { values.suffix(20).compactMap { try? JSONSerialization.jsonObject(with: $0) } }
            let result: [String: Any] = ["reports": objects(reports), "telemetry": objects(telemetryBodies),
                "captures": objects(captures), "incidents": objects(incidents), "enrollmentChanges": changes]
            return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }
    nonisolated func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { requests += 1 }
        guard wire else { throw FramebriarError.network }
        let path = request.url!.path
        let reply: [String: Any]
        if path.contains("/otlp/") {
            lock.withLock { telemetryBodies.append(request.httpBody ?? Data()) }
            reply = [:]
        } else if path.hasSuffix("/reports") {
            lock.withLock { reports.append(request.httpBody!) }
            let report = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            reply = ["id": report["id"]!, "status": "ready", "gameId": "simulator-fixture"]
        } else {
            reply = ["v": 1, "scopeVersion": 2, "gameId": "simulator-fixture", "feedbackCorrelationVersion": 1,
                "token": String(repeating: "t", count: 43), "refreshToken": String(repeating: "r", count: 43),
                "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(), "refreshExpiresAt": Self.enrollmentDeadline.ISO8601Format()]
        }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: reply))
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
        // A window-level callback receives the event even when no view has first responder.
        // Start at the responder when present to exercise its chain, otherwise use the key window.
        (responder ?? CompanionFeedbackPresenter.keyWindow())?.motionEnded(.motionShake, with: nil)
        responder = nil
        return name
    }
}
private extension UIResponder {
    @objc func framebriarPreviewCaptureResponder() { PreviewMotionProbe.responder = self }
}
#endif
