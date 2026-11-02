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
    @Test func linkedPendingApprovalKeepsAnOtherwiseRunningToolVisibleAndOpen() {
        for resolution in [CompanionApproval.Resolution.pending, .submitting, .uncertain] {
            let approval = CompanionApproval(id: "permission", toolName: "Run", summary: "Allow?", resolution: resolution, toolCallID: "b")
            let rows = CompanionTimelineFolding.rows(for: [tool("a"), tool("b", state: .running), tool("c"), .approval(approval)])
            guard case .item(.tool(let waiting)) = rows[1] else { Issue.record("Waiting tool was collapsed"); continue }
            #expect(waiting.requiresAttention && waiting.outputOpenByDefault)
            #expect(rows.map(\.id) == ["activity:tool:a", "tool:b", "activity:tool:c", "approval:permission"])
        }
        let resolved = CompanionApproval(id: "permission", toolName: "Run", summary: "Allowed", resolution: .allowed, toolCallID: "b")
        #expect(CompanionTimelineFolding.rows(for: [tool("a"), tool("b"), tool("c"), .approval(resolved)]).count == 2)
        let unlinked = CompanionApproval(id: "permission", toolName: "Run", summary: "Allow?")
        #expect(CompanionTimelineFolding.rows(for: [tool("a"), tool("b"), .approval(unlinked)]).count == 2)
    }
    @Test func finishedEmptyAssistantIsCarriedOnlyBetweenCountableItems() {
        let empty = CompanionTimelineItem.message(.init(id: "empty", role: .assistant, text: ""))
        let rows = CompanionTimelineFolding.rows(for: [tool("a"), empty, tool("b")])
        guard case .activity(let parts) = rows[0] else { Issue.record("Missing activity"); return }
        #expect(parts.map(\.id) == ["tool:a", "message:empty", "tool:b"])
        #expect(CompanionActivityPart.summary(parts) == "2 tool calls")
        #expect(CompanionTimelineFolding.rows(for: [tool("a"), empty]).map(\.id) == ["activity:tool:a", "message:empty"])
        let live = CompanionTimelineItem.message(.init(id: "live", role: .assistant, text: "", isStreaming: true))
        #expect(CompanionTimelineFolding.rows(for: [tool("a"), live, tool("b")]).count == 3)
    }
    @Test func changingSubagentIdentityBreaksToolGroups() {
        let tools = [nil, "a", "a", "b", nil].enumerated().map { index, subagentID in
            CompanionTimelineItem.tool(.init(id: "\(index)", name: "Read", summary: "", state: .completed, subagentID: subagentID))
        }
        let rows = CompanionTimelineFolding.rows(for: tools)
        #expect(rows.map(\.id) == ["activity:tool:0", "activity:tool:1", "activity:tool:3", "activity:tool:4"])
    }
    @Test func failureOutputPolicyKeepsStatusVisibleAndBoundsLongOutput() {
        let short = CompanionTool(id: "short", name: "Run", summary: "", output: "one\ntwo", state: .failed)
        let long = CompanionTool(id: "long", name: "Run", summary: "", output: "1\n2\n3\n4\n5\n6\nFailure", state: .failed)
        #expect(short.requiresAttention && short.outputOpenByDefault)
        #expect(long.requiresAttention && !long.outputOpenByDefault)
        #expect(long.outputPreview == "Failure")
        #expect(CompanionTimelineFolding.rows(for: [.tool(long)]) == [.item(.tool(long))])
        #expect(CompanionTool(id: "permission", name: "Run", summary: "", output: long.output, state: .running, awaitsApproval: true).outputOpenByDefault)
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
