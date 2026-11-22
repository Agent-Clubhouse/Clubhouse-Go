import Foundation
import Observation
import ClubhouseTransport

/// A preview is authority only for this desktop epoch and connection observation.
struct CompanionProviderV2Preview: Sendable {
    let value: AnnexProviderPreviewV2
    let target: CompanionTarget
    let epoch: String
    let generation: UUID
    let capabilityRevision: UUID
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
    private var startWitness: CompanionProviderV2Preview?
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
            && preview.map { $0.value.permitsApply(capability: $0.capability) && service.providerV2WitnessIsCurrent($0, starting: false) } == true
    }
    var canStart: Bool {
        guard canChoose, startAdvertised(), let applied = startEligibleApply, let witness = startWitness else { return false }
        return matchesStartWitness(witness, applied: applied) && service.providerV2WitnessIsCurrent(witness, starting: true)
    }
    func updateRequestedRuntime(_ value: String) {
        guard !busy, requestedRuntime != value else { return }
        requestedRuntime = value; preview = nil; startEligibleApply = nil; startWitness = nil
    }
    func select(_ provider: String) async {
        guard canChoose else { return }
        selectedProvider = provider; preview = nil; startEligibleApply = nil; startWitness = nil
        await refresh()
    }
    /// Read-only even when an operation is unknown. Equal configuration NEVER unlocks it.
    func refresh() async {
        guard canRequest(), !busy, let selectedProvider else { return }
        busy = true; error = nil; preview = nil; startWitness = nil
        defer { busy = false }
        do {
            let value = try await service.providerPreviewV2(target, provider: selectedProvider)
            preview = value; reportedSaved = value.value.contract.saved
            if !blocksMutations, let applied = startEligibleApply, matchesStartWitness(value, applied: applied) {
                startWitness = value
            }
        } catch { self.error = error.localizedDescription }
    }
    func apply() async {
        guard canApply, let preview else { return }
        busy = true; blocksMutations = true; error = nil; startWitness = nil
        defer { busy = false }
        do {
            switch try await service.applyProviderV2(target, preview: preview, clientCommandID: UUID().uuidString) {
            case .saved(let receipt):
                lastApply = receipt; reportedSaved = receipt.value.contract.saved
                startEligibleApply = receipt; startWitness = nil; blocksMutations = false; self.preview = nil
                // A saved receipt alone never enables Start, even briefly.
                if startAdvertised(), receipt.value.nextWake?.readyToken != nil {
                    do {
                        let witness = try await service.providerPreviewV2(target, provider: receipt.value.contract.saved.provider)
                        reportedSaved = witness.value.contract.saved
                        if matchesStartWitness(witness, applied: receipt), service.providerV2WitnessIsCurrent(witness, starting: true) {
                            startWitness = witness
                        } else { error = "Apply was confirmed, but the fresh saved-state check differs. Start is unavailable; review a new proposal." }
                    } catch { self.error = "Apply was confirmed, but a fresh state check failed. Start is unavailable. Refresh reported settings before continuing." }
                }
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
            // Recovery may have taken ownership while the fresh read was in flight.
            // Recheck external admission, not canStart (our own busy flag is set).
            guard canRequest() else {
                startWitness = nil
                error = "Another action is pending for this agent. Review its result before confirming Start again."
                return
            }
            // Start uses the Apply-issued token, NEVER the original proposal token or a new token.
            guard matchesStartWitness(witness, applied: applied), service.providerV2WitnessIsCurrent(witness, starting: true) else {
                startEligibleApply = nil; startWitness = nil; preview = nil
                error = "The current desktop state no longer matches the Apply receipt. Review a fresh proposal; no Start was sent."
                return
            }
            blocksMutations = true; startWitness = nil
            switch try await service.startProviderV2(target, applied: applied, witness: witness, clientCommandID: UUID().uuidString) {
            case .evidence(let value, let completed):
                lastStart = value; startEligibleApply = nil; preview = nil; blocksMutations = !completed
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
    private func matchesStartWitness(_ witness: CompanionProviderV2Preview, applied: CompanionProviderV2Applied) -> Bool {
        witness.target == target && applied.target == target && witness.epoch == applied.epoch
            && witness.value.matches(agent: target.agentID, provider: applied.value.contract.saved.provider, selection: .init())
            && witness.value.contract.saved == applied.value.contract.saved
            && witness.value.contract.proposed == applied.value.contract.saved
            && witness.value.preview.expectedState == applied.value.nextWake?.readyToken
            && witness.value.permitsApply(capability: witness.capability)
            && (requestedRuntime == "default" || requestedRuntime == witness.value.preview.outcome.targetRuntime.rawValue)
    }
    /// Reviewing held evidence is entirely local; never calls execute or dispatches a command.
    func reviewHeldResult() {
        error = "Only already-held receipts are shown. An unconfirmed action stays unknown after reopen, reconnect or an equal settings read. Check the desktop; this app will not send it again."
    }
}
