import Foundation
import SwiftUI
import Framebriar

@MainActor @Observable public final class FeedbackModel {
    public let client: Client
    public private(set) var status: ClientStatus?
    public private(set) var message: String?
    public private(set) var working = false
    /// Optional. When set, a saved report emits `feedback.submitted`, plus the consented diagnostics
    /// excerpt when the report doesn't carry its own diagnostics.
    public let telemetry: Telemetry?
    /// The mode for drafts opened without their own. Each draft keeps the mode it opened with.
    public let reportDiagnostics: FeedbackReportDiagnostics
    /// True while a `FeedbackView` for this model is on screen, however it was presented.
    public private(set) var isComposerOpen = false
    private var openComposers = 0
    private var capturing = false
    private let incidentProvider: @MainActor () -> FeedbackIncident?
    private let diagnosticsProvider: (@MainActor () throws -> FeedbackDiagnostics?)?
    private let now: @MainActor () -> Date
    /// - Parameters:
    ///   - diagnosticsProvider: synchronous, no I/O; runs once when a composer opens under `.on`. Without
    ///     one, the `telemetry` ring is used if there is one. Nil, a throw or unusable output never block Send.
    ///   - reportDiagnostics: `.off` keeps the `diagnostics` field off the wire and runs no capture.
    public init(client: Client, telemetry: Telemetry? = nil, incidentProvider: @escaping @MainActor () -> FeedbackIncident? = { nil },
                diagnosticsProvider: (@MainActor () throws -> FeedbackDiagnostics?)? = nil, reportDiagnostics: FeedbackReportDiagnostics = .off,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.client = client; self.telemetry = telemetry; self.incidentProvider = incidentProvider
        self.diagnosticsProvider = diagnosticsProvider; self.reportDiagnostics = reportDiagnostics; self.now = now
    }
    public func snapshotIncident() -> FeedbackIncident? { incidentProvider() }
    public func update() async { status = await client.status() }
    public func setActive(_ active: Bool) async {
        if active { await client.resume() } else { await client.pause() }
        await update()
    }
    /// Call from one app-lifetime foreground task, not from a Settings sheet.
    public func tick() async {
        do { try await client.refreshAccess(); try await client.flush() }
        catch { /* State/queue remain available; do not log responses or credentials. */ }
        await update()
    }
    public func connect(_ invitation: String) async {
        await perform {
            try await self.client.connect(invitation: invitation)
            self.message = "Enrolled. Only feedback you explicitly submit will be shared."
        }
    }
    public func disconnect() async {
        await perform {
            let revoked = try await self.client.disconnect()
            self.message = revoked ? "Enrollment cleared. Queued reports remain on this device, and won't send under a later enrollment unless you choose." : "Enrollment cleared locally. Remote revocation could not be confirmed. Queued reports remain, and won't send under a later enrollment unless you choose."
        }
    }
    public func clearQueue() async {
        await perform { try await self.client.clearQueuedFeedback(); self.message = "Queued reports cleared from this device." }
    }
    /// Sends reports held from a previous enrollment with this one. Pass the `status.releaseToken` the user
    /// saw when they confirmed, not a fresh one, so a change since then fails with `stale-release`
    /// instead of sending. Delivery is attempted afterwards; the result doesn't mean delivered.
    @discardableResult public func releaseHeldReports(releaseToken: String?) async -> HeldReleaseResult {
        let result = await client.releaseHeldReports(releaseToken: releaseToken)
        message = FeedbackDisclosure.releaseResult(result)
        if result.released > 0 { await tick() } else { await update() }
        return result
    }
    /// Discards held reports from this device without sending them. Works while unenrolled.
    @discardableResult public func clearHeldReports() async -> HeldClearResult {
        let result = await client.clearHeldReports()
        message = FeedbackDisclosure.clearHeldResult(result)
        await update()
        return result
    }
    /// Whether a report from this model can carry diagnostics, for wording that has to stay true.
    /// Follows the model's mode; a draft opened with its own says so in its own summary.
    public var sendsDiagnostics: Bool { reportDiagnostics == .on && (diagnosticsProvider != nil || telemetry != nil) }

    func composerAppeared() { openComposers += 1; isComposerOpen = true }
    func composerDisappeared() { openComposers = max(0, openComposers - 1); isComposerOpen = openComposers > 0 }

