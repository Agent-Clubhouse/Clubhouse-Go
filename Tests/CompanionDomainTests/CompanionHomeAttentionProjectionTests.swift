import Foundation
import Observation
import Testing
@testable import CompanionDomain

@MainActor private final class HomeAttentionService: CompanionService {
    enum Outcome: CaseIterable, Sendable { case success, refused, uncertain }
    var outcome: Outcome = .success
    var historyValue = CompanionHistory(items: [])
    var checkpoint: (() -> Void)?
    var commands = 0
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { historyValue }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { try finish() }
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws { try finish() }
    private func finish() throws {
        commands += 1
        checkpoint?() // The Store has already changed the decision to submitting.
        switch outcome {
        case .success: break
        case .refused: throw CompanionServiceError.rejected("Generated refusal")
        case .uncertain: throw CompanionServiceError.uncertain("Generated lost receipt")
        }
    }
}

@Suite @MainActor struct CompanionHomeAttentionProjectionTests {
    private func hosts() -> [CompanionHost] {
        (0..<2).map { index in
            .init(id: "generated-\(index)", name: "Generated desktop \(index)", endpoint: "", connection: .connected,
                  projects: [.init(id: "project", name: "Generated project", agents: [
                    .init(id: .init(hostID: "generated-\(index)", projectID: "project", agentID: "agent"),
                          name: "Generated agent \(index)", subtitle: "", status: .approval, capabilities: [.approve, .answer])
                  ])], hasLoadedCatalog: true)
        }
    }
    private func approval(_ id: String, now: Date) -> CompanionApproval {
        .init(id: id, toolName: "Edit", summary: "Generated decision \(id)", deadline: now.addingTimeInterval(3_600),
              options: [.init(id: "deny", label: "Deny", kind: .rejectOnce)])
    }
    private func question(_ id: String) -> CompanionQuestion {
        .init(id: id, prompts: [.init(id: "prompt", text: "Generated question \(id)", options: [], allowsMultiple: false, allowsFreeText: true)])
    }
    private func assertParity(_ store: CompanionStore, targets: [CompanionTarget], now: Date, step: String) {
        #expect(store.homeAttentionItems(now: now) == store.attentionItems(now: now), "Attention parity after \(step)")
        for target in targets {
            let expected = store.conversation(for: target).items.filter { item in
                switch item { case .approval, .question: true; default: false }
            }
            #expect((store.homeDecisionItems[target] ?? []) == expected, "Raw decision parity after \(step), \(target.hostID)")
        }
    }

