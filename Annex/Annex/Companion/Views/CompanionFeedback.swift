import SwiftUI
import UIKit
import Framebriar
import FramebriarUI
import ClubhouseTransport

/// Reads sanitized diagnostic records only; never conversations, prompts or pairing credentials.
@MainActor enum CompanionFeedback {
    static let shakePreferenceKey = "framebriar.shakeToOpenFeedback"
    /// Whether a shake pre-attaches a screenshot of the screen that was showing, for review.
    static let shakeScreenshotPreferenceKey = "framebriar.shakeAttachesScreenshot"
    static func snapshotIncident(telemetry: AnnexTelemetry = .shared, now: Date = Date(), backend: UUID? = nil) -> FeedbackIncident? {
        let snapshot = telemetry.snapshot()
        let start = now.addingTimeInterval(-300)
        let recent = snapshot.records.reversed().filter { $0.startedAt >= start && $0.startedAt <= now }
        let traces = recent.prefix(8).compactMap { try? FeedbackIncident.Trace(traceId: $0.traceID, spanId: $0.id) }
        func identifiers(_ key: AnnexDiagnosticIdentifier) -> [String] {
            Array(Set(recent.compactMap { $0.identifiers[key.rawValue] })).sorted().prefix(4).map { $0 }
        }
        return try? FeedbackIncident(capturedAt: now, windowStart: start,
            availability: !snapshot.enabled ? .collection_off : traces.isEmpty ? .unavailable : .recorded,
            phoneInstanceId: telemetry.instanceID.uuidString.lowercased(),
            hostInstanceIds: identifiers(.peerInstanceID), connectionIds: identifiers(.connectionID),
            traces: traces, backendRef: backend?.uuidString.lowercased())
    }
    static func makeModel() -> FeedbackModel? {
        // The build supplies the registered mobile scope, not an invitation or credential.
        // Enrollment remains an explicit user action. Missing configuration creates no client.
        guard let gameID = Bundle.main.object(forInfoDictionaryKey: "FramebriarGameID") as? String,
              !gameID.isEmpty else { return nil }
        do {
            let config = try Configuration(gameID: gameID, buildSHA: CompanionBuildInfo.buildSHA())
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true).appendingPathComponent("Framebriar", isDirectory: true)
            let client = try Client(configuration: config,
                                    enrollmentStore: KeychainEnrollmentStore(service: "ClubhouseGo.Framebriar"),
                                    feedbackStore: FileFeedbackStore(directory: root))
            return FeedbackModel(client: client, incidentProvider: { snapshotIncident(backend: AnnexDiagnosticSettings.shared.destination?.backendReference) })
        } catch {
            // Fail closed without logging credentials, private paths or stored content.
            return nil
        }
    }
}

