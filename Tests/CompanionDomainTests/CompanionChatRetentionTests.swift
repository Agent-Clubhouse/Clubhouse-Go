import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionChatRetentionTests {
    private func count(_ property: String, in projector: CompanionChatProjector) -> Int {
        let value = Mirror(reflecting: projector).children.first { $0.label == property }!.value
        return Mirror(reflecting: value).children.count
    }
    @Test func deliveredQueueDropsSubmissionCopies() {
        var projector = CompanionChatProjector()
        for i in 0..<100 {
            let id = "queued-\(i)"
            projector.apply(CompanionLongChatPerformanceTests.event("user_message", 3 * i + 1,
                ["messageId": .string(id), "delivery": .string("queued"), "content": .array([.object(["type": .string("text"), "text": .string(String(repeating: "queued", count: 200))])])]))
            projector.apply(CompanionLongChatPerformanceTests.event("queue_state", 3 * i + 2,
                ["queuedMessageIds": .array([]), "transition": .object(["messageIds": .array([.string(id)]), "status": .string("delivered")])]))
        }
        #expect(projector.items.count == 100, "Delivery history and Copy message stay intact")
        #expect(count("queuedContentParts", in: projector) == 0, "Only pending submissions need the raw coalescing copies")
    }
    @Test func sessionChangeDropsCommandMappings() {
        var projector = CompanionChatProjector()
        projector.apply(CompanionLongChatPerformanceTests.event("agent_message", 1, ["messageId": .string("old"), "text": .string("old")]))
        for i in 0..<100 { _ = projector.reconcile(messageID: "old-\(i)", commandID: "command-\(i)") }
        projector.apply(.object(["sessionId": .string("new"), "seq": .integer(1), "type": .string("session_started"), "data": .object([:])]))
        #expect(projector.commandIDsByMessage.isEmpty)
    }
}
