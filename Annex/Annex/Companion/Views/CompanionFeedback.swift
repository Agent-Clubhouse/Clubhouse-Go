import SwiftUI
import Framebriar
import FramebriarUI

/// Composition-only adapter: has no access to agent conversations, prompts, transport or pairing credentials.
@MainActor enum CompanionFeedback {
    static let shakePreferenceKey = "framebriar.shakeToOpenFeedback"
    static func makeModel() -> FeedbackModel? {
        // Intentionally unconfigured. Set a server-approved game ID in the build's Info.plist
        // only after the owner approves live enrollment. A missing value creates no client/network activity.
        guard let gameID = Bundle.main.object(forInfoDictionaryKey: "FramebriarGameID") as? String,
              !gameID.isEmpty else { return nil }
        do {
            let build = Bundle.main.object(forInfoDictionaryKey: "FramebriarBuildSHA") as? String
            let config = try Configuration(gameID: gameID, buildSHA: build)
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true).appendingPathComponent("Framebriar", isDirectory: true)
            let client = try Client(configuration: config,
                                    enrollmentStore: KeychainEnrollmentStore(service: "ClubhouseGo.Framebriar"),
                                    feedbackStore: FileFeedbackStore(directory: root))
            return FeedbackModel(client: client)
        } catch {
            // Fail closed without logging credentials, private paths or stored content.
            return nil
        }
    }
}

struct CompanionFeedbackSettings: View {
    let model: FeedbackModel?
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeEnabled = true
    var body: some View {
        Section("Developer feedback") {
            if let model {
                NavigationLink("Invitation & enrollment") { EnrollmentView(model: model) }
                if model.status?.canSubmit == true {
                    NavigationLink("Send feedback") { FeedbackView(model: model) }
                }
                Text("Feedback access: \(model.status?.access.rawValue ?? "checking")")
                Text("\(model.status?.queued ?? 0) reports on this device")
            } else {
                Text("Feedback is not configured for this build or local storage is unavailable.")
            }
            Toggle("Shake to open feedback", isOn: $shakeEnabled)
            Text("When enrolled, shake opens a blank feedback form. It never captures or sends automatically. You can also use Send feedback in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Only your submitted notes and optional reviewed image are shared. No agent content, prompts, diagnostics, or telemetry are collected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
