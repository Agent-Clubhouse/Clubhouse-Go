import SwiftUI
import Framebriar
import FramebriarUI
import ClubhouseTransport

/// Reads sanitized diagnostic records only; never conversations, prompts or pairing credentials.
@MainActor enum CompanionFeedback {
    static let shakePreferenceKey = "framebriar.shakeToOpenFeedback"
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
            let build = Bundle.main.object(forInfoDictionaryKey: "FramebriarBuildSHA") as? String
            let config = try Configuration(gameID: gameID, buildSHA: build)
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
            Text("Only submitted notes, an optional reviewed image and optional reviewed incident trace references are shared. No agent content, prompts or logs are attached. Tracing export is configured separately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
