#if DEBUG
import SwiftUI
import Framebriar
import FramebriarUI
import ClubhouseTransport
import CryptoKit
import ImageIO

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
    // App/scene updates may evaluate and discard this View's initial State value.
    // Only the installed lifetime may create a client or register screenshot observers.
    @State private var lifetime: CompanionStateLifetime<(model: FeedbackModel, transport: PreviewFeedbackTransport, presenter: CompanionFeedbackPresenter)>
    private var model: FeedbackModel { lifetime.value.model }
    private var presenter: CompanionFeedbackPresenter { lifetime.value.presenter }
    @State private var password = ""
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var enabled = true
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var captureScreen = true
    @State private var settingsCapture: CompanionFeedbackSettingsCapture?
    @State private var showingOther = false
    @State private var lastResponder = "none"
    @State private var selection: String?
    @State private var wireSummary = "{}"
    @State private var captureState = ""
    private var isWireFixture: Bool { ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing") }
    private let companionLayout = ProcessInfo.processInfo.arguments.contains("--framebriar-shake-companion-layout")
    private var transport: PreviewFeedbackTransport { lifetime.value.transport }
    // SwiftUI can recreate this value after a settings or scene update. Seed the
    // fixture once per process, never overwrite the user's toggle on recreation.
    private static let initializePreference: Void = {
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakePreferenceKey)
        UserDefaults.standard.set(true, forKey: CompanionFeedback.shakeScreenshotPreferenceKey)
        UserDefaults.standard.set(true, forKey: CompanionScreenshotFeedback.preferenceKey)
    }()
    init() {
        _ = Self.initializePreference
        _lifetime = State(initialValue: CompanionStateLifetime {
            let (model, transport) = Self.fixtureModel(enrolled: !ProcessInfo.processInfo.arguments.contains("--framebriar-shake-unenrolled"))
            return (model, transport, CompanionFeedbackPresenter(model: model))
        })
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
        .sheet(item: $settingsCapture) { capture in
            NavigationStack {
                Form {
                    Button("Simulate shake in Settings") { PreviewMotionProbe.shake() }
                    CompanionFeedbackSettings(model: model, initialCapture: capture)
                }
                    .navigationTitle("Fixture settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsCapture = nil } } }
            }.environment(\.companionFeedbackFixtureControls, isWireFixture ? Self.wireControls : nil)
                .onDisappear { capture.screenshot = nil }
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
                    let next = transport.wireSummary(initialScreenshotSHA: CompanionFeedbackPresenter.fixtureInitialScreenshotSHA)
                    if wireSummary != next { wireSummary = next }
                    let nextCapture = presenter.fixtureCaptureState
                    if captureState != nextCapture { captureState = nextCapture }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
        }
    }

    /// One bridge/model per fixture process; view recreation cannot orphan its diagnostics sink.
    private static let wireFixture: (model: FeedbackModel, transport: PreviewFeedbackTransport, bridge: CompanionTelemetry, source: AnnexTelemetry) = {
        let transport = PreviewFeedbackTransport(wire: true), source = AnnexTelemetry()
        let config = try! Configuration(gameID: "simulator-fixture", buildSHA: "abcdef0", endpoint: URL(string: "https://fixture.invalid/api")!)
        let client = try! Client(configuration: config, transport: transport, enrollmentStore: PreviewEnrollment(enrolled: true), feedbackStore: PreviewQueue(
            failFirstSave: ProcessInfo.processInfo.arguments.contains("--feedback-save-failure"), observer: transport))
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
            ? UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
                UIColor.magenta.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
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
                    .toolbar {
                        if isWireFixture {
                            ToolbarItem(placement: .topBarTrailing) { fixtureFeedbackMenu }
                        }
                    }
            }
        }
    }

    /// Exercise the public native menu event without synthesizing a source-control touch.
    private func activateMenuWithoutTouch() {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "fixture-feedback-menu" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        if let window = CompanionFeedbackPresenter.keyWindow(), let control = find(window) as? UIControl {
            control.sendActions(for: .menuActionTriggered)
            presenter.sendMenuFeedback()
        }
    }

    private var fixtureFeedbackMenu: some View {
        Menu {
            Button("Send feedback") { presenter.sendMenuFeedback() }
            Button("Do nothing") {}
        } label: { Label("Feedback menu", systemImage: "ellipsis") }
            .accessibilityIdentifier("fixture-feedback-menu")
    }

    @ViewBuilder private var fixtureControls: some View {
        Text("Synthetic feedback fixture")
        if isWireFixture {
            Color(red: 0.9, green: 0.05, blue: 0.7).frame(height: 140)
                .accessibilityLabel("Underlying app content").accessibilityIdentifier("fixture-screen-marker")
            Button("Open feedback through native menu event") { activateMenuWithoutTouch() }
                .accessibilityIdentifier("fixture-activate-feedback-menu")
        }
        if isWireFixture {
            Text(captureState).accessibilityIdentifier("fixture-capture-state")
            Text(wireSummary).font(.caption2).lineLimit(1).accessibilityIdentifier("fixture-wire-summary")
        }
        Text("Queued: \(model.status?.queued ?? 0) · Network: \(transport.count)").accessibilityIdentifier("fixture-counters")
        Button("Simulate shake") { lastResponder = PreviewMotionProbe.shake() }.accessibilityIdentifier("fixture-shake")
        Button("Simulate repeated shake") { for _ in 0..<3 { lastResponder = PreviewMotionProbe.shake() } }
        Text("Responder: \(lastResponder)").accessibilityIdentifier("fixture-responder")
        Button("Settings") {
            settingsCapture = CompanionFeedbackSettingsCapture(window: CompanionFeedbackPresenter.keyWindow())
        }
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
    nonisolated(unsafe) private var failFirstSave: Bool
    nonisolated private let observer: PreviewFeedbackTransport?
    init(seed: [QueuedFeedback] = [], failFirstSave: Bool = false, observer: PreviewFeedbackTransport? = nil) {
        items = seed; self.failFirstSave = failFirstSave; self.observer = observer
    }
    nonisolated func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    nonisolated func save(_ items: [QueuedFeedback], scope: String) throws {
        try lock.withLock {
            observer?.recordSave(items)
            if failFirstSave { failFirstSave = false; throw FramebriarError.storage }
            self.items = items
        }
    }
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
    nonisolated(unsafe) private var media: [Data] = []
    nonisolated(unsafe) private var saves: [[String: String]] = []
    nonisolated func recordSave(_ items: [QueuedFeedback]) {
        let records = items.map { item in
            ["id": item.feedback.id.uuidString.lowercased(),
             "sha256": item.feedback.screenshotPNG.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none"]
        }
        lock.withLock { saves.append(contentsOf: records) }
    }
    init(wire: Bool = false) { self.wire = wire }
    nonisolated var count: Int { lock.withLock { requests } }
    nonisolated func recordCapture(_ value: FeedbackDiagnostics) {
        if let data = try? JSONEncoder().encode(value) { lock.withLock { captures.append(data) } }
    }
    nonisolated func recordIncident(_ value: FeedbackIncident?) {
        if let value, let data = try? JSONEncoder().encode(value) { lock.withLock { incidents.append(data) } }
    }
    nonisolated func changedEnrollment() { lock.withLock { changes += 1 } }
    nonisolated func wireSummary(initialScreenshotSHA: String?) -> String {
        lock.withLock {
            func objects(_ values: [Data]) -> [Any] { values.suffix(20).compactMap { try? JSONSerialization.jsonObject(with: $0) } }
            let result: [String: Any] = ["initialScreenshotSHA": initialScreenshotSHA as Any? ?? NSNull(), "reports": objects(reports), "telemetry": objects(telemetryBodies),
                "captures": objects(captures), "incidents": objects(incidents), "enrollmentChanges": changes, "saves": saves, "media": media.map(Self.mediaEvidence)]
            return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }
    /// Keep the accessibility fixture small, while binding pixel evidence to the actual upload bytes.
    nonisolated private static func mediaEvidence(_ png: Data) -> [String: Any] {
        let output = NSMutableData()
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary),
           let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        var evidence: [String: Any] = ["sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                "bytes": png.count, "samplePNG": (output as Data).base64EncodedString()]
        // Small synthetic editor fixtures expose the exact PUT body, without bloating screen captures.
        if let image = UIImage(data: png)?.cgImage, image.width <= 1024, image.height <= 1024 {
            evidence["uploadedPNG"] = png.base64EncodedString()
        }
        return evidence
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
            reply = ["id": report["id"]!, "status": report["media"] is [String: Any] ? "pending" : "ready",
                     "ticket": String(repeating: "u", count: 43), "gameId": "simulator-fixture"]
        } else if path.hasSuffix("/media") {
            lock.withLock { media.append(request.httpBody!) }
            reply = ["id": request.url!.deletingLastPathComponent().lastPathComponent, "status": "ready", "gameId": "simulator-fixture"]
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
