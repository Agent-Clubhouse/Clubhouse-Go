import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// The desktop's tool folding (`view-model.ts` `buildStreamBlocks`, `exploreLabel`) and tool verbs (`ToolBlocks.tsx`).
struct CompanionTimelineFoldingTests {
    private func tool(_ id: String, _ kind: CompanionTool.Kind?, _ state: CompanionTool.State = .completed,
                      location: String? = nil, hasChanges: Bool = false, awaitsApproval: Bool = false,
                      images: [CompanionContentReference] = []) -> CompanionTimelineItem {
        .tool(.init(id: id, name: "Tool \(id)", summary: "", state: state, images: images, kind: kind, location: location,
                    hasChanges: hasChanges, awaitsApproval: awaitsApproval))
    }
    private func folded(_ row: CompanionTimelineRow) -> [String]? {
        if case .tools(let tools) = row { tools.map(\.id) } else { nil }
    }

    @Test func foldsRunsOfReadOnlyTools() {
        let message = CompanionTimelineItem.message(.init(id: "m", role: .assistant, text: "hi"))
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .read), tool("2", .search), tool("3", .fetch), tool("4", .think), message])
        #expect(rows.count == 2)
        #expect(folded(rows[0]) == ["1", "2", "3", "4"])
        #expect(rows[0].id == "tools:1")
    }

    @Test func runningReadOnlyToolsFoldToo() {
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .read), tool("2", .read, .running)])
        #expect(folded(rows[0]) == ["1", "2"])
        guard case .tools(let tools) = rows[0] else { Issue.record("expected a fold"); return }
        #expect(CompanionTimelineFolding.exploreLabel(tools) == "Exploring 2 files")
    }

    @Test func toolsThatActOrFailStayUnfolded() {
        let rows = CompanionTimelineFolding.rows(for: [
            tool("run1", .execute), tool("run2", .execute),
            tool("edit", .edit), tool("read", .read, .failed), tool("ok", .read),
            tool("pending", .read, .running, awaitsApproval: true), tool("search", .search, hasChanges: true)
        ])
        #expect(rows.allSatisfy { folded($0) == nil }, "Only consecutive read-only, unfailed lookups fold")
        #expect(rows.count == 7)
    }

    @Test func aFailedToolBreaksTheRun() {
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .read), tool("2", .read), tool("x", .read, .failed), tool("3", .read), tool("4", .search)])
        #expect(rows.map(\.id) == ["tools:1", "tool:x", "tools:3"])
    }

    @Test func singleLookupsAndUnknownKindsDontFold() {
        // Older desktops send no kind: those tools are never folded.
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .read), tool("m", nil), tool("n", nil)])
        #expect(rows.map(\.id) == ["tool:1", "tool:m", "tool:n"])
    }

    /// Images are worth seeing, so a lookup that returned some keeps its own card and its preview link.
    @Test func lookupsWithImagesStayOutOfTheFold() {
        let image = CompanionContentReference.image(String(repeating: "a", count: 64) + ".png")
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .read), tool("2", .read, images: [image]), tool("3", .read)])
        #expect(rows.map(\.id) == ["tool:1", "tool:2", "tool:3"])
    }

    /// Folding never drops a call's content links: the fold offers each, so a preview opened from one isn't orphaned.
    @Test func foldKeepsEveryContentLink() {
        let a = CompanionTool(id: "a", name: "Read", summary: "", output: "`a.txt`", state: .completed, kind: .read)
        let b = CompanionTool(id: "b", name: "Read", summary: "", output: "`b.txt`", state: .running, kind: .read)
        let rows = CompanionTimelineFolding.rows(for: [.tool(a), .tool(b)])
        #expect(rows.count == 1)
        #expect(CompanionContentReference.references(in: rows[0]) == [.file("a.txt"), .file("b.txt")])
        #expect(CompanionContentReference.hintRowID(in: rows, richContentAvailable: false) == "tools:a")
    }

    @Test func exploreLabelCountsLikeTheDesktop() {
        func label(_ kinds: [CompanionTool.Kind]) -> String {
            CompanionTimelineFolding.exploreLabel(kinds.enumerated().map { .init(id: "\($0.offset)", name: "", summary: "", state: .completed, kind: $0.element) })
        }
        #expect(label([.read, .read, .read, .search, .search]) == "Explored 3 files, 2 searches")
        #expect(label([.read, .search]) == "Explored 1 file, 1 search")
        #expect(label([.fetch, .think]) == "Explored 2 lookups")
        #expect(label([.read, .fetch]) == "Explored 1 file, 1 lookup")
    }

    @Test func toolVerbsMatchTheDesktop() {
        #expect(CompanionTool.Kind.read.verb == "Read")
        #expect(CompanionTool.Kind.edit.verb == "Edit")
        #expect(CompanionTool.Kind.execute.verb == "Run")
        #expect(CompanionTool.Kind.search.verb == "Search")
        #expect(CompanionTool.Kind.switchMode.verb == "Mode")
        let read = CompanionTool(id: "t", name: "Read file", summary: "", state: .completed, kind: .read, location: "Sources/App.swift")
        #expect(read.verb == "Read" && read.target == "Sources/App.swift")
        let legacy = CompanionTool(id: "t", name: "Bash", summary: "", state: .completed)
        #expect(legacy.verb == nil && legacy.target == "Bash")
    }
}