    /// Freezes what this composer can send. A reentrant call, such as a provider synchronously notifying
    /// something that opens feedback, runs no provider and captures nothing.
    /// - Parameter reportDiagnostics: the mode for this draft only. Nil uses the model's. Never changes the model.
    public func openDraft(reportDiagnostics: FeedbackReportDiagnostics? = nil) -> FeedbackDraft {
        let at = now(), ref = client.enrollmentSignal.enrollmentRef, mode = reportDiagnostics ?? self.reportDiagnostics
        let offersSwitch = mode == .on || telemetry?.isEnabled == true
        func draft(_ captured: FeedbackDiagnostics?, _ incident: FeedbackIncident?) -> FeedbackDraft {
            FeedbackDraft(id: UUID(), openedAt: at, reportDiagnosticsMode: mode, offersDiagnosticsSwitch: offersSwitch,
                          capturedDiagnostics: captured, incident: incident, enrollmentRef: ref)
        }
        guard !capturing else { return draft(mode == .on ? .unavailable(at: at) : nil, nil) }
        capturing = true; defer { capturing = false }
        return draft(mode == .on ? captureDiagnostics(at: at) : nil, incidentProvider())
    }
    private func captureDiagnostics(at: Date) -> FeedbackDiagnostics {
        var captured: FeedbackDiagnostics
        if let diagnosticsProvider {
            do {
                let value = try diagnosticsProvider()
                // Only the user's switch can leave diagnostics out.
                captured = value?.state == .left_out ? .unavailable(reason: FeedbackDiagnostics.Reason.invalid, at: at) : value?.normalized(at: at) ?? .none(at: at)
            } catch { captured = .unavailable(at: at) }
        } else if let telemetry {
            captured = telemetry.diagnosticsSnapshot()?.normalized(at: at) ?? .none(at: at)
        } else {
            captured = .none(reason: FeedbackDiagnostics.Reason.noProvider, at: at)
        }
        captured.setDelivery(status.map { .init(queued: $0.queued, lastResult: $0.lastDeliveryResult ?? "none") })
        return (try? captured.validate()) == nil ? .unavailable(reason: FeedbackDiagnostics.Reason.invalid, at: at) : captured
    }

    /// The local commit. When this returns, the report survives a crash or relaunch. Sends nothing.
    /// On a throw nothing was saved, and the draft can be sent again with the same ID, except after
    /// `enrollmentChanged`: that draft can never send. Call `openDraft()` for a new ID and new captures.
    public func save(_ draft: FeedbackDraft, notes: String, screenshotPNG: Data?, includeDiagnostics: Bool) async throws -> ReviewedFeedback {
        guard !working else { throw FramebriarError.busy }
        working = true; defer { working = false }
        let report = try draft.report(configuration: client.configuration, notes: notes, screenshotPNG: screenshotPNG, includeDiagnostics: includeDiagnostics)
        do { try await client.enqueue(report, enrollmentRef: draft.enrollmentRef) }
        catch { await update(); throw error }
        await update()
        return report
    }
    /// Attempts delivery now and reports what happened. The telemetry marker follows the attempt, so the
    /// two don't compete for the client. Telemetry failure never affects the report.
    /// A report carrying its own diagnostics, in any state, gets the marker only, so no event goes out twice.
    public func deliver(_ report: ReviewedFeedback, includeDiagnostics: Bool) async -> FeedbackDeliveryOutcome {
        let outcome = await client.deliver(report.id)
        await update()
        if let telemetry {
            let excerpt = includeDiagnostics && report.diagnostics == nil
            Task { await telemetry.feedbackSubmitted(reportID: report.id, trace: report.incident?.traces.first, includeDiagnostics: excerpt) }
        }
        return outcome
    }
    /// `save` then `deliver`. A failed save comes back as `needsAttention` with the draft still usable.
    public func send(_ draft: FeedbackDraft, notes: String, screenshotPNG: Data?, includeDiagnostics: Bool) async -> FeedbackDeliveryOutcome {
        do {
            let report = try await save(draft, notes: notes, screenshotPNG: screenshotPNG, includeDiagnostics: includeDiagnostics)
            return await deliver(report, includeDiagnostics: includeDiagnostics)
        } catch { return .needsAttention(Self.notSaved(error)) }
    }
    nonisolated static func notSaved(_ error: any Error) -> FeedbackDeliveryOutcome.AttentionReason {
        switch error as? FramebriarError {
        case .capacity: .storageFull
        case .storage: .storageUnavailable
        case .accessRequired, .expired: .notEnrolled
        case .busy: .busy
        case .enrollmentChanged: .enrollmentChanged
        default: .invalidReport
        }
    }

