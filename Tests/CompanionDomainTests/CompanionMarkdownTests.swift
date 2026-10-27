import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionMarkdownTests {
    private func blocks(_ text: String, streaming: Bool = false) -> [CompanionMarkdownBlock] {
        CompanionMarkdown.parse(text, streaming: streaming).blocks
    }
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    @Test func headingsKeepTheirLevelAndDropTheHashes() {
        let result = blocks("# One\n## Two\n###### Six")
        #expect(result.count == 3)
        guard case .heading(1, let one) = result[0], case .heading(2, let two) = result[1], case .heading(6, let six) = result[2] else {
            Issue.record("Expected three headings, got \(result)"); return
        }
        #expect(plain(one) == "One")
        #expect(plain(two) == "Two")
        #expect(plain(six) == "Six")
    }

    @Test func paragraphKeepsInlineStylesAndLineBreaks() {
        guard case .paragraph(let text) = blocks("Some **bold**, *italic*, `code` and [a link](https://example.com)\nnext line").first else {
            Issue.record("Expected a paragraph"); return
        }
        #expect(plain(text) == "Some bold, italic, code and a link\nnext line")
        let runs = text.runs.map { (plain(AttributedString(text[$0.range])), $0.inlinePresentationIntent, $0.link) }
        #expect(runs.contains { $0.0 == "bold" && $0.1 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == "italic" && $0.1 == .emphasized })
        #expect(runs.contains { $0.0 == "code" && $0.1 == .code })
        #expect(runs.contains { $0.0 == "a link" && $0.2 == URL(string: "https://example.com") })
    }

    @Test func bulletNumberedAndNestedLists() {
        let result = blocks("- one\n- two\n  - nested\n\n3. third\n4. fourth")
        guard case .list(let bullets) = result.first, case .list(let numbers) = result.last else {
            Issue.record("Expected two lists, got \(result)"); return
        }
        #expect(bullets.start == nil)
        #expect(bullets.items.count == 2)
        guard case .list(let nested) = bullets.items[1].blocks.last else { Issue.record("Expected a nested list"); return }
        guard case .paragraph(let inner) = nested.items.first?.blocks.first else { Issue.record("Expected nested text"); return }
        #expect(plain(inner) == "nested")
        #expect(numbers.start == 3)
        #expect(numbers.items.count == 2)
    }

    @Test func taskListsCarryTheirCheckboxes() {
        guard case .list(let list) = blocks("- [x] done\n- [ ] todo\n- plain").first else { Issue.record("Expected a list"); return }
        #expect(list.items.map(\.checkbox) == [.checked, .unchecked, nil])
        guard case .paragraph(let text) = list.items[0].blocks.first else { Issue.record("Expected item text"); return }
        #expect(plain(text) == "done")
    }

    @Test func tablesRespectColumnAlignmentAndPadShortRows() {
        let source = """
        | Name | Count | Status |
        |:-----|:-----:|-------:|
        | **api** | 3 | ok |
        | web | 12 |
        """
        guard case .table(let table) = blocks(source).first else { Issue.record("Expected a table"); return }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header.map(plain) == ["Name", "Count", "Status"])
        #expect(table.rows.map { $0.map(plain) } == [["api", "3", "ok"], ["web", "12", ""]])
        #expect(table.rows[0][0].runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test func quotesAndRules() {
        let result = blocks("> quoted **text**\n> more\n\n---\n\nafter")
        guard case .quote(let quoted) = result[0], case .paragraph(let inner) = quoted.first else { Issue.record("Expected a quote"); return }
        #expect(plain(inner) == "quoted text\nmore")
        #expect(result[1] == .rule)
        guard case .paragraph(let after) = result[2] else { Issue.record("Expected a paragraph"); return }
        #expect(plain(after) == "after")
    }

    @Test func mixedContentWithFencesKeepsMarkdownInsideCodeLiteral() {
        let source = """
        ## Plan

        ```swift
        let x = 1
        // ## not a heading
        | not | a table |
        ```

        - item

              indented code
        """
        let result = blocks(source)
        #expect(result.count == 3)
        guard case .heading(2, _) = result[0] else { Issue.record("Expected a heading"); return }
        #expect(result[1] == .code(language: "swift", code: "let x = 1\n// ## not a heading\n| not | a table |"))
        guard case .list(let list) = result[2] else { Issue.record("Expected a list"); return }
        #expect(list.items[0].blocks.last == .code(language: nil, code: "indented code"))
    }

    @Test func htmlBlocksStayAsSource() {
        #expect(blocks("<details>\n<summary>More</summary>\n</details>") == [.plain("<details>\n<summary>More</summary>\n</details>")])
    }

    // MARK: Streaming

    @Test func halfReceivedTableStaysPlainWhileStreaming() {
        let partial = "Here are the results:\n\n| Name | Count |\n|---|---|\n| api | 3"
        let result = blocks(partial, streaming: true)
        #expect(result.count == 2)
        guard case .paragraph(let intro) = result[0] else { Issue.record("Expected the settled intro"); return }
        #expect(plain(intro) == "Here are the results:")
        #expect(result[1] == .plain("| Name | Count |\n|---|---|\n| api | 3"))
        // Once the turn ends, the same text is a table.
        guard case .table = blocks(partial).last else { Issue.record("Expected a table once complete"); return }
    }

    @Test func tableSettlesWhenFollowedByABlankLine() {
        let result = blocks("| a | b |\n|---|---|\n| 1 | 2 |\n\nNext", streaming: true)
        guard case .table = result.first else { Issue.record("Expected a settled table, got \(result)"); return }
    }

    @Test func possibleUnderlineStaysPlainWhileStreaming() {
        // "Title\n-" is a setext heading to cmark, but the "-" may be the start of a list item.
        let result = blocks("Intro\n\nTitle\n-", streaming: true)
        #expect(result.last == .plain("Title\n-"))
        guard case .heading = blocks("Intro\n\nTitle\n-").last else { Issue.record("Complete text is a setext heading"); return }
    }

    @Test func unclosedFenceStreamsAsCode() {
        let result = blocks("Look:\n\n```swift\nlet a = 1\n| x |", streaming: true)
        #expect(result.last == .code(language: "swift", code: "let a = 1\n| x |"))
    }

    @Test func ordinaryStreamingParagraphRendersNormally() {
        let result = blocks("## Heading\n\nSome **bold** text", streaming: true)
        guard case .heading = result.first, case .paragraph(let text) = result.last else { Issue.record("Expected heading and paragraph"); return }
        #expect(plain(text) == "Some bold text")
    }

    @Test func splitIgnoresBlankLinesInsideFences() {
        let text = "```\na\n\n| b |\n```\n| c |"
        let split = CompanionMarkdown.splitUnsettledTail(text)
        #expect(split.settled == "")
        #expect(split.tail == text)
    }

    @Test func memoisedDocumentMatchesAFreshParse() {
        let text = "# Title\n\n| a |\n|---|\n| b |"
        #expect(CompanionMarkdown.document(text) == CompanionMarkdown.parse(text))
        #expect(CompanionMarkdown.document(text) == CompanionMarkdown.document(text))
        #expect(CompanionMarkdown.document(text, streaming: true) == CompanionMarkdown.parse(text, streaming: true))
    }

    // MARK: User message source

    @Test func userMessageSourceLabelsMatchTheDesktop() {
        func label(_ source: String?, steered: Bool = false) -> String? {
            CompanionMessage(id: "m", role: .user, text: "hi", source: source, isSteered: steered).sourceLabel
        }
        #expect(label(nil) == nil)
        #expect(label("user") == nil)
        #expect(label("mission") == "Mission")
        #expect(label("annex") == "From Annex")
        #expect(label("mcp") == "From another agent")
        #expect(label("user", steered: true) == "Steered into the running turn")
        #expect(label("annex", steered: true) == "From Annex · Steered into the running turn")
    }

    @Test @MainActor func projectorReadsSourceAndSteerDelivery() {
        var projection = CompanionChatProjector()
        projection.apply(.object(["v": .integer(2), "agentId": .string("agent"), "sessionId": .string("s"), "seq": .integer(1), "ts": .integer(1_700_000_000_000),
                                  "type": .string("user_message"),
                                  "data": .object(["messageId": .string("m"), "source": .string("mission"), "delivery": .string("steer"),
                                                   "content": .array([.object(["type": .string("text"), "text": .string("Go")])])])]))
        guard case .message(let message) = projection.items.first else { Issue.record("Expected a message"); return }
        #expect(message.source == "mission")
        #expect(message.isSteered)
        #expect(message.sourceLabel == "Mission · Steered into the running turn")
    }
}
