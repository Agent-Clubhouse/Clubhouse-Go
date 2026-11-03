import SwiftUI
import UIKit
import Framebriar
import FramebriarUI
import ClubhouseTransport

/// Reads sanitized diagnostic records only; never conversations, prompts or pairing credentials.
@MainActor enum CompanionFeedback {
    /// Ordinary routes always open OFF. Only the explicit one-test entry overrides one view to ON.
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
    /// Synchronous bounded memory snapshot, independent of enrollment/access/export at send time.
    /// Annex owns the closed vocabulary; the SDK independently sanitizes and sizes its wire contract.
    static func diagnosticsSnapshot(from source: AnnexTelemetry = .shared, now: Date = Date()) -> FeedbackDiagnostics {
        let captured = AnnexFeedbackDiagnostics.capture(from: source, now: now)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        switch captured.state {
        case .none: return .none(reason: captured.reason == .no_provider ? FeedbackDiagnostics.Reason.noProvider : FeedbackDiagnostics.Reason.empty, at: now)
        case .unavailable, .left_out: return .unavailable(reason: FeedbackDiagnostics.Reason.invalid, at: now)
        case .attached:
            guard let start = dates.date(from: captured.windowStart), let end = dates.date(from: captured.windowEnd) else {
                return .unavailable(reason: FeedbackDiagnostics.Reason.invalid, at: now)
            }
            var entries: [FeedbackDiagnostics.Entry] = []
            for entry in captured.entries {
                guard let at = dates.date(from: entry.at), let level = FeedbackDiagnostics.Level(rawValue: entry.level.rawValue) else {
                    return .unavailable(reason: FeedbackDiagnostics.Reason.invalid, at: now)
                }
                entries.append(.init(at: at, level: level, ns: entry.ns, event: entry.event, attrs: entry.attrs.mapValues {
                    switch $0 { case .string(let text): .string(text); case .number(let number): .number(number) }
                }))
            }
            return FeedbackDiagnostics(windowStart: start, windowEnd: end, entries: entries,
                                       dropped: captured.dropped, droppedAttrs: captured.droppedAttrs)
        }
    }

    /// The feedback model with enrollment-gated telemetry. If telemetry can't be configured, feedback still works without it.
    static func compose(client: Client, source: AnnexTelemetry = .shared, telemetryTransport: any HTTPTransport = URLSessionTransport(),
                        observeAppLifecycle: Bool = true) -> (model: FeedbackModel, telemetry: CompanionTelemetry?) {
        adoptSession(of: source)
        let telemetry = try? CompanionTelemetry(client: client, configuration: client.configuration, source: source,
                                                transport: telemetryTransport, observeAppLifecycle: observeAppLifecycle)
        let model = FeedbackModel(client: client, telemetry: telemetry?.telemetry, incidentProvider: {
            // Freeze the current performance interval at capture, without refreshing a reviewed draft.
            telemetry?.checkpointCapture()
            return snapshotIncident(telemetry: source, backend: AnnexDiagnosticSettings.shared.destination?.backendReference)
        }, diagnosticsProvider: {
            telemetry?.checkpointCapture()
            return diagnosticsSnapshot(from: source)
        }, reportDiagnostics: .off)
        return (model, telemetry)
    }
}

