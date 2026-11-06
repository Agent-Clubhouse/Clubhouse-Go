import Foundation
import Observation
import ClubhouseTransport

/// One explicit phone workflow. Retained by the store so dismissing a sheet cannot forget an uncertain write.
@MainActor @Observable final class CompanionProviderFlow {
    private enum Operation {
        case save(AnnexProviderPreview, String)
        case start(String, String)
    }
    let target: CompanionTarget
    private let service: any CompanionService
    private let canRequest: () -> Bool
    private var operation: Operation?
    private var outcomeUnknown = false
    private(set) var selectedProvider: String?
    private(set) var preview: AnnexProviderPreview?
    private(set) var savedProvider: String?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var startRequested = false

    init(target: CompanionTarget, service: any CompanionService, canRequest: @escaping () -> Bool) {
        self.target = target; self.service = service; self.canRequest = canRequest
    }
    var blocksMutations: Bool { operation != nil }
    var canChoose: Bool { canRequest() && !busy && !blocksMutations }
    var canSave: Bool { canRequest() && !busy && !blocksMutations && savedProvider == nil && preview?.outcome.permitsSave == true }
    var canStart: Bool {
        canRequest() && !busy && !blocksMutations && !startRequested && savedProvider != nil
            && preview?.outcome.savedProvider == savedProvider && preview?.outcome.permitsSave == true
    }

    func select(_ provider: String) async {
        guard canRequest(), !busy, !blocksMutations else { return }
        selectedProvider = provider; savedProvider = nil; startRequested = false; preview = nil
        await refresh()
    }
    /// A read-only preview; neither opening the view nor choosing a provider saves it.
    func refresh() async {
        guard canRequest(), !busy, !blocksMutations, let selectedProvider else { return }
        busy = true; error = nil; preview = nil
        defer { busy = false }
        do { preview = try await service.providerPreview(target, provider: selectedProvider) }
        catch { self.error = error.localizedDescription }
    }
    func save() async {
        guard canSave, let preview else { return }
        operation = .save(preview, UUID().uuidString)
        outcomeUnknown = false
        await perform()
    }
    func startNew() async {
        guard canStart, let savedProvider else { return }
        operation = .start(savedProvider, UUID().uuidString)
        outcomeUnknown = false
        await perform()
    }
    /// Explicit retry replays the identical command ID; it never creates a second save/start.
    func checkPreviousResult() async {
        guard !busy, operation != nil else { return }
        await perform()
    }
    private func perform() async {
        guard let operation, !busy else { return }
        busy = true; error = nil
        do {
            switch operation {
            case .save(let preview, let id):
                let result = try await service.changeProvider(target, preview: preview, clientCommandID: id)
                switch result {
                case .changed(let value): savedProvider = value.savedProvider
                case .alreadySelected(let value): savedProvider = value.outcome.savedProvider
                }
                self.operation = nil; self.preview = nil; busy = false
                // A fresh read verifies the saved provider and current state before offering Start new.
                await refresh()
            case .start(let provider, let id):
                try await service.startNewProvider(target, provider: provider, clientCommandID: id)
                self.operation = nil; preview = nil; startRequested = true; busy = false
            }
        } catch {
            busy = false
            self.error = error.localizedDescription
            // A definite pre-dispatch refusal can be refreshed. An unknown outcome keeps other mutations locked.
            if case CompanionServiceError.rejected = error { self.operation = nil; preview = nil }
            else if case CompanionServiceError.unavailable = error, !outcomeUnknown { self.operation = nil; preview = nil }
            else { outcomeUnknown = true }
        }
    }
}

enum CompanionProviderReason {
    static func message(_ code: String?) -> String {
        switch code {
        case "agent_running": "Sleep the agent before saving its provider."
        case "agent_stopping": "The desktop is still stopping the agent and saving its session."
        case "agent_starting": "Wait for the agent to finish starting, then put it to sleep."
        case "agent_creating": "Wait for the agent to finish being created."
        case "orchestrator_unavailable": "This provider isn't available on the desktop."
        case "incompatible_permissions": "The desktop cannot preserve the current permission settings with this provider."
        case "incompatible_runtime": "This provider cannot use the selected runtime on the desktop."
        case "instructions_not_equivalent": "The providers' native primary instruction files differ or could not be verified."
        case "session_capture_failed": "The desktop could not save the previous session. Resolve that on the desktop before changing providers."
        case "stale_state": "The agent or its settings changed. Refresh the preview before saving."
        case "agent_transition_busy": "Another agent operation is in progress. Refresh after it finishes."
        case "resume_unverified", "resume_failed": "Resume is unavailable. No fresh session was started."
        case "agent_not_found": "This agent is no longer available on the desktop."
        default: "The desktop cannot complete this provider action. Refresh its state or check the desktop."
        }
    }
}