    @available(*, deprecated, message: "FeedbackView now uses save and deliver, which report a delivery result. See the README's migration note.")
    public func submit(_ reviewed: ReviewedFeedback, includeDiagnostics: Bool = true) async -> Bool {
        var saved = false
        await perform {
            try await self.client.enqueue(reviewed, enrollmentRef: self.client.enrollmentSignal.enrollmentRef); saved = true
            self.message = "Saved on this device. Delivery is confirmed separately."
        }
        if saved, let telemetry {
            // After the local commit, never before; telemetry failure never affects the report.
            Task { await telemetry.feedbackSubmitted(reportID: reviewed.id, trace: reviewed.incident?.traces.first, includeDiagnostics: includeDiagnostics) }
        }
        return saved
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !working else { return }
        working = true; defer { working = false }
        do { try await action() }
        catch {
            switch error as? FramebriarError {
            case .capacity: message = "Local feedback storage is full. Your review has not been saved."
            case .storage: message = "Local storage is unavailable. Your review has not been saved."
            case .invalidInput: message = "Check the invitation or feedback. PNG attachments must be at most 8 MiB."
            case .accessRequired, .expired: message = "Feedback access needs a new invitation. Existing reports remain on this device."
            case .paused: message = "Feedback delivery is paused."
            default: message = "The operation could not be confirmed. Retry the same invitation or reviewed report."
            }
        }
        await update()
    }
}

public struct EnrollmentView: View {
    @Bindable private var model: FeedbackModel
    @State private var invitation = ""
    @State private var confirmClear = false
    @State private var confirmDisconnect = false
    @State private var confirmClearHeld = false
    /// The token and count the confirmation showed, so a change before the tap makes the release stale.
    @State private var pendingRelease: (token: String, count: Int)?
    public init(model: FeedbackModel) { self.model = model }
    public var body: some View {
        Form {
            Section("Feedback enrollment") {
                Text(FeedbackDisclosure.enrollment(hasTelemetry: model.telemetry != nil, sendsDiagnostics: model.sendsDiagnostics))
                Text("Status: \(model.status?.access.rawValue ?? "checking")")
                if let end = model.status?.enrollmentExpiresAt { Text("Enrollment ends \(end.formatted())") }
                SecureField("Invitation", text: $invitation).textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                Button("Redeem invitation") {
                    let value = invitation; invitation = ""
                    Task { await model.connect(value) }
                }.disabled(model.working || invitation.isEmpty)
                Button("Clear enrollment", role: .destructive) { confirmDisconnect = true }.disabled(model.working)
            }
            Section("On this device") {
                Text("\(model.status?.queued ?? 0) of 10 reports · \(model.status?.queuedBytes ?? 0) of 33,554,432 attachment bytes")
                Text("Unsent reports remain until delivered or explicitly cleared. Device loss or app removal can lose local reports. Server media and context expire after seven days, with possible cleanup delay.")
                if let status = model.status, status.correlationWaiting > 0 { Text("\(status.correlationWaiting) reports are retained until the service supports incident correlation. No metadata is silently discarded.") }
                if let status = model.status, status.blocked > 0 { Text("\(status.blocked) reports need review after service rejection.") }
                if let status = model.status, status.heldForEnrollment > 0 {
                    Text(FeedbackDisclosure.heldSummary(count: status.heldForEnrollment)).accessibilityIdentifier("framebriar-held-summary")
                    if let token = status.releaseToken {
                        Button("Send with this enrollment…") { pendingRelease = (token, status.heldForEnrollment) }
                            .disabled(model.working).accessibilityIdentifier("framebriar-release-held")
                    }
                    Button("Clear these reports", role: .destructive) { confirmClearHeld = true }
                        .disabled(model.working).accessibilityIdentifier("framebriar-clear-held")
                }
                Button("Retry delivery") { Task { await model.tick() } }.disabled(model.working)
                Button("Clear queued feedback", role: .destructive) { confirmClear = true }.disabled(model.working)
            }
            if let message = model.message { Section { Text(message).accessibilityIdentifier("framebriar-status") } }
            if let id = model.status?.lastReceivedID { Section { Text("Service confirmed report \(id.uuidString)") } }
        }
        .navigationTitle("Feedback enrollment")
        .task { await model.update() }
        .confirmationDialog("Clear queued feedback from this device?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear queued feedback", role: .destructive) { Task { await model.clearQueue() } }
        }
        .confirmationDialog(pendingRelease.map { FeedbackDisclosure.releaseConfirmation(count: $0.count) } ?? "", isPresented: Binding(get: { pendingRelease != nil }, set: { if !$0 { pendingRelease = nil } }), titleVisibility: .visible) {
            if let token = pendingRelease?.token {
                Button("Send") { Task { await model.releaseHeldReports(releaseToken: token) } }
            }
        }
        .confirmationDialog("Clear reports saved under a previous enrollment? They won't be sent.", isPresented: $confirmClearHeld, titleVisibility: .visible) {
            Button("Clear these reports", role: .destructive) { Task { await model.clearHeldReports() } }
        }
        .confirmationDialog("Clear enrollment? Queued reports will remain.", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Clear enrollment", role: .destructive) { Task { await model.disconnect() } }
        }
        .onDisappear { invitation = "" }
    }
}