@Suite struct CompanionChatParityProjectorTests {
    private func event(_ type: String, _ seq: Int64, ts: Int64 = 1_700_000_000_000, _ data: [String: AnnexJSON] = [:]) -> AnnexJSON {
        .object(["sessionId": .string("s1"), "seq": .integer(seq), "ts": .integer(ts), "type": .string(type), "data": .object(data)])
    }
    private func tool(_ projector: CompanionChatProjector, _ id: String) -> CompanionTool? {
        projector.items.lazy.compactMap { item -> CompanionTool? in if case .tool(let tool) = item, tool.id == id { tool } else { nil } }.first
    }

    @Test func toolCallsCarryKindLocationAndChanges() {
        var projector = CompanionChatProjector()
        projector.apply(event("tool_call", 1, ["toolCallId": .string("r"), "kind": .string("read"), "title": .string("Read file"), "status": .string("in_progress"),
                                              "locations": .array([.object(["path": .string("Sources/App.swift")])])]))
        projector.apply(event("tool_call", 2, ["toolCallId": .string("e"), "kind": .string("execute"), "title": .string("swift test"), "status": .string("pending")]))
        projector.apply(event("tool_call", 3, ["toolCallId": .string("x"), "kind": .string("brand_new_kind"), "title": .string("Something"), "status": .string("completed")]))
        var read = tool(projector, "r")
        #expect(read?.kind == .read && read?.location == "Sources/App.swift" && read?.state == .running && read?.isExplore == true)
        #expect(tool(projector, "e")?.awaitsApproval == true)
        #expect(tool(projector, "x")?.kind == .other, "Unknown kinds read as Tool")

        // An update without kind or locations keeps them; terminal content marks the call as one that acted.
        projector.apply(event("tool_call_update", 4, ["toolCallId": .string("r"), "status": .string("completed")]))
        read = tool(projector, "r")
        #expect(read?.kind == .read && read?.location == "Sources/App.swift" && read?.state == .completed)
        projector.apply(event("tool_call_update", 5, ["toolCallId": .string("e"), "status": .string("in_progress"),
                                                     "content": .array([.object(["type": .string("terminal"), "output": .string("ok")])])]))
        let run = tool(projector, "e")
        #expect(run?.awaitsApproval == false && run?.hasChanges == true)
        projector.apply(event("tool_call_update", 6, ["toolCallId": .string("e"), "status": .string("completed")]))
        #expect(tool(projector, "e")?.hasChanges == true, "An update without content keeps the earlier output kind")
    }

    @Test func turnStartTracksTheRunningTurn() {
        var projector = CompanionChatProjector()
        projector.apply(event("turn_started", 1, ts: 1_700_000_000_000))
        #expect(projector.turnStartedAt == Date(timeIntervalSince1970: 1_700_000_000))
        projector.apply(event("session_state", 2, ["state": .string("waiting_permission")]))
        #expect(projector.turnStartedAt != nil, "Waiting on an approval is still the same turn")
        projector.apply(event("turn_ended", 3, ["stopReason": .string("end_turn")]))
        #expect(projector.turnStartedAt == nil)
        projector.apply(event("turn_started", 4))
        projector.apply(event("session_ended", 5, ["reason": .string("idle_timeout")]))
        #expect(projector.turnStartedAt == nil)
    }

    @Test func usageEventsCarryContextFill() {
        var projector = CompanionChatProjector()
        projector.apply(event("usage", 1, ["scope": .string("turn"), "tokens": .object(["input": .integer(10)])]))
        #expect(projector.contextUsage == nil, "Token counts alone say nothing about context")
        projector.apply(event("usage", 2, ["scope": .string("session"), "context": .object(["used": .integer(84_000), "size": .integer(200_000)])]))
        #expect(projector.contextUsage?.percent == 42)
        projector.apply(event("usage", 3, ["scope": .string("session"), "limits": .array([])]))
        #expect(projector.contextUsage?.percent == 42, "A usage event without context keeps the last fill")
        projector.apply(event("usage", 4, ["scope": .string("session"), "context": .object(["used": .integer(10), "size": .integer(0)])]))
        #expect(projector.contextUsage?.percent == 42, "A zero-size window is ignored")
        #expect(CompanionContextUsage(used: 300, size: 200).percent == 100)
    }

