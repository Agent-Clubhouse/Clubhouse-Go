import SwiftUI
import UIKit
import Framebriar
import FramebriarUI
import ClubhouseTransport

/// Reads sanitized diagnostic records only; never conversations, prompts or pairing credentials.
@MainActor enum CompanionFeedback {
    /// Required release policy. v0.7.0's composer cannot enforce omission with this flag alone:
    /// do not ship this integration until the tagged SDK OFF policy and composer wire tests land.
    /// No scoped test or AnnexFeedbackDiagnostics provider is connected here.
    static let reportDiagnosticsSendingEnabled = false
    static let shakePreferenceKey = "framebriar.shakeToOpenFeedback"
    /// Whether a shake pre-attaches a screenshot of the screen that was showing, for review.
    static let shakeScreenshotPreferenceKey = "framebriar.shakeAttachesScreenshot"
    static func snapshotIncident(telemetry: AnnexTelemetry = .shared, now: Date = Date(), backend: UUID? = nil) -> FeedbackIncident? {
        let snapshot = telemetry.snapshot()
        let start = now.addingTimeInterval(-300)
        let recent = snapshot.records.reversed().filter { $0.startedAt >= start && $0.startedAt <= now }
        let traces = recent.filter { AnnexAppTelemetry.exportsSpan(for: $0.operation) }.prefix(8).compactMap { try? FeedbackIncident.Trace(traceId: $0.traceID, spanId: $0.id) }
        func identifiers(_ key: AnnexDiagnosticIdentifier) -> [String] {
            Array(Set(recent.compactMap { $0.identifiers[key.rawValue] })).sorted().prefix(4).map { $0 }
        }
        return try? FeedbackIncident(capturedAt: now, windowStart: start,
            availability: !snapshot.enabled ? .collection_off : traces.isEmpty ? .unavailable : .recorded,
            phoneInstanceId: telemetry.instanceID.uuidString.lowercased(),
            hostInstanceIds: identifiers(.peerInstanceID), connectionIds: identifiers(.connectionID),
            traces: traces, backendRef: backend?.uuidString.lowercased())
    }
    /// The SDK commits locally before returning; telemetry has its own immediate flush. Wake
    /// Go's report pump too, rather than waiting for its next periodic foreground tick.
    static func deliverNewlyQueued(model: FeedbackModel, previous: Int?, current: Int?, isBackground: Bool) async {
        guard !isBackground, let current, current > (previous ?? 0) else { return }
        await model.tick()
    }

    static func makeModel() -> (model: FeedbackModel, telemetry: CompanionTelemetry?)? {
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
            return compose(client: client)
        } catch {
            // Fail closed without logging credentials, private paths or stored content.
            return nil
        }
    }
    /// One ID for the run: the diagnostics instance ID, already the incident `phoneInstanceId` and the
    /// collector's `service.instance.id`, becomes Framebriar's session ID, so the report `sessionId` and
    /// the telemetry resource `session.id` match it.
    static func adoptSession(of source: AnnexTelemetry = .shared) {
        try? FramebriarSession.adopt(source.instanceID.uuidString.lowercased())
    }
    /// The feedback model with enrollment-gated telemetry. If telemetry can't be configured, feedback still works without it.
    static func compose(client: Client, source: AnnexTelemetry = .shared, telemetryTransport: any HTTPTransport = URLSessionTransport(),
                        observeAppLifecycle: Bool = true) -> (model: FeedbackModel, telemetry: CompanionTelemetry?) {
        adoptSession(of: source)
        let telemetry = try? CompanionTelemetry(client: client, configuration: client.configuration, source: source,
                                                transport: telemetryTransport, observeAppLifecycle: observeAppLifecycle)
        let model = FeedbackModel(client: client, telemetry: telemetry?.telemetry, incidentProvider: {
            snapshotIncident(telemetry: source, backend: AnnexDiagnosticSettings.shared.destination?.backendReference)
        })
        return (model, telemetry)
    }
}

