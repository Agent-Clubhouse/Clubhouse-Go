import Framebriar
import FramebriarUI
import ObjectiveC
import SwiftUI
import UIKit

/// Test fixture only. In-memory stores and a fake transport: it opens no socket and has no real invitation.
/// Launch arguments: --callback (route through `onFeedbackShake`), --offline, --not-enrolled, --no-capture,
/// --passthrough-window (a non-key overlay like a host's PassthroughWindow).
@MainActor @Observable final class Counters {
    static let shared = Counters()
    var chain = 0
    var perform = 0
    var captures = 0
    var notEnrolled = 0
    var probe = 0
}

final class MemoryEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock(); private var record = EnrollmentRecord()
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
final class MemoryQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock(); private var items: [QueuedFeedback] = []
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { self.items = items } }
}
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let offline: Bool
    init(offline: Bool) { self.offline = offline }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let reply: [String: Any]
        if request.url!.path.hasSuffix("/v1/access/redeem") {
            let f = ISO8601DateFormatter()
            reply = ["v": 1, "scopeVersion": 2, "gameId": "harness", "token": String(repeating: "b", count: 43), "refreshToken": String(repeating: "r", count: 43),
                     "expiresAt": f.string(from: Date() + 3600), "refreshExpiresAt": f.string(from: Date() + 86400)]
        } else {
            if offline { throw FramebriarError.network }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            reply = ["id": body?["id"] ?? "", "status": "ready", "gameId": "harness"]
        }
        return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: reply))
    }
}

@MainActor func makeHarnessModel(offline: Bool, enrolled: Bool) async throws -> FeedbackModel {
    let config = try Configuration(gameID: "harness", endpoint: URL(string: "https://harness.invalid/api")!)
    let client = try Client(configuration: config, transport: FakeTransport(offline: offline), enrollmentStore: MemoryEnrollment(), feedbackStore: MemoryQueue())
    await client.resume()
    if enrolled { try await client.connect(invitation: String(repeating: "i", count: 43)) }
    let model = FeedbackModel(client: client, diagnosticsProvider: {
        FeedbackDiagnostics(windowStart: Date() - 60, windowEnd: Date(), entries: [
            .init(at: Date() - 2, level: .warn, ns: "transport", event: "connect.failed", attrs: ["failure": "timeout", "attempt": 1]),
            .init(at: Date() - 1, level: .error, ns: "transport", event: "socket.closed", attrs: ["closeCode": 1006])
        ])
    })
    await model.update()
    return model
}

/// Counts `motionEnded` where the chain reaches UIApplication, past every window, so a test can tell
/// "the event was delivered and the chain continued" from "the composer opened".
enum ChainProbe {
    static let installed: Void = {
        let selector = #selector(UIResponder.motionEnded(_:with:))
        let method = class_getInstanceMethod(UIApplication.self, selector)!
        typealias Fn = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = { object, motion, event in
            MainActor.assumeIsolated { Counters.shared.chain += 1 }
            original(object, selector, motion, event)
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(UIApplication.self, selector, implementation, method_getTypeEncoding(method)) { method_setImplementation(method, implementation) }
    }()
}

/// A non-key overlay window, overriding the same things as Clubhouse Go's PassthroughWindow.
final class PassthroughWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

/// A host responder with its own `motionEnded`, which must still run.
final class ResponderProbe: UIView {
    override var canBecomeFirstResponder: Bool { true }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        Counters.shared.probe += 1
        super.motionEnded(motion, with: event)
    }
}
struct ResponderProbeView: UIViewRepresentable {
    let claim: Bool
    func makeUIView(context: Context) -> ResponderProbe { ResponderProbe() }
    func updateUIView(_ view: ResponderProbe, context: Context) {
        if claim, !view.isFirstResponder { view.becomeFirstResponder() } else if !claim, view.isFirstResponder { view.resignFirstResponder() }
    }
}

