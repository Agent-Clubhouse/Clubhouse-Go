import Foundation
import Testing
@testable import CompanionDomain

@MainActor struct CompanionReadableChatTests {
    private func routed(_ id: String, _ parts: [CompanionRoutedMessagePart], queue: CompanionMessage.QueueState? = nil,
                        delivery: CompanionMessage.Delivery = .confirmed, images: [CompanionMessageImage] = []) -> CompanionTimelineItem {
        .message(.init(id: id, role: .user, text: "raw", delivery: delivery, queueState: queue, source: "mcp", routed: parts, images: images))
    }
    private let short = CompanionRoutedMessagePart(sender: .init(name: "Builder"), text: "Done")
    private func tool(_ id: String, state: CompanionTool.State = .completed, approval: Bool = false) -> CompanionTimelineItem {
        .tool(.init(id: id, name: "Run", summary: "command", state: state, kind: .execute, awaitsApproval: approval))
    }
    @Test func adjacentToolsAndShortRoutedPartsFormOneOrderedRow() {
        let rows = CompanionTimelineFolding.rows(for: [tool("a"), routed("b", [short, short]), tool("c", state: .running)])
        guard case .activity(let parts) = rows.first else { Issue.record("Missing activity"); return }
        #expect(rows.count == 1)
        #expect(parts.map(\.id) == ["tool:a", "routed:b:0", "routed:b:1", "tool:c"])
        #expect(rows[0].id == "activity:tool:a")
        #expect(CompanionActivityPart.summary(parts) == "2 tool calls · 2 messages · Running…")
    }
    @Test func singleRoutedPartCollapsesWithoutPreparingAnyMarkdown() {
        let rows = CompanionTimelineFolding.rows(for: [routed("b", [.init(sender: .init(name: "Builder"), text: String(repeating: "**long**\n\n", count: 1_000))])])
        let entries = CompanionTimelineEntry.entries(for: rows)
        #expect(entries.count == 1)
        guard case .row(.activity) = entries.first else { Issue.record("Collapsed Markdown must stay an opaque row, with zero slices"); return }
        #expect(CompanionContentReference.references(in: rows[0]).isEmpty)
    }
    @Test func noticeAndHelperQuestionSplitPartsWithoutLosingOrder() {
        let notice = CompanionRoutedMessagePart(fromClubhouse: true, text: "Helper started")
        let question = CompanionRoutedMessagePart(sender: .init(name: "Builder"), text: "[QUESTION FROM HELPER:Builder] Which branch?")
        let rows = CompanionTimelineFolding.rows(for: [routed("b", [short, notice, short, question, short])])
        #expect(rows.map(\.id) == ["activity:routed:b:0", "routed:b:1", "activity:routed:b:2", "routed:b:3", "activity:routed:b:4"])
        #expect(!CompanionTimelineFolding.canCollapse(notice))
        #expect(!CompanionTimelineFolding.canCollapse(question))
    }
    @Test func actionableDeliveriesAndQueuesStayVisible() {
        for queue in [CompanionMessage.QueueState.queued, .dispatching, .failed, .submitted] {
            let rows = CompanionTimelineFolding.rows(for: [tool("a"), routed("b", [short], queue: queue), tool("c")])
            #expect(rows.count == 3)
            #expect(rows[1].id == "message:b")
        }
        for delivery in [CompanionMessage.Delivery.failed("Error"), .uncertain("Unknown"), .sending, .accepted, .uploading(completed: 0, total: 1)] {
            #expect(CompanionTimelineFolding.rows(for: [routed("b", [short], delivery: delivery)])[0].id == "message:b")
        }
    }
    @Test func failureAndPermissionSplitThenRejoinAfterResolution() {
        for item in [tool("b", state: .failed), tool("b", state: .running, approval: true)] {
            let rows = CompanionTimelineFolding.rows(for: [tool("a"), item, tool("c")])
            #expect(rows.count == 3)
            #expect(rows[1].id == "tool:b")
        }
        #expect(CompanionTimelineFolding.rows(for: [tool("a"), tool("b"), tool("c")]).count == 1)
    }
    @Test func attachmentSummaryCountsOncePerDelivery() {
        let rows = CompanionTimelineFolding.rows(for: [routed("b", [short, short], images: [.init(id: "image")])])
        guard case .activity(let parts) = rows[0] else { Issue.record("Missing run"); return }
        #expect(CompanionActivityPart.summary(parts) == "2 messages · 1 attachment")
    }
    @Test func expansionAndBookmarkSurviveSnapshotRefresh() {
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        store.transcriptExpansion(for: target).state(key: "activity:tool:a").open = true
        store.readingBookmark(for: target).position = .init(followsLatest: false, entryID: "message:a", distanceFromEntry: 10, offset: 400, shownEntries: 300)
        store.apply(.timeline(target, items: [tool("a")], sequence: 2, reset: true, sessionID: "session"))
        #expect(store.transcriptExpansion(for: target).state(key: "activity:tool:a").open == true)
        #expect(store.readingBookmark(for: target).position.offset == 400)
    }
}