struct CompanionFeedbackSettings: View {
    let model: FeedbackModel?
    var initialScreenshotPNG: Data? = nil
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
                        NavigationLink("Send feedback") { CompanionFeedbackComposer(model: model, initialScreenshotPNG: initialScreenshotPNG) }
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
                Section {
                    CompanionFeedbackDiagnosticsTestEntry(model: model)
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
                Text("When enrolled, shake opens the feedback form. With Attach a screenshot on, it includes a picture of the screen you were on, taken on this device and shown for you to check. Remove or replace it before you submit; nothing is sent until you tap Send. After you take an iOS screenshot, Send feedback with this screenshot? opens the form with that screen attached the same way. No screenshot is taken while a password field is in use. Send feedback in Home's ⋯ menu and a chat's ⋯ menu includes the screen from before the menu opened. In Settings it includes the screen from before Settings opened. Remove or replace the image before Send; a failed or suppressed capture leaves Add screenshot available.")
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
    var isDiagnosticsTest = false
    @State private var openedEnrollment: String?
    @State private var enrollmentChanged = false
    @State private var captureWasOff = false
    #if DEBUG
    @Environment(\.companionFeedbackFixtureControls) private var fixtureControls
    #endif
    var body: some View {
        FeedbackView(model: model, initialScreenshotPNG: screenshot, onClose: onClose,
                     reportDiagnostics: isDiagnosticsTest ? .on : .off)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isDiagnosticsTest {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(enrollmentChanged ? "Diagnostics test ended — enrollment changed" : "Diagnostics test report").bold()
                            .accessibilityIdentifier("feedback-diagnostics-test-banner")
                        Text(enrollmentChanged
                             ? "This test permission cannot move to the new enrollment. The replacement draft has report diagnostics off. Cancel and prepare a new test from Settings to include them."
                             : "Start your note with ‘Diagnostics test’. Only this draft can include the recent records shown in Included. Review them before Send; Cancel leaves the next report off.")
                        if captureWasOff { Text("Capture was off when this opened; recent transport records may be missing.") }
                    }.font(.caption).padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                }
            }
            #if DEBUG
            .safeAreaInset(edge: .top, spacing: 0) {
                if let fixtureControls {
                    HStack {
                        Button("Change fixture enrollment", action: fixtureControls.changeEnrollment)
                        Button("Record later retry", action: fixtureControls.recordLater)
                    }.font(.caption)
                }
            }
            #endif
            .onAppear {
                if openedEnrollment == nil {
                    openedEnrollment = model.client.enrollmentSignal.enrollmentRef
                    #if DEBUG
                    captureWasOff = !(fixtureControls?.captureIsEnabled() ?? AnnexTelemetry.shared.isEnabled)
                    #else
                    captureWasOff = !AnnexTelemetry.shared.isEnabled
                    #endif
                }
            }
            .onChange(of: model.status.map { _ in model.client.enrollmentSignal.enrollmentRef }) { _, current in
                if current != openedEnrollment { enrollmentChanged = true }
            }
    }
    private var screenshot: Data? {
        #if DEBUG
        if isDiagnosticsTest, let image = fixtureControls?.image { return image }
        #endif
        return initialScreenshotPNG
    }
}

/// No persistent switch. Each deliberate navigation creates a new one-view override.
private struct CompanionFeedbackDiagnosticsTestEntry: View {
    let model: FeedbackModel
    var body: some View {
        DisclosureGroup("Feedback diagnostics test") {
            NavigationLink("Prepare one diagnostics test report…") {
                CompanionFeedbackDiagnosticsTestConfirmation(model: model)
            }
            .disabled(model.status?.canSubmit != true || model.telemetry == nil)
            .accessibilityIdentifier("feedback-prepare-diagnostics-test")
            if model.telemetry == nil {
                Text("Diagnostics testing is unavailable in this session. You can still send ordinary feedback.").font(.caption)
            }
        }
    }
}

/// A stable confirmation screen, rather than a sheet attached to a recyclable Settings row.
private struct CompanionFeedbackDiagnosticsTestConfirmation: View {
    let model: FeedbackModel
    var body: some View {
        Form {
            Section("Diagnostics test report") {
                Text("Use only when a developer asks for a labeled test report. Ordinary feedback keeps report diagnostics off.")
                Text("Only the draft you prepare now may attach recent transport diagnostics. Start the note with ‘Diagnostics test’, check Included, then choose Send. Cancel leaves ordinary reports off. An enrollment change ends this test permission.")
                NavigationLink("Prepare test report") { CompanionFeedbackComposer(model: model, isDiagnosticsTest: true) }
                    .disabled(model.status?.canSubmit != true || model.telemetry == nil)
            }
        }.navigationTitle("Diagnostics test")
    }
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
