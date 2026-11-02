import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionSessionStartTests {
    private func event(_ type: String, _ seq: Int64, _ data: [String: AnnexJSON] = [:], session: String = "s1") -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(seq), "ts": .integer(1_700_000_000_000 + seq),
                 "type": .string(type), "data": .object(data)])
    }
    private func messages(_ projector: CompanionChatProjector) -> [CompanionMessage] {
        projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }
    }
    private func runningSession() -> CompanionChatProjector {
        var p = CompanionChatProjector()
        p.apply(event("session_started", 1, ["capabilities": .object(["queue": .string("client")])]))
        p.apply(event("turn_started", 2, ["trigger": .string("prompt")]))
        p.apply(event("user_message", 3, ["messageId": .string("waiting"), "delivery": .string("queued"),
            "content": .array([.object(["type": .string("text"), "text": .string("Follow-up")])])]))
        p.apply(event("queue_state", 4, ["queuedMessageIds": .array([.string("waiting")]),
            "transition": .object(["messageIds": .array([.string("waiting")]), "status": .string("queued")])]))
        p.apply(event("agent_message_chunk", 5, ["messageId": .string("reply"), "text": .string("Partial reply")]))
        p.apply(event("plan_document", 6, ["planId": .string("plan"), "markdown": .string("# Partial plan"), "status": .string("streaming")]))
        return p
    }

    @Test(arguments: ["running", "waiting_permission", "waiting_input", "error", "sleeping", "idle"], ["absent", "true", "false"])
    func sameSessionStartResetsLifecycleAndFinishesEveryStream(state: String, resumed: String) {
        var p = runningSession()
        p.apply(event("session_state", 7, ["state": .string(state)]))
        #expect(messages(p).filter(\.isStreaming).count == 2)
        var data: [String: AnnexJSON] = ["model": .string("New model"),
            "capabilities": .object(["queue": .string("native"), "steer": .bool(true)])]
        if resumed != "absent" { data["resumed"] = .bool(resumed == "true") }
        let start = event("session_started", 8, data)
        p.apply(start)
        #expect(p.status == .idle)
        #expect(p.turnStartedAt == nil)
        #expect(messages(p).allSatisfy { !$0.isStreaming })
        #expect(p.model == "New model" && p.capabilities.contains(.steer))
        #expect(messages(p).map(\.id) == ["reply", "plan-document-plan", "waiting"])
        #expect(messages(p).map(\.text) == ["Partial reply", "# Partial plan", "Follow-up"])
        #expect(messages(p).last?.queueState == .failed && p.queuedMessageIDs.isEmpty)

        // Settlement reorders the queue row; updates must keep using #230's rebuilt item index.
        p.apply(event("agent_message", 9, ["messageId": .string("reply"), "text": .string("Final reply")]))
        #expect(messages(p).map(\.text) == ["Final reply", "# Partial plan", "Follow-up"])
        p.apply(event("turn_started", 10, ["trigger": .string("prompt")]))
        p.apply(event("agent_message_chunk", 11, ["messageId": .string("new-reply"), "text": .string("New run")]))
        let active = p.items
        let newTurnTime = p.turnStartedAt
        p.apply(start)
        #expect(p.status == .working && p.turnStartedAt == newTurnTime && newTurnTime != nil)
        #expect(p.items == active, "Replayed starts cannot stop a newer turn's streams")
    }

    @Test func sessionInfoPreservesTheRunningTurnAndItsStreams() {
        var p = runningSession()
        let startedAt = p.turnStartedAt
        let items = p.items
        p.apply(event("session_info", 7, ["model": .string("Updated model")]))
        #expect(p.status == .working && p.turnStartedAt == startedAt && startedAt != nil)
        #expect(p.items == items && messages(p).filter(\.isStreaming).count == 2)
        #expect(messages(p).first?.queueState == .queued)
        #expect(p.model == "Updated model")
    }

    @Test func differentSessionStillStartsWithAnEmptyTimeline() {
        var p = runningSession()
        p.apply(event("session_started", 1, ["model": .string("New session model")], session: "s2"))
        #expect(p.sessionID == "s2" && p.lastSequence == 1)
        #expect(p.items.isEmpty && p.queuedMessageIDs.isEmpty && p.turnStartedAt == nil)
        #expect(p.model == "New session model")
        p.apply(event("agent_message_chunk", 2, ["messageId": .string("reply"), "text": .string("Fresh reply")], session: "s2"))
        #expect(messages(p).map(\.text) == ["Fresh reply"])
    }
}