    @Test func approvalUsesTheRequestTitle() {
        var projector = CompanionChatProjector()
        projector.apply(event("permission_request", 1, ["requestId": .string("p"), "title": .string("Run swift test"), "toolName": .string("Bash"),
                                                       "options": .array([.object(["optionId": .string("s"), "kind": .string("allow_session"), "label": .string("Allow for session")]),
                                                                          .object(["optionId": .string("r"), "kind": .string("reject_always"), "label": .string("Never"), "scope": .string("rm:*")])])]))
        guard case .approval(let approval) = projector.items.first else { Issue.record("expected approval"); return }
        #expect(approval.title == "Run swift test" && approval.toolName == "Bash")
        #expect(approval.options.map(\.kind) == [.allowSession, .rejectAlways])
        #expect(approval.options[1].scope == "rm:*")
        #expect(approval.options.allSatisfy { !$0.isOneOff && $0.isPersistent })
        #expect(approval.options.allSatisfy { !$0.isAnswerable(persistentApprovals: false) && $0.isAnswerable(persistentApprovals: true) })
    }
}

struct CompanionChatActivityTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func approval(_ id: String, title: String?, resolution: CompanionApproval.Resolution = .pending, deadline: Date? = nil) -> CompanionTimelineItem {
        .approval(.init(id: id, toolName: "Bash", summary: "", title: title, deadline: deadline, resolution: resolution))
    }

    @Test func workingShowsElapsedAndCurrentTool() {
        let items: [CompanionTimelineItem] = [
            .tool(.init(id: "old", name: "Old tool", summary: "", state: .running)),
            .message(.init(id: "u", role: .user, text: "Go")),
            .tool(.init(id: "a", name: "Read file", summary: "", state: .completed)),
            .tool(.init(id: "b", name: "swift test", summary: "", state: .running))
        ]
        #expect(CompanionChatActivity.line(status: .working, turnStartedAt: start, items: items, now: start.addingTimeInterval(65)) == "1:05 · swift test")
        #expect(CompanionChatActivity.line(status: .working, turnStartedAt: nil, items: items) == "swift test")
        // Your latest message ends the search: an older running tool isn't this turn's.
        #expect(CompanionChatActivity.line(status: .working, turnStartedAt: start, items: Array(items.prefix(2)), now: start.addingTimeInterval(5)) == "0:05")
        #expect(CompanionChatActivity.line(status: .working, turnStartedAt: nil, items: []) == nil)
    }

    @Test func waitingStatesSayWhatTheyWaitOn() {
        let items = [approval("done", title: "Old", resolution: .allowed), approval("p", title: "Edit README.md")]
        #expect(CompanionChatActivity.line(status: .approval, turnStartedAt: start, items: items) == "Edit README.md")
        #expect(CompanionChatActivity.line(status: .approval, turnStartedAt: nil, items: []) == "Waiting for approval")
        #expect(CompanionChatActivity.line(status: .waiting, turnStartedAt: nil, items: []) == "Has a question")
        #expect(CompanionChatActivity.line(status: .idle, turnStartedAt: nil, items: items) == nil)
    }

    @Test func queuePositionCountsOnlyWaitingApprovals() {
        let now = Date()
        let items = [approval("done", title: nil, resolution: .denied), approval("expired", title: nil, deadline: now.addingTimeInterval(-1)),
                     approval("a", title: nil), approval("b", title: nil)]
        guard case .approval(let first) = items[2], case .approval(let second) = items[3], case .approval(let done) = items[0] else { return }
        #expect(CompanionChatActivity.queuePosition(of: first, in: items, at: now) == "1 of 2")
        #expect(CompanionChatActivity.queuePosition(of: second, in: items, at: now) == "2 of 2")
        #expect(CompanionChatActivity.queuePosition(of: done, in: items, at: now) == nil)
        #expect(CompanionChatActivity.queuePosition(of: first, in: Array(items.prefix(3)), at: now) == nil, "One waiting approval has no count")
    }

    @Test func elapsedFormatsLikeTheDesktop() {
        #expect(CompanionChatActivity.elapsed(0) == "0:00")
        #expect(CompanionChatActivity.elapsed(59.9) == "0:59")
        #expect(CompanionChatActivity.elapsed(3_725) == "62:05")
        #expect(CompanionChatActivity.elapsed(-5) == "0:00")
    }
}
