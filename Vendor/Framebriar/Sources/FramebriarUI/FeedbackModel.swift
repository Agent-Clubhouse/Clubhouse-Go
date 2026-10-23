import Foundation
import SwiftUI
import Framebriar

@MainActor @Observable public final class FeedbackModel {
    public let client: Client
    public private(set) var status: ClientStatus?
    public private(set) var message: String?
    public private(set) var working = false
    public init(client: Client) { self.client = client }
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
            self.message = revoked ? "Enrollment cleared. Queued reports remain on this device." : "Enrollment cleared locally. Remote revocation could not be confirmed. Queued reports remain."
        }
    }
    public func clearQueue() async {
        await perform { try await self.client.clearQueuedFeedback(); self.message = "Queued reports cleared from this device." }
    }
    public func submit(_ reviewed: ReviewedFeedback) async -> Bool {
        var saved = false
        await perform {
            try await self.client.enqueue(reviewed); saved = true
            self.message = "Saved on this device. Delivery is confirmed separately."
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
    public init(model: FeedbackModel) { self.model = model }
    public var body: some View {
        Form {
            Section("Feedback enrollment") {
                Text("Only feedback you choose to submit is shared. No prompts, agent content, logs, or telemetry are collected. Review images for private information before sending.")
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
                if let status = model.status, status.blocked > 0 { Text("\(status.blocked) reports need review after service rejection.") }
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
        .confirmationDialog("Clear enrollment? Queued reports will remain.", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Clear enrollment", role: .destructive) { Task { await model.disconnect() } }
        }
        .onDisappear { invitation = "" }
    }
}
