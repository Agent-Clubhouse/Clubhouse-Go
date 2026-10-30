import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionMessageSlicesTests {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }
    private func paragraph(_ index: Int, words: Int = 60) -> String {
        "Paragraph \(index) " + (1...words).map { "word\($0)" }.joined(separator: " ") + "."
    }
    /// The text of every block, flattened, so a split can be checked for nothing lost or repeated.
    private func text(_ blocks: [CompanionMarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let text), .heading(_, let text): plain(text)
            case .plain(let text): text
            case .list(let list): list.items.map { text($0.blocks) }.joined(separator: " ")
            case .quote(let blocks): text(blocks)
            case .code(_, let code): code
            case .table(let table): table.rows.flatMap { $0.map(plain) }.joined(separator: " ")
            case .rule: "---"
            }
        }.joined(separator: " ")
    }
    private func words(_ string: String) -> [Substring] { string.split(whereSeparator: \.isWhitespace) }

    @Test func aShortReplyIsOneSliceWithTheMessageID() {
        let slices = CompanionMessageSlices.slices(messageID: "m1", text: "Done. **All** tests pass.", streaming: false)
        #expect(slices.count == 1)
        #expect(slices[0].id == "m1")
        #expect(slices[0].isLast)
        #expect(!slices[0].continuesBlock)
        #expect(slices[0].blocks.count == 1)
    }

    @Test func anEmptyReplyStillHasOneSlice() {
        let slices = CompanionMessageSlices.slices(messageID: "empty", text: "", streaming: true)
        #expect(slices.count == 1)
        #expect(slices[0].blocks.isEmpty)
        #expect(slices[0].isLast)
    }

    @Test func aLongReplySplitsAtParagraphsWithinTheBudgetAndLosesNothing() {
        let source = (1...40).map { paragraph($0) }.joined(separator: "\n\n")
        let slices = CompanionMessageSlices.slices(messageID: "long", text: source, streaming: false)
        #expect(slices.count > 5)
        #expect(slices.map(\.id) == ["long"] + (1..<slices.count).map { "long#\($0)" })
        #expect(slices.map(\.index) == Array(0..<slices.count))
        #expect(slices.filter(\.isLast).map(\.index) == [slices.count - 1])
        #expect(slices.allSatisfy { !$0.continuesBlock })
        for slice in slices {
            #expect(slice.blocks.reduce(0) { $0 + CompanionMessageSlices.weight($1) } <= CompanionMessageSlices.defaultBudget)
        }
        #expect(words(text(slices.flatMap(\.blocks))) == words(text(CompanionMarkdown.parse(source).blocks)))
    }

    @Test func oneHugeParagraphIsCutAtSentencesAndKeepsItsFormatting() {
        let sentences = (1...300).map { "Sentence \($0) has **bold** words in it." }
        let source = sentences.joined(separator: " ")
        let slices = CompanionMessageSlices.slices(messageID: "huge", text: source, streaming: false)
        #expect(slices.count > 5)
        #expect(!slices[0].continuesBlock)
        #expect(slices.dropFirst().allSatisfy { $0.continuesBlock })
        let pieces = slices.flatMap(\.blocks).map { block -> AttributedString in
            guard case .paragraph(let text) = block else { Issue.record("Expected paragraphs, got \(block)"); return "" }
            return text
        }
        for piece in pieces {
            #expect(piece.characters.count <= CompanionMessageSlices.defaultBudget)
            #expect(plain(piece).hasSuffix("."), "Cut at the end of a sentence: \(plain(piece).suffix(30))")
            #expect(plain(piece).first?.isWhitespace == false)
            #expect(piece.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        }
        #expect(pieces.map(plain).joined(separator: " ") == sentences.map { $0.replacingOccurrences(of: "**", with: "") }.joined(separator: " "))
    }

    @Test func textWithNoBreaksIsStillCutToTheBudget() {
        let source = String(repeating: "x", count: 5_000)
        let pieces = CompanionMessageSlices.cut(AttributedString(source), budget: 1_000)
        #expect(pieces.map { $0.characters.count } == [1_000, 1_000, 1_000, 1_000, 1_000])
    }

    @Test func linesArePreferredOverSentences() {
        let source = (1...30).map { "Line \($0). More text here" }.joined(separator: "\n")
        let pieces = CompanionMessageSlices.cut(AttributedString(source), budget: 200)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { plain($0).hasSuffix("More text here") })
        #expect(pieces.map(plain).joined(separator: "\n") == source)
    }

    @Test func aLongNumberedListKeepsCountingAcrossSlices() {
        let source = (1...80).map { "\($0). " + (1...20).map { word in "item\(word)" }.joined(separator: " ") }.joined(separator: "\n")
        let slices = CompanionMessageSlices.slices(messageID: "list", text: source, streaming: false)
        #expect(slices.count > 1)
        var expectedStart = 1
        for (index, slice) in slices.enumerated() {
            #expect(slice.continuesBlock == (index > 0))
            guard slice.blocks.count == 1, case .list(let list) = slice.blocks[0] else { Issue.record("Expected one list per slice"); return }
            #expect(list.start == expectedStart)
            expectedStart += list.items.count
        }
        #expect(expectedStart == 81)
    }

    @Test func aLongBulletListStaysBulleted() {
        let source = (1...80).map { _ in "- " + (1...20).map { word in "item\(word)" }.joined(separator: " ") }.joined(separator: "\n")
        let pieces = CompanionMessageSlices.cut(CompanionMarkdown.parse(source).blocks[0], budget: 1_200)
        #expect(pieces.count > 1)
        for piece in pieces {
            guard case .list(let list) = piece else { Issue.record("Expected lists"); return }
            #expect(list.start == nil)
        }
    }

    @Test func aLongQuoteSplitsIntoQuotes() {
        let source = (1...20).map { "> " + paragraph($0) }.joined(separator: "\n>\n")
        let pieces = CompanionMessageSlices.cut(CompanionMarkdown.parse(source).blocks[0], budget: 1_200)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { if case .quote = $0 { true } else { false } })
    }

    @Test func codeAndTablesAreNeverCutAndHaveASliceOfTheirOwnWhenLarge() {
        let code = "```swift\n" + (1...200).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n```"
        let source = [paragraph(1), code, paragraph(2)].joined(separator: "\n\n")
        let slices = CompanionMessageSlices.slices(messageID: "code", text: source, streaming: false)
        let codeSlices = slices.filter { $0.blocks.contains { if case .code = $0 { true } else { false } } }
        #expect(codeSlices.count == 1)
        guard case .code(_, let body) = codeSlices[0].blocks.first(where: { if case .code = $0 { true } else { false } }) else { return }
        #expect(body.split(separator: "\n").count == 200)
        // A long block weighs no more than its capped inline preview.
        #expect(CompanionMessageSlices.weight(codeSlices[0].blocks.first { if case .code = $0 { true } else { false } }!) < CompanionMessageSlices.defaultBudget)
    }

    @Test func earlierSlicesDoNotChangeAsAReplyStreams() {
        let paragraphs = (1...30).map { paragraph($0) }
        let early = CompanionMessageSlices.slices(messageID: "s", text: paragraphs.prefix(20).joined(separator: "\n\n"), streaming: true)
        let later = CompanionMessageSlices.slices(messageID: "s", text: paragraphs.joined(separator: "\n\n") + "\n\nStill wri", streaming: true)
        #expect(later.count > early.count)
        // All but the last early slice, which may have filled up, are unchanged.
        for (before, after) in zip(early.dropLast(), later) {
            #expect(before.id == after.id)
            #expect(before.blocks == after.blocks)
        }
    }

    @Test func slicesAreCachedPerMessageVersion() {
        let source = (1...20).map { paragraph($0) }.joined(separator: "\n\n")
        let first = CompanionMessageSlices.slices(messageID: "cached", text: source, streaming: false)
        #expect(CompanionMessageSlices.slices(messageID: "cached", text: source, streaming: false) == first)
        let other = CompanionMessageSlices.slices(messageID: "other", text: source, streaming: false)
        #expect(other.first?.id == "other")
    }
}
