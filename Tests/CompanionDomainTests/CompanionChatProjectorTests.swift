import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionChatProjectorTests {
    private func event(_ type: String, seq: Int64, session: String = "session-a", data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["v": .integer(2), "agentId": .string("agent"), "sessionId": .string(session), "seq": .integer(seq), "ts": .integer(1_700_000_000_000), "type": .string(type), "data": .object(data)])
    }

    @Test func finalMessageReplacesChunksAndReplayIsIgnored() {
        var projection = CompanionChatProjector()
        let chunk = event("agent_message_chunk", seq: 10, data: ["messageId": .string("message"), "text": .string("Hel")])
        projection.apply(chunk); projection.apply(chunk)
        projection.apply(event("agent_message", seq: 12, data: ["messageId": .string("message"), "text": .string("Hello")]))
        #expect(projection.items.count == 1)
        guard case .message(let message) = projection.items[0] else { Issue.record("Expected message"); return }
        #expect(message.text == "Hello")
        #expect(!message.isStreaming)
    }

    @Test func sessionChangeResetsSequenceAndTimeline() {
        var projection = CompanionChatProjector()
        projection.apply(event("agent_message", seq: 90, data: ["messageId": .string("old"), "text": .string("Old session")]))
        projection.apply(event("agent_message", seq: 1, session: "new-session", data: ["messageId": .string("new"), "text": .string("New session")]))
        #expect(projection.lastSequence == 1)
        #expect(projection.items.map(\.id) == ["message:new"])
    }

    /// The desktop lists every option. Older desktops take only the one-off ones (`persistent_approval_not_supported`);
    /// desktops with `permissions.persistentApprovals` take them all.
    @Test func persistentPermissionOptionsAreAnswerableOnlyWhenTheDesktopTakesThem() {
        var projection = CompanionChatProjector()
        projection.apply(event("permission_request", seq: 1, data: [
            "requestId": .string("p"), "title": .string("Run command"), "options": .array([
                .object(["optionId": .string("once-native"), "kind": .string("allow_once"), "label": .string("Allow once")]),
                .object(["optionId": .string("always-native"), "kind": .string("allow_always"), "label": .string("Always allow")]),
                .object(["optionId": .string("reject-native"), "kind": .string("reject_once"), "label": .string("Reject")])
            ])]))
        guard case .approval(let approval) = projection.items[0] else { Issue.record("Expected approval"); return }
        #expect(approval.options.map(\.id) == ["once-native", "always-native", "reject-native"])
        #expect(approval.options.filter { $0.isAnswerable(persistentApprovals: false) }.map(\.id) == ["once-native", "reject-native"])
        #expect(approval.options.filter { $0.isAnswerable(persistentApprovals: true) }.map(\.id) == ["once-native", "always-native", "reject-native"])
        #expect(approval.options[1].kind == .allowAlways)
        #expect(approval.title == "Run command")
    }

    @Test func pendingInteractionOutsideHistoryTailSurvives() {
        var projection = CompanionChatProjector()
        projection.apply(event("agent_message", seq: 40, data: ["messageId": .string("latest"), "text": .string("Waiting")]))
        projection.apply(event("permission_request", seq: 2, data: ["requestId": .string("pending"), "title": .string("Approval"), "options": .array([])]), allowOlderPending: true)
        #expect(projection.lastSequence == 40)
        #expect(projection.items.contains { $0.id == "approval:pending" })
    }

    @Test func toolAppendUpdatesKeepOriginalInputAndName() {
        var projection = CompanionChatProjector()
        projection.apply(event("tool_call", seq: 1, data: ["toolCallId": .string("t"), "title": .string("Tests"), "rawInput": .string("swift test"), "status": .string("in_progress")]))
        for sequence in 2...3 {
            projection.apply(event("tool_call_update", seq: Int64(sequence), data: ["toolCallId": .string("t"), "contentMode": .string("append"), "content": .array([.object(["type": .string("text"), "text": .string("line\(sequence)\n")])])]))
        }
        projection.apply(event("tool_call_update", seq: 4, data: ["toolCallId": .string("t"), "status": .string("completed")]))
        guard case .tool(let tool) = projection.items[0] else { Issue.record("Expected tool"); return }
        #expect(tool.name == "Tests")
        #expect(tool.summary == "swift test")
        #expect(tool.output == "line2\nline3\n")
        #expect(tool.state == .completed)
    }

    @Test func receiptReconcilesMessageThatArrivedBeforeHTTPReply() {
        var projection = CompanionChatProjector()
        projection.apply(event("user_message", seq: 1, data: ["messageId": .string("server"), "content": .array([.object(["type": .string("text"), "text": .string("Do work")])])]))
        let result = projection.reconcile(messageID: "server", commandID: "client")
        guard case .message(let message) = result else { Issue.record("Expected reconciled message"); return }
        #expect(message.clientCommandID == "client")
        #expect(message.delivery == .confirmed)
    }

    @Test func structuredQuestionsValidateRequiredChoicesAndFreeText() {
        let question = CompanionQuestion(id: "q", prompts: [
            .init(id: "choice", text: "Choose", options: [.init(id: "one", label: "One")], allowsMultiple: false, allowsFreeText: false),
            .init(id: "text", text: "Explain", options: [], allowsMultiple: false, allowsFreeText: true)
        ])
        #expect(!CompanionStore.validAnswers(["choice": .text("not-an-option"), "text": .text("Details")], for: question))
        #expect(!CompanionStore.validAnswers(["choice": .text("one")], for: question))
        #expect(CompanionStore.validAnswers(["choice": .text("one"), "text": .text("Details")], for: question))
    }

    @Test func queueSnapshotWatermarkRejectsOlderTranscriptQueueState() {
        var projection = CompanionChatProjector()
        projection.apply(event("user_message", seq: 10, data: ["messageId": .string("m"), "delivery": .string("queued"), "content": .array([])]))
        projection.applyQueueSnapshot(.object(["queuedMessageIds": .array([.string("m")]), "queueStateSeq": .integer(40), "queueRemovalSupported": .bool(true)]))
        projection.apply(event("queue_state", seq: 30, data: ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string("m")]), "status": .string("delivered")])]))
        guard case .message(let queued) = projection.items[0] else { Issue.record("Expected queued message"); return }
        #expect(queued.queueState == .queued)
        #expect(projection.queueStateSequence == 40)
        projection.apply(event("queue_state", seq: 41, data: ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string("m")]), "status": .string("dispatching")])]))
        guard case .message(let dispatching) = projection.items[0] else { Issue.record("Expected message"); return }
        #expect(dispatching.queueState == .dispatching)
        #expect(projection.queuedMessageIDs.isEmpty)
        projection.apply(event("queue_removed", seq: 42, data: ["messageIds": .array([.string("m")])]))
        projection.applyQueueSnapshot(.object(["queuedMessageIds": .array([.string("m")]), "queueStateSeq": .integer(41), "queueRemovalSupported": .bool(true)]))
        guard case .message(let removed) = projection.items[0] else { Issue.record("Expected message"); return }
        #expect(removed.queueState == .removed)
        #expect(projection.queuedMessageIDs.isEmpty)
    }

    @Test func providerQueueIsSubmittedAndNewSessionResetsQueueWatermark() {
        var projection = CompanionChatProjector()
        projection.apply(event("session_started", seq: 1, data: ["capabilities": .object(["queue": .string("native")])]))
        projection.apply(event("user_message", seq: 2, data: ["messageId": .string("m"), "delivery": .string("queued"), "content": .array([])]))
        guard case .message(let message) = projection.items[0] else { Issue.record("Expected message"); return }
        #expect(message.queueState == .submitted)
        #expect(!projection.capabilities.contains(.removeQueued))
        projection.applyQueueSnapshot(.object(["queueStateSeq": .integer(100), "queuedMessageIds": .array([])]))
        projection.apply(event("queue_state", seq: 2, session: "replacement", data: ["queuedMessageIds": .array([.string("new")])]))
        #expect(projection.queueStateSequence == 2)
        #expect(projection.queuedMessageIDs == ["new"])
    }
}