struct CompanionFeedbackSettings: View {
    let model: FeedbackModel?
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeEnabled = true
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var shakeAttachesScreenshot = true
    @AppStorage(CompanionScreenshotFeedback.preferenceKey) private var screenshotOffersFeedback = true
    /// Framebriar's rule: enrolling enables telemetry, and Settings must say so next to enrollment.
    static let telemetryDisclosure = "Enrolling in developer feedback also sends usage and diagnostic telemetry to the developer while you stay enrolled: performance data, crash and hang reports, and events such as connection, pairing and chat timings, error types and counts. Automated telemetry excludes prompts, agent content, names, file paths, addresses and URLs. Notes and images you choose to submit can contain private information; review them first. Reports may also include reviewed incident trace references. Clearing enrollment stops automatic telemetry; saved feedback stays on this device until delivered or explicitly cleared. Your own tracing collector, in Connection diagnostics, is separate."
    static let feedbackOnlyDisclosure = "Feedback shares the notes and optional image you choose to submit, plus optional reviewed incident trace references. Notes and images can contain private information; review them first. Automatic developer telemetry is unavailable in this session. Your own tracing collector, in Connection diagnostics, is separate."
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
        Group {
            Section("Developer feedback") {
                if let model {
                    NavigationLink("Invitation & enrollment") { CompanionFeedbackEnrollment(model: model) }
                    if model.status?.canSubmit == true {
                        NavigationLink("Send feedback") { CompanionFeedbackComposer(model: model) }
                    }
                    Text("Feedback access: \(model.status.map { Self.label($0.access) } ?? "Checking")")
                    Text(model.telemetry == nil ? Self.feedbackOnlyDisclosure : Self.telemetryDisclosure)
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("feedback-telemetry-disclosure")
                } else {
                    Text("Feedback is not configured for this build or local storage is unavailable.")
                }
            }
            if let model {
                Section("Saved feedback") {
                    if let status = model.status { Text("\(status.queued) reports on this device") }
                    else { Text("Checking saved feedback…") }
                    CompanionHeldFeedbackActions(model: model)
                    CompanionFeedbackQueueActions(model: model)
                }
            }
            Section("Feedback shortcuts") {
                Toggle("Shake to open feedback", isOn: $shakeEnabled)
                Toggle("Attach a screenshot when you shake", isOn: $shakeAttachesScreenshot).disabled(!shakeEnabled)
                Toggle("Offer feedback when you take a screenshot", isOn: $screenshotOffersFeedback)
                if let model, model.status != nil, model.status?.canSubmit != true {
                    Text("Shake needs feedback enrollment. Redeem an invitation in Invitation & enrollment first; until then a shake explains this instead of opening the form.")
                        .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("shake-enrollment-required")
                }
                Text("When enrolled, shake opens the feedback form. With Attach a screenshot on, it includes a picture of the screen you were on, taken on this device and shown for you to check. Remove or replace it before you submit; nothing is sent until you tap Send. After you take an iOS screenshot, Send feedback with this screenshot? opens the form with that screen attached the same way. No screenshot is taken while a password field is in use. Send feedback is also in Settings, in Home's ⋯ menu and in a chat's ⋯ menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Go-owned boundaries for all menu/settings/screenshot routes. Adopt tagged SDK changes here;
/// draft capture, review and intentional submission remain owned by the SDK composer.
struct CompanionFeedbackComposer: View {
    let model: FeedbackModel
    var initialScreenshotPNG: Data? = nil
    var onClose: (@MainActor () -> Void)? = nil
    var body: some View { FeedbackView(model: model, initialScreenshotPNG: initialScreenshotPNG, onClose: onClose) }
}

struct CompanionFeedbackEnrollment: View {
    let model: FeedbackModel
    var body: some View { EnrollmentView(model: model) }
}

/// The confirmation owns the exact token/count that were displayed. Never obtain a fresh token
/// when Send is tapped: a different enrollment or held set must fail with stale-release.
private struct CompanionHeldFeedbackActions: View {
    let model: FeedbackModel
    @State private var pendingRelease: Release?
    @State private var confirmingClear = false
    private struct Release { let token: String; let count: Int }
    var body: some View {
        if let status = model.status, status.heldForEnrollment > 0 {
            Text(FeedbackDisclosure.heldSummary(count: status.heldForEnrollment))
                .accessibilityIdentifier("feedback-held-summary")
            if let token = status.releaseToken {
                Button("Send with this enrollment…") {
                    pendingRelease = Release(token: token, count: status.heldForEnrollment)
                }.disabled(model.working).accessibilityIdentifier("feedback-release-held")
                .confirmationDialog(pendingRelease.map { FeedbackDisclosure.releaseConfirmation(count: $0.count) } ?? "",
                                    isPresented: Binding(get: { pendingRelease != nil }, set: { if !$0 { pendingRelease = nil } }), titleVisibility: .visible) {
                    if let release = pendingRelease {
                        Button("Send") { Task { await model.releaseHeldReports(releaseToken: release.token) } }
                    }
                }
            }
            Button("Clear held reports", role: .destructive) { confirmingClear = true }
                .disabled(model.working).accessibilityIdentifier("feedback-clear-held")
                .confirmationDialog("Clear reports saved under a previous enrollment? They won't be sent.",
                                    isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Clear held reports", role: .destructive) { Task { await model.clearHeldReports() } }
                }
            Text("Send queues these reports for the current enrollment. Delivery needs a service receipt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CompanionFeedbackQueueActions: View {
    let model: FeedbackModel
    @State private var confirmingClear = false
    var body: some View {
        Button("Clear queued feedback", role: .destructive) { confirmingClear = true }
            .disabled(model.working)
            .confirmationDialog("Clear queued feedback from this device?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear queued feedback", role: .destructive) { Task { await model.clearQueue() } }
            } message: {
                Text("This removes saved reports and attachments from this device. It does not delete reports already received by the service.")
            }
        if let message = model.message { Text(message).accessibilityIdentifier("feedback-queue-status") }
    }
}

extension View {
    /// One SDK window receiver per scene. Ordinary sheets, including Settings, are eligible;
    /// typing, secure fields and duplicate delivery are guarded by the tagged SDK.
    func companionFeedbackShake(_ presenter: CompanionFeedbackPresenter?, enabled: Bool,
                                suppressed: Bool = false, captureScreen: Bool = true) -> some View {
        onFeedbackShake(model: presenter?.model, enabled: enabled, isPresenting: suppressed,
                        captureScreen: captureScreen, onNotEnrolled: { presenter?.sendFeedback(fromShake: true) }) { event in
            presenter?.sendFeedback(screenshotPNG: event.screenshotPNG, from: event.window)
        }
    }
}
