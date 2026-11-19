import Foundation
import Observation
import ClubhouseTransport

/// A preview is authority only for this desktop epoch and connection observation.
struct CompanionProviderV2Preview: Sendable {
    let value: AnnexProviderPreviewV2
    let target: CompanionTarget
    let epoch: String
    let generation: UUID
    let capability: AnnexProviderApplyV2Capability
}
struct CompanionProviderV2Applied: Sendable, Equatable {
    let value: AnnexProviderApplyReceiptV2
    let target: CompanionTarget
    let epoch: String
    let commandID: String
}
enum CompanionProviderV2ApplyOutcome: Sendable {
    case saved(CompanionProviderV2Applied)
    case refused(String)
    case conflict(AnnexProviderTransitionV2)
}
enum CompanionProviderV2StartOutcome: Sendable {
    case evidence(AnnexProviderStartReceiptV2, completed: Bool)
    case refused(String)
}

/// Store-retained and target-bound. Unknown HTTP outcomes have NO redispatch API.
@MainActor @Observable final class CompanionProviderV2Flow {
    let target: CompanionTarget
    private let service: any CompanionService
    private let canRequest: () -> Bool
    private let startAdvertised: () -> Bool
    private var requestedRuntime: String
    private var startEligibleApply: CompanionProviderV2Applied?
    private(set) var selectedProvider: String?
    private(set) var preview: CompanionProviderV2Preview?
    private(set) var reportedSaved: AnnexProviderNextWakeV2?
    private(set) var lastApply: CompanionProviderV2Applied?
    private(set) var lastStart: AnnexProviderStartReceiptV2?
    private(set) var conflict: AnnexProviderTransitionV2?
    private(set) var busy = false
    private(set) var blocksMutations = false
    private(set) var error: String?

    init(target: CompanionTarget, service: any CompanionService, requestedRuntime: String,
         canRequest: @escaping () -> Bool, startAdvertised: @escaping () -> Bool) {
        self.target = target; self.service = service; self.requestedRuntime = requestedRuntime
        self.canRequest = canRequest; self.startAdvertised = startAdvertised
    }
    var canChoose: Bool { canRequest() && !busy && !blocksMutations }
    var preservesRuntime: Bool {
        guard let preview else { return false }
        return requestedRuntime == "default" || requestedRuntime == preview.value.preview.outcome.targetRuntime.rawValue
    }
    var canApply: Bool {
        canChoose && startEligibleApply == nil && preservesRuntime
            && preview.map { $0.value.permitsApply(capability: $0.capability) } == true
    }
    var canStart: Bool {
        canChoose && startAdvertised() && startEligibleApply?.value.nextWake?.readyToken != nil
    }
    func updateRequestedRuntime(_ value: String) {
        guard !busy, requestedRuntime != value else { return }
        requestedRuntime = value; preview = nil; startEligibleApply = nil
    }
    func select(_ provider: String) async {
        guard canChoose else { return }
        selectedProvider = provider; preview = nil; startEligibleApply = nil
        await refresh()
    }
    /// Read-only even when an operation is unknown. Equal configuration NEVER unlocks it.
    func refresh() async {
        guard canRequest(), !busy, let selectedProvider else { return }
        busy = true; error = nil; preview = nil
        defer { busy = false }
        do {
            let value = try await service.providerPreviewV2(target, provider: selectedProvider)
            preview = value; reportedSaved = value.value.contract.saved
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let preview else { return }
        busy = true; blocksMutations = true; error = nil
        defer { busy = false }
        do {
            switch try await service.applyProviderV2(target, preview: preview, clientCommandID: UUID().uuidString) {
            case .saved(let receipt):
                lastApply = receipt; reportedSaved = receipt.value.contract.saved
                startEligibleApply = receipt; blocksMutations = false; self.preview = nil
            case .refused(let reason):
                error = reason; blocksMutations = false; self.preview = nil; startEligibleApply = nil
            case .conflict(let evidence):
                conflict = evidence; reportedSaved = evidence.saved; startEligibleApply = nil; self.preview = nil
                error = "The desktop acknowledged a write that differs from this proposal. No session was started. Review the saved settings on the desktop before another change."
            }
        } catch {
            // No retry, new ID or equal fresh read can turn missing evidence into a receipt.
            startEligibleApply = nil; self.preview = nil; self.error = error.localizedDescription
            if case CompanionServiceError.unavailable = error { blocksMutations = false }
            if case CompanionServiceError.rejected = error { blocksMutations = false }
        }
    }
    /// Called only after the person's separate confirmation. Revalidate immediately before Start.
    func startNew() async {
        guard canStart, let applied = startEligibleApply else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let witness = try await service.providerPreviewV2(target, provider: applied.value.contract.saved.provider)
            reportedSaved = witness.value.contract.saved
            // Start uses the Apply-issued token, NEVER the original proposal token or a new token.
            guard witness.epoch == applied.epoch, witness.value.contract.saved == applied.value.contract.saved,
                  witness.value.contract.proposed == applied.value.contract.saved,
                  witness.value.preview.expectedState == applied.value.nextWake?.readyToken,
                  witness.value.permitsApply(capability: witness.capability),
                  requestedRuntime == "default" || requestedRuntime == witness.value.preview.outcome.targetRuntime.rawValue else {
                startEligibleApply = nil; preview = nil
                error = "The current desktop state no longer matches the Apply receipt. Review a fresh proposal; no Start was sent."
                return
            }
            blocksMutations = true
            switch try await service.startProviderV2(target, applied: applied, witness: witness, clientCommandID: UUID().uuidString) {
            case .evidence(let value, let completed):
                lastStart = value; startEligibleApply = nil; preview = nil; blocksMutations = false
                error = completed ? nil : "The Start command did not complete successfully. Its historical creation evidence is shown below. Check the desktop before another Start."
            case .refused(let reason):
                error = reason; blocksMutations = false; startEligibleApply = nil; preview = nil
            }
        } catch {
            startEligibleApply = nil; preview = nil; self.error = error.localizedDescription
            if case CompanionServiceError.unavailable = error { blocksMutations = false }
            if case CompanionServiceError.rejected = error { blocksMutations = false }
        }
    }
    /// Reviewing held evidence is entirely local; never calls execute or dispatches a command.
    func reviewHeldResult() {
        error = "Only already-held receipts are shown. An unconfirmed action stays unknown after reopen, reconnect or an equal settings read. Check the desktop; this app will not send it again."
    }
}