    /// Exhaustive small matrix: both target identities × all three command outcomes.
    /// Check after every event/load/command AND inside the submitting service boundary.
    @Test(arguments: [0, 1], HomeAttentionService.Outcome.allCases)
    func mixedSequencesNeverDrift(targetIndex: Int, outcome: HomeAttentionService.Outcome) async throws {
        let now = Date(), service = HomeAttentionService()
        let store = CompanionStore(service: service)
        defer { service.checkpoint = nil; store.shutdown() }
        var snapshots = hosts()
        let targets = snapshots.flatMap(\.allAgents).map(\.id), target = targets[targetIndex]
        func parity(_ step: String) { assertParity(store, targets: targets, now: now, step: step) }
        func apply(_ event: CompanionEvent, _ step: String) { store.apply(event); parity(step) }
        apply(.hosts(snapshots), "initial hosts")

        let a = approval("history", now: now), q = question("history-question")
        service.historyValue = .init(items: [.approval(a), .question(q)], lastSequence: 10, sessionID: "generated-session")
        await store.load(target, force: true); parity("history replace")
        #expect(store.homeDecisionItems[target]?.count == 2)

        apply(.timeline(target, items: [.question(q), .approval(a)], sequence: 20, reset: true, sessionID: "generated-session"), "timeline replace/order")
        apply(.upsert(target, .approval(approval("stale", now: now)), sequence: 19), "rejected old sequence")
        #expect(store.homeDecisionItems[target]?.contains { $0.id == "approval:stale" } == false)
        apply(.upsert(target, .approval(approval("new", now: now)), sequence: 21), "approval upsert")
        apply(.upsert(target, .question(question("new-question")), sequence: 22), "question upsert")
        var revisedApproval = approval("new", now: now)
        revisedApproval.toolName = "Shell"
        revisedApproval.summary = "Changed generated summary"
        revisedApproval.options[0].label = "Changed deny label"
        apply(.upsert(target, .approval(revisedApproval), sequence: nil), "same-ID approval metadata")
        var revisedQuestion = question("new-question")
        revisedQuestion.prompts[0].text = "Changed generated prompt"
        apply(.upsert(target, .question(revisedQuestion), sequence: nil), "same-ID question metadata")
        for chunk in 0..<20 {
            apply(.textDelta(target, messageID: "stream", text: " generated", sequence: 23 + chunk), "plain chunk \(chunk)")
        }
        apply(.streamFinished(target, messageID: "stream", sequence: 43), "stream finished")

        // Local transitions are not wire events. Test their true submitting and completion paths.
        service.outcome = outcome
        var submittingChecks = 0
        service.checkpoint = {
            parity("local submitting")
            let hasSubmitting = store.conversation(for: target).items.contains { item in
                switch item {
                case .approval(let value): value.resolution == .submitting
                case .question(let value): value.resolution == .submitting
                default: false
                }
            }
            #expect(hasSubmitting)
            submittingChecks += 1
        }
        await store.respond(a, option: a.options[0], target: target); parity("approval completion \(outcome)")
        let approvalResolution = store.conversation(for: target).items.compactMap { item -> CompanionApproval.Resolution? in
            if case .approval(let value) = item, value.id == a.id { return value.resolution }; return nil
        }.first
        let expectedApproval: CompanionApproval.Resolution = switch outcome { case .success: .denied; case .refused: .pending; case .uncertain: .uncertain }
        #expect(approvalResolution == expectedApproval)

        // A fresh read clears uncertainty before the next real command; it also replaces decisions.
        service.historyValue = .init(items: [.question(q)], lastSequence: 44, sessionID: "generated-session")
        await store.load(target, force: true); parity("fresh history after command")
        await store.answer(q, answers: ["prompt": .text("Generated answer")], target: target); parity("question completion \(outcome)")
        let questionResolution = store.conversation(for: target).items.compactMap { item -> CompanionQuestion.Resolution? in
            if case .question(let value) = item, value.id == q.id { return value.resolution }; return nil
        }.first
        let expectedQuestion: CompanionQuestion.Resolution = switch outcome { case .success: .answered; case .refused: .pending; case .uncertain: .uncertain }
        #expect(questionResolution == expectedQuestion)
        #expect(service.commands == 2 && submittingChecks == 2, "Both real command paths must run")

        // All remaining resolution variants, replacements, and both identities in one event sequence.
        for (index, other) in targets.enumerated() {
            var replacement = approval("replacement-\(index)", now: now)
            let approvalResolutions: [CompanionApproval.Resolution] = [.pending, .submitting, .allowed, .denied, .expired, .cancelled, .uncertain]
            for resolution in approvalResolutions {
                replacement.resolution = resolution
                apply(.upsert(other, .approval(replacement), sequence: nil), "approval resolution \(resolution)")
            }
            var replacementQuestion = question("replacement-question-\(index)")
            let questionResolutions: [CompanionQuestion.Resolution] = [.pending, .submitting, .answered, .cancelled, .uncertain]
            for resolution in questionResolutions {
                replacementQuestion.resolution = resolution
                apply(.upsert(other, .question(replacementQuestion), sequence: nil), "question resolution \(resolution)")
            }
            apply(.timeline(other, items: [], sequence: 100, reset: true, sessionID: "new-session-\(index)"), "timeline clears decisions")
        }
        snapshots[targetIndex].connection = .reconnecting
        apply(.hosts(snapshots), "reconnect")
        apply(.resyncRequired(hostID: target.hostID), "resync")
        snapshots[targetIndex].connection = .connected
        snapshots[targetIndex].controlEpoch = "generated-next-epoch"
        apply(.hosts(snapshots), "new epoch")
        apply(.upsert(target, .approval(a), sequence: nil), "decision after epoch")
        snapshots[targetIndex].projects[0].agents.removeAll()
        apply(.hosts(snapshots), "durable agent removal")
        #expect(store.homeDecisionItems[target] == nil)
        apply(.hosts([]), "desktop removal")
        #expect(store.homeDecisionItems.isEmpty)
    }

    @Test func textChunksDoNotInvalidateHomeAttentionButDecisionChangesDo() async {
        let now = Date(), store = CompanionStore(service: HomeAttentionService())
        defer { store.shutdown() }
        let snapshots = hosts(), targets = snapshots.flatMap(\.allAgents).map(\.id)
        store.apply(.hosts(snapshots))
        store.apply(.upsert(targets[0], .approval(approval("pending", now: now)), sequence: nil))
        await confirmation("No transcript dependency", expectedCount: 0) { changed in
            withObservationTracking { _ = store.homeAttentionItems(now: now) } onChange: { changed() }
            for index in 0..<100 {
                store.apply(.textDelta(targets[index % targets.count], messageID: "stream", text: " generated", sequence: nil))
            }
        }
        // A separate Store keeps the zero-change observer above out of this positive control.
        let live = CompanionStore(service: HomeAttentionService())
        defer { live.shutdown() }
        live.apply(.hosts(snapshots))
        await confirmation("Decision observer is live", expectedCount: 1) { changed in
            withObservationTracking { _ = live.homeAttentionItems(now: now) } onChange: { changed() }
            live.apply(.upsert(targets[0], .question(question("new")), sequence: nil))
        }
        assertParity(store, targets: targets, now: now, step: "observation controls")
        assertParity(live, targets: targets, now: now, step: "positive observation control")
    }
}