struct CounterStrip: View {
    @State private var counters = Counters.shared
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(counters.chain)").accessibilityIdentifier("count-chain")
            Text("\(counters.perform)").accessibilityIdentifier("count-perform")
            Text("\(counters.captures)").accessibilityIdentifier("count-capture")
            Text("\(counters.notEnrolled)").accessibilityIdentifier("count-not-enrolled")
            Text("\(counters.probe)").accessibilityIdentifier("count-probe")
        }.font(.caption2)
    }
}

struct SheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                CounterStrip()
                TextField("Sheet field", text: $text).focused($focused).accessibilityIdentifier("sheet-field")
                Button("Resign sheet field") { focused = false }.accessibilityIdentifier("sheet-resign")
                Button("Close sheet") { dismiss() }.accessibilityIdentifier("close-sheet")
            }.navigationTitle("Host sheet")
        }
    }
}

struct RootView: View {
    let model: FeedbackModel
    let callback: Bool
    let capture: Bool
    @State private var plain = ""
    @State private var secure = ""
    @State private var showSheet = false
    @State private var claim = false
    @State private var presenter = HostPresenter()
    @FocusState private var focus: Field?
    enum Field { case plain, secure }

    var body: some View {
        let base = Form {
            CounterStrip()
            TextField("Plain field", text: $plain).focused($focus, equals: .plain).accessibilityIdentifier("field-plain")
            SecureField("Secure field", text: $secure).focused($focus, equals: .secure).accessibilityIdentifier("field-secure")
            Button("Resign") { focus = nil }.accessibilityIdentifier("resign")
            Button("Open sheet") { showSheet = true }.accessibilityIdentifier("open-sheet")
            Button("Toggle responder") { claim.toggle() }.accessibilityIdentifier("toggle-responder")
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button("New scene") { UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) }.accessibilityIdentifier("new-scene")
            }
            ResponderProbeView(claim: claim).frame(width: 1, height: 1)
            Text("\(UIApplication.shared.connectedScenes.count)").accessibilityIdentifier("scene-count")
            Text(model.isComposerOpen ? "open" : "closed").accessibilityIdentifier("composer-state")
        }
        .sheet(isPresented: $showSheet) { SheetContent() }
        return Group {
            if ProcessInfo.processInfo.arguments.contains("--no-sdk") {
                base // control: no SDK shake code at all, to compare the system's own behavior
            } else if callback {
                base.onFeedbackShake(model: model, enabled: true, captureScreen: capture, onNotEnrolled: { Counters.shared.notEnrolled += 1 }) { event in
                    Counters.shared.perform += 1
                    if event.screenshotPNG != nil { Counters.shared.captures += 1 }
                    presenter.present(model: model, event: event)
                }
            } else {
                base.shakeToOpenFeedback(model: model, enabled: true, captureScreen: capture)
            }
        }
    }
}

/// The way a host routes a shake to its own presenter: from `event.window`, reusing `event.screenshotPNG`.
@MainActor final class HostPresenter {
    func present(model: FeedbackModel, event: FeedbackShakeEvent) {
        var top = event.window.rootViewController
        while let next = top?.presentedViewController { top = next }
        let host = UIHostingController(rootView: NavigationStack {
            FeedbackView(model: model, initialScreenshotPNG: event.screenshotPNG) { [weak top] in top?.dismiss(animated: true) }
        })
        top?.present(host, animated: true)
    }
}

@main struct HarnessApp: App {
    @State private var model: FeedbackModel?
    @State private var overlay: PassthroughWindow?
    private let arguments = ProcessInfo.processInfo.arguments
    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    RootView(model: model, callback: arguments.contains("--callback"), capture: !arguments.contains("--no-capture"))
                } else { ProgressView() }
            }
            .task {
                _ = ChainProbe.installed
                if model == nil {
                    model = try? await makeHarnessModel(offline: arguments.contains("--offline"), enrolled: !arguments.contains("--not-enrolled"))
                }
                if arguments.contains("--passthrough-window"), overlay == nil,
                   let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                    let window = PassthroughWindow(windowScene: scene)
                    window.windowLevel = .alert; window.isHidden = false; window.rootViewController = UIViewController()
                    window.rootViewController?.view.isUserInteractionEnabled = false
                    overlay = window
                }
            }
        }
    }
}
