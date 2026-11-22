import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionTextLinkTests {
    private func paragraph(_ source: String) throws -> AttributedString {
        let blocks = CompanionMarkdown.parse(source).blocks
        guard case .paragraph(let value) = blocks.first else { throw MissingParagraph() }
        return value
    }
    private struct MissingParagraph: Error {}
    private func urls(_ text: AttributedString) -> [String] {
        text.runs.compactMap { $0.link?.absoluteString }
    }

    @Test func bareDestinationKeepsDoubleHyphensQueryAndFragmentBesideSmartProse() throws {
        let url = "https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/123?check=a--b&mode=one#job-45"
        let text = try paragraph("\"Ready\" -- open \(url). Then done.")
        #expect(urls(text) == [url])
        #expect(String(text.characters) == "“Ready” – open \(url). Then done.")
        let entity = "https://example.com/?value=&copy;&other=2"
        #expect(urls(try paragraph(entity)) == [entity])
    }

    @Test func sentencePunctuationAndBalancedURLParentheses() throws {
        let url = "https://example.com/path_(detail)?a=1&b=2#fragment"
        let source = "Read (\(url)), then https://example.com/second."
        #expect(urls(try paragraph(source)) == [url, "https://example.com/second"])
        let literal = CompanionMarkdown.literal(source)
        #expect(String(literal.characters) == source)
        #expect(urls(literal) == [url, "https://example.com/second"])
    }

    @Test func existingLabeledDestinationWinsOverURLLookingLabel() throws {
        let source = "[https://visible.invalid](https://actual.invalid/a--b?x=1#part)"
        #expect(urls(try paragraph(source)) == ["https://actual.invalid/a--b?x=1#part"])
        let literal = CompanionMarkdown.literal(source)
        #expect(String(literal.characters) == source)
        #expect(urls(literal) == ["https://actual.invalid/a--b?x=1#part"])
    }

    @Test func literalMessagesKeepUTF8CRLFMarkdownAndCode() {
        let url = "https://example.com/a--b?q=%F0%9F%9A%80#section"
        let source = "👩🏽‍💻 Café **as typed**\r\n\(url).\r\n`https://inline.invalid`\r\n\r\n```text\r\nhttps://fenced.invalid\r\n```\r\n\r\n    https://indented.invalid\r\n"
        let value = CompanionMarkdown.literal(source)
        #expect(Array(String(value.characters).utf8) == Array(source.utf8))
        #expect(urls(value) == [url])
        #expect(CompanionMarkdown.literal(source) == value)
    }

    @Test func codeAndHTMLAreNeverAutoLinked() throws {
        let source = "`https://inline.invalid` and https://prose.invalid\n\n```\nhttps://fenced.invalid\n```\n\n<div>https://html.invalid</div>"
        #expect(urls(try paragraph(source)) == ["https://prose.invalid"])
        #expect(try paragraph(source).runs.contains { $0.inlinePresentationIntent == .code && $0.link == nil })
        let blocks = CompanionMarkdown.parse(source).blocks
        #expect(blocks[1] == .code(language: nil, code: "https://fenced.invalid"))
        #expect(blocks[2] == .plain("<div>https://html.invalid</div>"))
        #expect(urls(CompanionMarkdown.literal(source)) == ["https://prose.invalid"])
    }

    @Test func formattedBareURLsKeepTheirWholeDestination() throws {
        #expect(urls(try paragraph("**https://example.com/a--b?q=1#f**")) == ["https://example.com/a--b?q=1#f"])
        #expect(urls(try paragraph("https://example.com/a*b*c?x=1#f")) == ["https://example.com/a*b*c?x=1#f"])
    }

    @Test func compactTableDelimitersAreNotPartOfBareDestinations() {
        let source = "|Run|URL|\n|---|---|\n|one|https://example.com/job--42?x=1#step|"
        guard case .table(let table) = CompanionMarkdown.parse(source).blocks.first else { Issue.record("Missing table"); return }
        #expect(table.rows.first?.count == 2)
        #expect(urls(table.rows[0][1]) == ["https://example.com/job--42?x=1#step"])
    }

    @Test func underscoreEmphasisKeepsDestinationsAndStyleWithoutChangingLiteralText() throws {
        let url = "https://example.com/a--b?q=1#f"
        for (source, style) in [("_\(url)_", InlinePresentationIntent.emphasized), ("__\(url)__", .stronglyEmphasized)] {
            let rich = try paragraph(source)
            #expect(urls(rich) == [url])
            #expect(String(rich.characters) == url)
            #expect(rich.runs.contains { $0.link?.absoluteString == url && $0.inlinePresentationIntent == style })
            let literal = CompanionMarkdown.literal(source)
            #expect(Array(String(literal.characters).utf8) == Array(source.utf8))
            #expect(urls(literal) == [url])
        }
    }

    @Test func underscoreInsideAWordDoesNotStartALink() throws {
        for source in ["prefix_https://example.com/a", "prefix__https://example.com/a__suffix"] {
            #expect(urls(try paragraph(source)).isEmpty)
            let literal = CompanionMarkdown.literal(source)
            #expect(String(literal.characters) == source)
            #expect(urls(literal).isEmpty)
        }
    }

    @Test func trimmingMarkupCannotLeaveAnEmptyHost() throws {
        let source = "**https://**"
        #expect(urls(try paragraph(source)).isEmpty)
        #expect(urls(CompanionMarkdown.literal(source)).isEmpty)
        #expect(String(CompanionMarkdown.literal(source).characters) == source)
    }

    @Test func markdownFileKeepsItsExistingSchemeAndLocalLinkPolicy() {
        let source = "https://example.com/a--b?x=1#f [mail](mailto:hello@example.com) [local](./secret.md) [bad](javascript:alert)"
        let preview = CompanionMarkdownFilePreview(source: source)
        guard case .block(.paragraph(let value)) = preview.elements.first else { Issue.record("Missing paragraph"); return }
        #expect(urls(value) == ["https://example.com/a--b?x=1#f", "mailto:hello@example.com"])
        #expect(preview.source == source)
    }

    @Test func ordinaryNoLinkMessagesKeepTheirExistingPaths() throws {
        let source = "Ordinary message -- \"no links\".\nSecond line."
        #expect(CompanionTextLinks.markdownSource(source) == source)
        #expect(String(CompanionMarkdown.literal(source).characters) == source)
        #expect(urls(CompanionMarkdown.literal(source)).isEmpty)
        #expect(String(try paragraph(source).characters) == "Ordinary message – “no links”.\nSecond line.")
    }
}
