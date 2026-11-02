import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct DesktopRevisedSnapshotProposalTests {
    private func chat(_ type: String, _ sequence: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
        LiveServiceHarness.chatEvent("s1", sequence: sequence, type: type, data: data)
    }

    @Test(arguments: [false, true], [false, true])
    func streamingChatCannotAdvanceAnInitialCheckpointPastUndeliveredState(initial: Bool, currentAtSend: Bool) async throws {
        let harness = try await LiveServiceHarness.start()
        defer { harness.stop() }
        let baseEvents = [
            chat("session_started", 1, ["capabilities": .object(["chat": .bool(true)])]),
            chat("user_message", 2, ["messageId": .string("q"), "delivery": .string("queued"), "content": .array([])]),
            chat("tool_call", 3, ["toolCallId": .string("t"), "title": .string("Tests"), "status": .string("in_progress")]),
            chat("turn_started", 4, [:])]
        let permission = chat("permission_request", 9, ["requestId": .string("p"), "title": .string("Approve tests"), "options": .array([])])
        let duringBuild = [
            chat("agent_message", 5, ["messageId": .string("answer"), "text": .string("Final answer")]),
            chat("tool_call_update", 6, ["toolCallId": .string("t"), "status": .string("completed"), "rawOutput": .string("done")]),
            chat("queue_state", 7, ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string("q")]), "status": .string("delivered")])]),
            chat("session_state", 8, ["state": .string("idle")]), permission]
        let base: AnnexJSON = .object(["sessionId": .string("s1"), "state": .string("running"), "events": .array(baseEvents),
            "capabilities": .object(["chat": .bool(true)]), "queuedMessageIds": .array([.string("q")]), "queueStateSeq": .integer(4), "queueRemovalSupported": .bool(true)])
        await harness.transport.setRead("chat", base)
        await harness.store.load(harness.target)
        var fresh = base
        if case .object(var fields) = base {
            fields["events"] = .array(baseEvents + duringBuild)
            fields["state"] = .string("waiting_permission")
            fields["pendingPermissions"] = .array([permission])
            fields["queuedMessageIds"] = .array([]); fields["queueStateSeq"] = .integer(7)
            fresh = .object(fields)
        }
        // Fresh history is available, but ordinary catalog/status catch-up does not fold its transcript.
        await harness.transport.setRead("chat", fresh)
        await harness.transport.setRead("chatHistory", fresh)
        var cursor = AnnexReplayCursor()
        if !initial { #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 100)) == .deliver) }
        let checkpoint: Int64 = currentAtSend ? 105 : 100
        let quick: AnnexJSON = .object(["id": .string("q5"), "name": .string("New helper"), "kind": .string("quick"), "projectId": .string("project"), "status": .string("running")])
        guard case .message(let catalog) = harness.snapshotEvent(["quickAgents": .object(["project": .array([quick])]), "helperRequests": .array([])]) else { return }
        let snapshot = AnnexEnvelope(type: "snapshot", payload: catalog.payload, lastSeq: checkpoint)
        // The harness already has a connected service and a cached chat. A first
        // snapshot belongs to a new connection, unlike a same-socket refresh.
        // #216 deliberately ignores redundant connected events on an established socket.
        if initial { await harness.transport.emit(.connection(.connecting)) }
        let statusReadsBeforeSnapshot = await harness.transport.readRoutes.filter { $0.name == "chatHistory" }.count
        let snapshotDecision = cursor.accept(snapshot)
        if case .resync(let reason) = snapshotDecision { await harness.transport.emit(.resyncRequired(reason)) }
        await harness.transport.emit(.connection(.connected))
        await harness.transport.emit(.message(snapshot))
        for replayed in [false, true] {
            for (index, event) in duringBuild.enumerated() {
                let frame = AnnexEnvelope(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": event]),
                                          seq: 101 + Int64(index), replayed: replayed)
                let decision = cursor.accept(frame)
                if decision == .deliver { await harness.transport.emit(.message(frame)) }
                else { #expect(decision == .duplicate) }
            }
        }
        let expectedLocalSequence = initial && currentAtSend ? 4 : 9
        try await harness.waitUntil {
            harness.store.conversation(for: harness.target).lastSequence == expectedLocalSequence
                && harness.host?.connection == .connected
                && harness.host?.agent(for: harness.target)?.status == .approval
                && harness.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true
        }
        if initial && currentAtSend {
            #expect(await harness.transport.readRoutes.filter { $0.name == "chatHistory" }.count == statusReadsBeforeSnapshot + 1,
                    "The new connection performs status-only catch-up; it does not replace the transcript")
        }
        let items = harness.store.conversation(for: harness.target).items
        let answer = items.compactMap { if case .message(let message) = $0, message.id == "answer" { message.text } else { nil } }.first
        let tool = items.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }.first
        let queued = items.compactMap { if case .message(let message) = $0, message.id == "q" { message.queueState } else { nil } }.first
        let approval = items.contains { if case .approval(let request) = $0 { request.id == "p" } else { false } }
        let lost = initial && currentAtSend
        #expect(answer == (lost ? nil : "Final answer"))
        #expect(tool?.state == (lost ? .running : .completed))
        #expect(queued == (lost ? .queued : .delivered))
        #expect(approval == !lost)
        #expect(harness.host?.agent(for: harness.target)?.status == .approval, "Status catch-up can heal the badge without restoring the lost prompt/tool/queue/transcript")
        #expect(harness.host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count == 1)
        #expect(cursor.lastSequence == 105)
        print("Proposal initial=\(initial), currentAtSend=\(currentAtSend): answer=\(answer ?? "MISSING"), tool=\(String(describing: tool?.state)), queue=\(String(describing: queued)), prompt=\(approval), catalog q5=1, status=approval, snapshot decision=\(snapshotDecision)")
        // Explicit full-history recovery repairs it, but the global replay cannot: all those seqs were skipped.
        await harness.store.load(harness.target, force: true)
        let recovered = harness.store.conversation(for: harness.target).items
        #expect(recovered.contains { if case .message(let message) = $0 { message.id == "answer" && message.text == "Final answer" } else { false } })
        #expect(recovered.contains { if case .tool(let tool) = $0 { tool.id == "t" && tool.state == .completed } else { false } })
        #expect(recovered.contains { if case .approval(let request) = $0 { request.id == "p" } else { false } })
    }

    @Test func continuousChatStreamingDoesNotStarveMatchingRefreshesOn147() {
        var cursor = AnnexReplayCursor()
        #expect(cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: 0)) == .deliver)
        var acceptedRefreshes = 0
        for seq in Int64(1)...1000 {
            #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: seq)) == .deliver)
            if seq % 10 == 0 {
                if cursor.accept(AnnexEnvelope(type: "snapshot", lastSeq: seq)) == .deliver { acceptedRefreshes += 1 }
            }
            #expect(cursor.accept(AnnexEnvelope(type: "chat:event", seq: seq, replayed: true)) == .duplicate)
        }
        #expect(acceptedRefreshes == 100)
        #expect(cursor.lastSequence == 1000)
    }
}
