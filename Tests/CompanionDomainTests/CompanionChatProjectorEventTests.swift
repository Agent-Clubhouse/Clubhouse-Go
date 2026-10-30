import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Chat event kinds the projector folds into the timeline beyond plain messages: plans, subagents, questions
/// and the content blocks an approval request can carry.
@Suite @MainActor struct CompanionChatProjectorEventTests {
    private func event(_ type: String, seq: Int64, data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["sessionId": .string("s"), "seq": .integer(seq), "type": .string(type), "data": .object(data)])
    }
    private func message(_ projection: CompanionChatProjector, _ id: String) -> CompanionMessage? {
        projection.items.compactMap { item -> CompanionMessage? in if case .message(let m) = item, m.id == id { m } else { nil } }.first
    }

    @Test func planEntriesShowTheirProgressAndUpdateInPlace() {
        var projection = CompanionChatProjector()
        projection.apply(event("plan", seq: 1, data: ["entries": .array([
            .object(["status": .string("completed"), "content": .string("Read the code")]),
            .object(["status": .string("in_progress"), "content": .string("Write tests")]),
            .object(["status": .string("pending")]),
        ])]))
        #expect(message(projection, "plan-s")?.text == "✓ Read the code\n→ Write tests\n○ ")
        #expect(message(projection, "plan-s")?.role == .system)
        projection.apply(event("plan", seq: 2, data: ["entries": .array([.object(["status": .string("completed"), "content": .string("Done")])])]))
        #expect(message(projection, "plan-s")?.text == "✓ Done")
        #expect(projection.items.count == 1)
    }

    @Test func planDocumentsStreamAndNeedMarkdown() {
        var projection = CompanionChatProjector()
        projection.apply(event("plan_document", seq: 1, data: ["status": .string("streaming")]))
        #expect(projection.items.isEmpty, "Nothing to show without the document's text")
        projection.apply(event("plan_document", seq: 2, data: ["planId": .string("p1"), "markdown": .string("# Plan"), "status": .string("streaming")]))
        #expect(message(projection, "plan-document-p1")?.isStreaming == true)
        projection.apply(event("plan_document", seq: 3, data: ["planId": .string("p1"), "markdown": .string("# Plan\nDone"), "status": .string("complete")]))
        #expect(message(projection, "plan-document-p1")?.text == "# Plan\nDone")
        #expect(message(projection, "plan-document-p1")?.isStreaming == false)
        // A desktop that sends no plan id keys the document by session.
        projection.apply(event("plan_document", seq: 4, data: ["markdown": .string("Other")]))
        #expect(message(projection, "plan-document-s")?.role == .assistant)
    }

    @Test func subagentsAreNoticesKeyedByTheirID() {
        var projection = CompanionChatProjector()
        projection.apply(event("subagent", seq: 1, data: ["subagentId": .string("sub-1"), "name": .string("Explorer"), "status": .string("running")]))
        projection.apply(event("subagent", seq: 2, data: ["subagentId": .string("sub-1"), "name": .string("Explorer"), "status": .string("done")]))
        projection.apply(event("subagent", seq: 3, data: [:]))
        #expect(projection.items == [.notice(id: "subagent-sub-1", text: "Explorer · done"), .notice(id: "subagent-3", text: "Subagent · working")])
    }

    @Test func questionsKeepOnlyCompleteOptions() {
        var projection = CompanionChatProjector()
        projection.apply(event("question", seq: 1, data: ["requestId": .string("q1"), "questions": .array([
            .object(["id": .string("color"), "prompt": .string("Which colour?"), "multiSelect": .bool(true), "options": .array([
                .object(["id": .string("red"), "label": .string("Red"), "description": .string("Warm")]),
                .object(["id": .string("unlabelled")]),
            ])]),
            .object(["id": .string("no-prompt")]),
        ])]))
        guard case .question(let question)? = projection.items.first else { Issue.record("No question"); return }
        #expect(question.prompts.count == 1)
        #expect(question.prompts.first?.options == [.init(id: "red", label: "Red", detail: "Warm")])
        #expect(question.prompts.first?.allowsMultiple == true)
        #expect(projection.status == .waiting)
    }

    @Test(arguments: [
        (AnnexJSON.object(["type": .string("terminal"), "command": .string("make"), "output": .string("ok")]), "make\nok"),
        (.object(["type": .string("diff"), "unifiedDiff": .string("@@ -1 +1 @@")]), "@@ -1 +1 @@"),
        (.object(["type": .string("diff"), "path": .string("a.txt"), "newText": .string("new")]), "a.txt\nnew"),
        (.object(["type": .string("file"), "path": .string("b.txt")]), "File: b.txt"),
        (.object(["type": .string("file")]), "File: Attachment"),
        (.object(["type": .string("image")]), "Image attachment"),
        (.object(["type": .string("resource"), "uri": .string("file:///c")]), "file:///c"),
        (.object(["type": .string("resource")]), "Resource attachment"),
    ])
    func approvalContentBlocksReadAsText(block: AnnexJSON, text: String) {
        var projection = CompanionChatProjector()
        projection.apply(event("permission_request", seq: 1, data: ["requestId": .string("p"), "content": .array([block])]))
        guard case .approval(let approval)? = projection.items.first else { Issue.record("No approval"); return }
        #expect(approval.detail == text)
    }

    @Test func toolInputsReadAsAPersonWouldWriteThem() {
        #expect(CompanionChatProjector.inputSummary(nil) == nil)
        #expect(CompanionChatProjector.inputSummary(.object(["command": .string("ls -la")])) == "$ ls -la")
        #expect(CompanionChatProjector.inputSummary(.object(["file_path": .string("/repo/Sources/a.swift"), "new_string": .string("let x = 1")]))
                == "a.swift\nlet x = 1")
        #expect(CompanionChatProjector.inputSummary(.object(["path": .string("/repo/README.md")])) == "README.md")
        #expect(CompanionChatProjector.inputSummary(.object(["description": .string("Search the web")])) == "Search the web")
        #expect(CompanionChatProjector.inputSummary(.string("plain")) == "plain")
        // Anything else is shown as sorted, pretty JSON.
        #expect(CompanionChatProjector.inputSummary(.object(["b": .integer(1), "a": .bool(true)])) == "{\n  \"a\" : true,\n  \"b\" : 1\n}")
    }
}
