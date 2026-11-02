import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Lifecycle cases absent from the desktop's committed queued-bursts.json.
@Suite struct CompanionQueueLifecycleTests {
    private func event(_ type: String, _ seq: Int64, _ data: [String: AnnexJSON] = [:], session: String = "s1") -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(seq), "ts": .integer(1_700_000_000_000 + seq),
                 "type": .string(type), "data": .object(data)])
    }
    private func user(_ id: String, _ seq: Int64, delivery: String = "queued", text: String = "Same words") -> AnnexJSON {
        event("user_message", seq, ["messageId": .string(id), "source": .string("annex"), "delivery": .string(delivery),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }
    private func queue(_ id: String, _ seq: Int64, _ state: String, waiting: [String] = []) -> AnnexJSON {
        event("queue_state", seq, ["queuedMessageIds": .array(waiting.map(AnnexJSON.string)),
            "transition": .object(["messageIds": .array([.string(id)]), "status": .string(state)])])
    }
    private func messages(_ projector: CompanionChatProjector) -> [CompanionMessage] {
        projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }
    }
    private func mixedQueue() -> [AnnexJSON] {
        [event("session_started", 1, ["capabilities": .object(["queue": .string("client")])]),
         user("waiting", 2), queue("waiting", 3, "queued", waiting: ["waiting"]),
         event("agent_message", 4, ["messageId": .string("before"), "text": .string("Working")]),
         user("sending", 5), queue("sending", 6, "dispatching", waiting: ["waiting"]),
         user("delivered", 7), queue("delivered", 8, "delivered", waiting: ["waiting"]),
         event("agent_message", 9, ["messageId": .string("after"), "text": .string("More work")])]
    }

    @Test(arguments: ["native", "legacy", "client"])
    func systemTurnsLeaveTheQueueForTheNextNonSystemTurn(kind: String) {
        var p = CompanionChatProjector()
        p.queueStateEventsSupported = kind != "legacy"
        p.apply(event("session_started", 1, ["capabilities": .object(kind == "legacy" ? [:] : ["queue": .string(kind)])]))
        p.apply(user("first", 2)); p.apply(user("second", 3))
        p.apply(event("turn_started", 4, ["trigger": .string("system")]))
        #expect(p.status == .working && p.turnStartedAt != nil)
        #expect(messages(p).map(\.queueState) == [.submitted, .submitted])
        p.apply(event("turn_ended", 5, ["stopReason": .string("end_turn")]))
        p.apply(event("turn_started", 6, ["trigger": .string("prompt")]))
        #expect(messages(p).map(\.queueState) == (kind == "client" ? [.submitted, .submitted] : [nil, .submitted]))
    }

    @Test(arguments: ["stopped", "idle_timeout", "error"])
    func endingTheSessionSettlesQueuedAndSendingButKeepsDeliveredRows(reason: String) {
        var p = CompanionChatProjector(); mixedQueue().forEach { p.apply($0) }
        p.apply(event("session_ended", 10, ["reason": .string(reason)]))
        #expect(messages(p).map(\.id) == ["before", "sending", "delivered", "after", "waiting"])
        #expect(messages(p).filter { ["waiting", "sending"].contains($0.id) }.allSatisfy { $0.queueState == .failed && $0.delivery == .confirmed })
        #expect(messages(p).first { $0.id == "delivered" }?.queueState == .delivered)
        #expect(p.queuedMessageIDs.isEmpty && !p.queueRemovalSupported && !p.capabilities.contains(.removeQueued))
        p.apply(event("turn_started", 11, ["trigger": .string("prompt")]))
        #expect(messages(p).first { $0.id == "waiting" }?.queueState == .failed)
    }

    @Test(arguments: ["native", "legacy"])
    func endingAnUnacknowledgedProviderQueueMarksItUnknownWithoutRetry(kind: String) {
        var p = CompanionChatProjector()
        p.apply(event("session_started", 1, ["capabilities": .object(kind == "legacy" ? [:] : ["queue": .string(kind)])]))
        p.apply(user("waiting", 2)); p.apply(event("session_ended", 3, ["reason": .string("stopped")]))
        #expect(messages(p).first?.queueState == .failed)
        #expect(messages(p).first?.delivery == .confirmed, "Queue uncertainty does not become a retryable send failure")
        #expect(p.queuedMessageIDs.isEmpty)
    }

    @Test(arguments: ["absent", "true", "false"])
    func anotherRunInTheSameSessionSettlesEvenWithoutTheResumedFlag(resumed: String) {
        var p = CompanionChatProjector(); mixedQueue().forEach { p.apply($0) }
        var data: [String: AnnexJSON] = ["capabilities": .object(["queue": .string("native")])]
        if resumed != "absent" { data["resumed"] = .bool(resumed == "true") }
        let start = event("session_started", 10, data)
        p.apply(start); p.apply(start)
        p.apply(event("turn_started", 11, ["trigger": .string("prompt")]))
        #expect(messages(p).map(\.id) == ["before", "sending", "delivered", "after", "waiting"])
        #expect(messages(p).filter { ["waiting", "sending"].contains($0.id) }.allSatisfy { $0.queueState == .failed })
        #expect(messages(p).first { $0.id == "delivered" }?.queueState == .delivered)
        #expect(p.queuedMessageIDs.isEmpty)
    }

    @Test func sessionInfoKeepsWaitingRowsAndDifferentSessionStartsEmpty() {
        var p = CompanionChatProjector(); mixedQueue().forEach { p.apply($0) }
        p.apply(event("session_info", 10, ["model": .string("new model")]))
        #expect(messages(p).first { $0.id == "waiting" }?.queueState == .queued)
        p.apply(event("session_started", 1, [:], session: "new-session"))
        #expect(p.items.isEmpty && p.queuedMessageIDs.isEmpty)
        #expect(p.sessionID == "new-session" && p.lastSequence == 1)
    }

    @Test(arguments: ["queue_state", "user_message"])
    func lateDeliveryClearsOnlyTheMatchingSettledMark(type: String) {
        var p = CompanionChatProjector(); mixedQueue().forEach { p.apply($0) }
        p.apply(event("session_ended", 10, ["reason": .string("stopped")]))
        p.apply(user("different-id", 11, delivery: "steer"))
        #expect(messages(p).first { $0.id == "waiting" }?.queueState == .failed, "Equal text is a different submission")
        if type == "queue_state" { p.apply(queue("waiting", 12, "delivered")) }
        else { p.apply(user("waiting", 12, delivery: "prompt")) }
        #expect(messages(p).filter { $0.id == "waiting" }.count == 1)
        #expect(messages(p).first { $0.id == "waiting" }?.queueState == (type == "queue_state" ? .delivered : nil))
        #expect(messages(p).first { $0.id == "sending" }?.queueState == .failed)
    }

    @MainActor @Test(arguments: ["native", "client", "in-flight"])
    func deadHistorySettlesBeforeItsEmptyQueueSnapshotCanErasePendingEvidence(kind: String) async throws {
        let events = kind == "client" ? mixedQueue() : [user("waiting", 1)]
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        let snapshot = LiveServiceHarness.chatSnapshot(fields: ["events": .array(events), "readOnly": .bool(true),
            "state": .string("sleeping"), "capabilities": .object(["queue": .string(kind == "native" ? "native" : "client")]),
            "queueStateSeq": .integer(0), "queuedMessageIds": .array([]), "queueRemovalSupported": .bool(false)])
        await harness.transport.setRead("chat", snapshot)
        let first = try await harness.service.history(for: harness.target)
        let second = try await harness.service.history(for: harness.target)
        #expect(first.items == second.items, "Repeated dead-history reads are stable")
        let rows = first.items.compactMap { if case .message(let m) = $0 { m } else { nil } }
        let pending = rows.filter { ["waiting", "sending"].contains($0.id) }
        #expect(!pending.isEmpty && pending.allSatisfy { $0.queueState == .failed })
        #expect(first.capabilities?.contains(.removeQueued) != true)
    }

    @MainActor @Test func pagedDeadHistorySettlesOnlyAfterEachPageIsFolded() async throws {
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        let reader = CompanionArchiveReader(transport: harness.transport, target: harness.target, sessionID: "s1")
        let events = mixedQueue()
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "readOnly": .bool(true),
            "events": .array(Array(events.suffix(6))), "nextBeforeSeq": .integer(4)]))
        let tail = try await reader.load(before: nil)
        #expect(tail.items.contains { if case .message(let m) = $0 { return m.id == "sending" && m.queueState == .failed }; return false })
        // Earlier pages may omit the flag; they still belong to the same dead transcript.
        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("s1"), "events": .array(Array(events.prefix(4)))]))
        let whole = try await reader.load(before: 4)
        let rows = whole.items.compactMap { if case .message(let m) = $0 { m } else { nil } }
        #expect(rows.map(\.id) == ["before", "sending", "delivered", "after", "waiting"])
        #expect(rows.first { $0.id == "waiting" }?.queueState == .failed)
        #expect(rows.first { $0.id == "sending" }?.queueState == .failed)
        #expect(rows.first { $0.id == "delivered" }?.queueState == .delivered)
    }
}
