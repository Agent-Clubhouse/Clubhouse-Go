import Testing
@testable import CompanionDomain

@MainActor struct CompanionTimelineProjectionTests {
    @Test func assistantChunksNeverRegroupUnchangedHistory() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        let items = (0..<5_000).map { CompanionTimelineItem.message(.init(id: "helper-\($0)", role: .user, text: "[FROM:Builder] Update", source: "mcp")) }
        store.apply(.timeline(target, items: items, sequence: 1, reset: true))
        #expect(store.timelineRows(for: target).count == 1)
        let projection = store.timelineProjection(for: target)
        for step in 2...201 {
            store.apply(.upsert(target, .message(.init(id: "reply", role: .assistant, text: "Chunk \(step)", isStreaming: true)), sequence: step))
            let window = CompanionTimelineWindow(rows: store.timelineRows(for: target), limit: 150)
            #expect(window.entries.count == 2)
        }
        #expect(projection.regroupedItemCount == 5_000, "No source history is inspected or regrouped by 200 chunks")
        #expect(projection.assistantUpdateCount == 200)
    }
    @Test func structuralAndLocalChangesInvalidateWithoutStaleRows() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        let tool = CompanionTool(id: "tool", name: "Run", summary: "", state: .running)
        store.apply(.upsert(target, .tool(tool), sequence: 1))
        #expect(store.timelineRows(for: target)[0].id == "activity:tool:tool")
        var failed = tool; failed.state = .failed
        store.apply(.upsert(target, .tool(failed), sequence: 2))
        #expect(store.timelineRows(for: target) == [.item(.tool(failed))])
        store.apply(.upsert(target, .message(.init(id: "reply", role: .assistant, text: "", isStreaming: true)), sequence: 3))
        _ = store.timelineRows(for: target)
        store.apply(.streamFinished(target, messageID: "reply", sequence: 4))
        #expect(store.timelineRows(for: target) == CompanionTimelineFolding.rows(for: store.conversation(for: target).items))
        var conversation = store.conversation(for: target)
        conversation.items.append(.notice(id: "local", text: "Local edit"))
        #expect(store.timelineProjection(for: target).rows(for: conversation).last?.id == "notice:local")
    }
    @Test func revisionDoesNotChangeSemanticConversationEquality() {
        let a = CompanionConversation()
        var b = a; b.items = []
        #expect(a.itemsRevision != b.itemsRevision)
        #expect(a == b)
    }
}
