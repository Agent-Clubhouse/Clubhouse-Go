import Testing
@testable import CompanionDomain

@MainActor struct CompanionTimelineProjectionTests {
    @Test func removingAHostReleasesItsBookmarkViewportAndProjection() {
        let store = CompanionStore(service: CompanionPreviewService())
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        let target = CompanionPreviewService.target
        guard let other = hosts.first(where: { $0.id != target.hostID })?.allAgents.first?.id else {
            Issue.record("Fixture requires two hosts"); return
        }
        store.apply(.hosts(hosts))
        for target in [target, other] {
            store.apply(.timeline(target, items: [.notice(id: "seed", text: "Fixture")], sequence: 1, reset: true))
            _ = store.timelineRows(for: target)
        }
        weak var removedBookmark = store.readingBookmark(for: target)
        weak var removedViewport = removedBookmark?.viewport
        weak var removedProjection = store.timelineProjection(for: target)
        removedBookmark?.position.offset = 123
        let retained = store.readingBookmark(for: other)
        store.apply(.hosts(hosts))
        #expect(removedBookmark != nil && store.readingBookmark(for: other) === retained)
        store.apply(.hosts(hosts.filter { $0.id != target.hostID }))
        #expect(removedBookmark == nil && removedViewport == nil && removedProjection == nil)
        #expect(store.readingBookmark(for: other) === retained)
        store.apply(.hosts(hosts))
        #expect(store.readingBookmark(for: target).position.offset == 0)
    }
    @Test func assistantChunksNeverRegroupUnchangedHistory() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        let items = (0..<5_000).map { CompanionTimelineItem.message(.init(id: "helper-\($0)", role: .user, text: "[FROM:Builder] Update", source: "mcp")) }
        store.apply(.timeline(target, items: items, sequence: 1, reset: true))
        #expect(store.timelineRows(for: target).count == 5_000)
        let projection = store.timelineProjection(for: target)
        for step in 2...201 {
            store.apply(.upsert(target, .message(.init(id: "reply", role: .assistant, text: "Chunk \(step)", isStreaming: true)), sequence: step))
            let window = CompanionTimelineWindow(rows: store.timelineRows(for: target), limit: 150)
            #expect(window.entries.count == 150)
            #expect(window.entries.last?.id == "message:reply")
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
    @Test func toolChunksOnlyReplaceTheirRunAndAttentionChangesStillSplitIt() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        let history = (0..<5_000).map { CompanionTimelineItem.notice(id: "notice-\($0)", text: "Visible notice") }
        var tool = CompanionTool(id: "tool", name: "Run", summary: "", state: .running)
        store.apply(.timeline(target, items: history + [.tool(tool)], sequence: 1, reset: true))
        _ = store.timelineRows(for: target)
        let projection = store.timelineProjection(for: target)
        for step in 2...201 {
            tool.output = "Chunk \(step)"
            store.apply(.upsert(target, .tool(tool), sequence: step))
            #expect(store.timelineRows(for: target).last?.id == "activity:tool:tool")
        }
        #expect(projection.regroupedItemCount == 5_001)
        #expect(projection.toolUpdateCount == 200)
        tool.state = .failed
        store.apply(.upsert(target, .tool(tool), sequence: 202))
        #expect(store.timelineRows(for: target).last == .item(.tool(tool)))
        #expect(projection.regroupedItemCount == 10_002)
    }
    @Test func snapshotsReleaseStaleHiddenRowsBeforeTheNextRender() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        store.apply(.timeline(target, items: [.notice(id: "old", text: "Old payload")], sequence: 1, reset: true))
        _ = store.timelineRows(for: target)
        let projection = store.timelineProjection(for: target)
        #expect(projection.retainedRowCount == 1)
        store.apply(.timeline(target, items: [], sequence: 2, reset: true))
        #expect(projection.retainedRowCount == 0)
        #expect(store.timelineRows(for: target).isEmpty)
    }
    @Test func revisionDoesNotChangeSemanticConversationEquality() {
        let a = CompanionConversation()
        var b = a; b.items = []
        #expect(a.itemsRevision != b.itemsRevision)
        #expect(a == b)
    }
}