struct CompanionFeedbackSettings: View {
    let model: FeedbackModel?
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeEnabled = true
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var shakeAttachesScreenshot = true
    @AppStorage(CompanionScreenshotFeedback.preferenceKey) private var screenshotOffersFeedback = true
    static func label(_ access: AccessState) -> String {
        switch access {
        case .connected: "Connected"
        case .disconnected: "Not enrolled"
        case .offline: "Offline, will retry"
        case .expired: "Expired"
        case .accessRequired: "Needs a new invitation"
        case .paused: "Paused"
        }
    }
    var body: some View {
        Section("Developer feedback") {
            if let model {
                NavigationLink("Invitation & enrollment") { EnrollmentView(model: model) }
                if model.status?.canSubmit == true {
                    NavigationLink("Send feedback") { FeedbackView(model: model) }
                }
                Text("Feedback access: \(model.status.map { Self.label($0.access) } ?? "Checking")")
                Text("\(model.status?.queued ?? 0) reports on this device")
            } else {
                Text("Feedback is not configured for this build or local storage is unavailable.")
            }
            Toggle("Shake to open feedback", isOn: $shakeEnabled)
            Toggle("Attach a screenshot when you shake", isOn: $shakeAttachesScreenshot).disabled(!shakeEnabled)
            Toggle("Offer feedback when you take a screenshot", isOn: $screenshotOffersFeedback)
            if let model, model.status != nil, model.status?.canSubmit != true {
                Text("Shake needs feedback enrollment. Redeem an invitation in Invitation & enrollment first; until then a shake explains this instead of opening the form.")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("shake-enrollment-required")
            }
            Text("When enrolled, shake opens the feedback form. With Attach a screenshot on, it includes a picture of the screen you were on, taken on this device and shown for you to check. Remove or replace it before you submit; nothing is sent until you tap Submit reviewed feedback. After you take an iOS screenshot, Send feedback with this screenshot? opens the form with that screen attached the same way. No screenshot is taken while a password field is in use. Send feedback is also in Settings, in Home's ⋯ menu and in a chat's ⋯ menu.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Only submitted notes, an optional reviewed image (including a shake screenshot you kept) and optional reviewed incident trace references are shared. No agent content, prompts or logs are attached. Tracing export is configured separately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// The Framebriar shortcut ignores shakes until the user is enrolled, which looked broken
    /// because the preference defaults on. While unenrolled, explain why and offer enrollment.
    /// Install next to `shakeToOpenFeedback`; the two receivers are never eligible together.
    func shakeToExplainFeedbackEnrollment(model: FeedbackModel?, enabled: Binding<Bool>, isPresenting: Bool) -> some View {
        modifier(ShakeEnrollmentPrompt(model: model, enabled: enabled, isPresenting: isPresenting))
    }
}

private struct ShakeEnrollmentPrompt: ViewModifier {
    let model: FeedbackModel?
    @Binding var enabled: Bool
    let isPresenting: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPrompt = false
    @State private var showingEnrollment = false

    private var unenrolled: Bool { model?.status != nil && model?.status?.canSubmit != true }

    func body(content: Content) -> some View {
        content
            .background {
                if model != nil {
                    EnrollmentShakeReceiver(eligible: enabled && unenrolled && scenePhase == .active
                                                && !isPresenting && !showingPrompt && !showingEnrollment) {
                        showingPrompt = true
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .alert("Feedback enrollment required", isPresented: $showingPrompt) {
                Button("Set up feedback") { showingEnrollment = true }
                Button("Turn off shake") { enabled = false }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Shake opens the feedback form after you redeem a feedback invitation in Settings → Invitation & enrollment.")
            }
            .sheet(isPresented: $showingEnrollment) {
                if let model {
                    NavigationStack {
                        EnrollmentView(model: model).toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showingEnrollment = false } }
                        }
                    }
                }
            }
    }
}

/// Claims first responder only while eligible, never from active text input or a presentation,
/// mirroring the Framebriar receiver so a real shake is delivered here while unenrolled.
private struct EnrollmentShakeReceiver: UIViewControllerRepresentable {
    let eligible: Bool
    let onShake: @MainActor () -> Void
    func makeUIViewController(context: Context) -> Receiver { Receiver() }
    func updateUIViewController(_ controller: Receiver, context: Context) {
        controller.eligible = eligible
        controller.onShake = onShake
        controller.updateEligibility()
    }
    static func dismantleUIViewController(_ controller: Receiver, coordinator: ()) { controller.stop() }

    @MainActor final class Receiver: UIViewController {
        var eligible = false
        var onShake: (@MainActor () -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var rearmTask: Task<Void, Never>?
        override var canBecomeFirstResponder: Bool { eligible }
        override func loadView() { view = UIView(); view.backgroundColor = .clear }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateEligibility() }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); rearmTask?.cancel(); resignFirstResponder() }
        override func viewDidLoad() {
            super.viewDidLoad()
            for name in [UIResponder.keyboardDidHideNotification, UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateEligibility() }
                })
            }
        }
        func stop() {
            eligible = false; onShake = nil; rearmTask?.cancel(); rearmTask = nil; resignFirstResponder()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        func updateEligibility() {
            rearmTask?.cancel(); rearmTask = nil
            guard eligible else { if isFirstResponder { resignFirstResponder() }; return }
            if claim() { return }
            // A dismissal transition can still be finishing; retry briefly like the SDK receiver.
            rearmTask = Task { @MainActor [weak self] in
                for _ in 0..<30 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, !Task.isCancelled, self.eligible else { return }
                    if self.claim() { return }
                }
            }
        }
        private func claim() -> Bool {
            guard let window = viewIfLoaded?.window, window.isKeyWindow,
                  window.windowScene?.activationState == .foregroundActive,
                  !Self.hasPresentation(window.rootViewController), !Self.isEditing(window) else { return false }
            let claimed = isFirstResponder || becomeFirstResponder()
            #if DEBUG
            CompanionShakeDiagnostics.trace("enrollment receiver claim -> \(claimed)")
            #endif
            return claimed
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            #if DEBUG
            CompanionShakeDiagnostics.trace("enrollment receiver motionEnded eligible=\(self.eligible)")
            #endif
            guard motion == .motionShake, eligible, let onShake else { super.motionEnded(motion, with: event); return }
            onShake()
        }
        private static func hasPresentation(_ controller: UIViewController?) -> Bool {
            guard let controller else { return false }
            if controller.presentedViewController != nil || controller.isBeingPresented || controller.isBeingDismissed { return true }
            return controller.children.contains { hasPresentation($0) }
        }
        private static func isEditing(_ view: UIView) -> Bool {
            if view.isFirstResponder && view is any UIKeyInput { return true }
            return view.subviews.contains { isEditing($0) }
        }
    }
}
