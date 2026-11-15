import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif
import Markdown

/// Agent replies parsed into native blocks. cmark-gfm (via swift-markdown) does the parsing, so headings,
/// GFM tables, task lists, quotes and rules follow the same rules as the desktop chat.
/// Inline runs become `AttributedString` with the same presentation intents Foundation's own Markdown
/// initialiser produces, so SwiftUI `Text` renders bold, italics, code and links exactly as before.
struct CompanionMarkdownDocument: Equatable, Sendable {
    var blocks: [CompanionMarkdownBlock]
}

indirect enum CompanionMarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list(CompanionMarkdownList)
    case quote([CompanionMarkdownBlock])
    case rule
    case code(language: String?, code: String)
    case table(CompanionMarkdownTable)
    /// Raw source shown as is: HTML blocks, and while streaming, a trailing block that is still arriving.
    case plain(String)
}

struct CompanionMarkdownList: Equatable, Sendable {
    enum Checkbox: Equatable, Sendable { case checked, unchecked }
    struct Item: Equatable, Sendable {
        var checkbox: Checkbox?
        var blocks: [CompanionMarkdownBlock]
    }
    /// `nil` for bullets; otherwise the number of the first item.
    var start: Int?
    var items: [Item]
}

struct CompanionMarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }
    var alignments: [Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]
    /// The table as GFM Markdown, for Copy and Share.
    var markdown: String
    var columnCount: Int { alignments.count }
}

enum CompanionMarkdown {
    /// Parses `text`, memoised per (text, streaming) so long transcripts don't re-parse on every render.
    static func document(_ text: String, streaming: Bool = false) -> CompanionMarkdownDocument {
        let key = "\(streaming ? 1 : 0)\u{0}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        let document = AnnexTelemetry.shared.measurePerformance(.markdownParse, textBytes: text.utf8.count) {
            parse(text, streaming: streaming)
        }
        cache.setObject(Box(document), forKey: key)
        return document
    }

    /// While streaming, a trailing block that can still change shape (a table missing rows, a line that may
    /// become a setext underline or a rule) stays plain text until a blank line or the end of the turn settles it.
    static func parse(_ text: String, streaming: Bool = false) -> CompanionMarkdownDocument {
        let (settled, tail) = streaming ? splitUnsettledTail(text) : (text, nil)
        var blocks = Document(parsing: settled).children.flatMap { Self.blocks(from: $0, imagesAsPlaceholders: false) }
        if let tail { blocks.append(.plain(tail)) }
        return .init(blocks: blocks)
    }

    // MARK: Streaming

    /// Splits off the text after the last blank line when it looks like a block still forming.
    /// An unclosed code fence is left to cmark, which already renders it as a code block to the end.
    static func splitUnsettledTail(_ text: String) -> (settled: String, tail: String?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var fence: Substring?
        var tailStart = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) && trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
            } else if let marker = fenceMarker(trimmed) {
                fence = marker
            } else if trimmed.allSatisfy(\.isWhitespace) {
                tailStart = index + 1
            }
        }
        guard fence == nil, tailStart < lines.count else { return (text, nil) }
        let tailLines = lines[tailStart...]
        let tail = tailLines.joined(separator: "\n")
        guard !tail.allSatisfy(\.isWhitespace) else { return (text, nil) }
        let isTable = tailLines.contains { $0.drop { $0 == " " }.hasPrefix("|") }
        let last = tailLines.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let mayBecomeUnderline = !last.isEmpty && last.allSatisfy { "-=*_ ".contains($0) }
        guard isTable || mayBecomeUnderline else { return (text, nil) }
        return (lines[..<tailStart].joined(separator: "\n"), tail)
    }

    private static func fenceMarker(_ line: Substring) -> Substring? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            return line.prefix { $0 == mark.first }
        }
        return nil
    }

    // MARK: Blocks

    nonisolated static func blocks(from markup: Markup, imagesAsPlaceholders: Bool) -> [CompanionMarkdownBlock] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: heading.level, text: inline(heading.children, imagesAsPlaceholders: imagesAsPlaceholders))]
        case let paragraph as Paragraph:
            return [.paragraph(inline(paragraph.children, imagesAsPlaceholders: imagesAsPlaceholders))]
        case let list as UnorderedList:
            return [.list(.init(start: nil, items: list.listItems.map { item($0, imagesAsPlaceholders: imagesAsPlaceholders) }))]
        case let list as OrderedList:
            return [.list(.init(start: Int(list.startIndex), items: list.listItems.map { item($0, imagesAsPlaceholders: imagesAsPlaceholders) }))]
        case let quote as BlockQuote:
            return [.quote(quote.children.flatMap { blocks(from: $0, imagesAsPlaceholders: imagesAsPlaceholders) })]
        case is ThematicBreak:
            return [.rule]
        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return [.code(language: language?.isEmpty == false ? language : nil, code: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)]
        case let table as Table:
            return [.table(self.table(table, imagesAsPlaceholders: imagesAsPlaceholders))]
        case let html as HTMLBlock:
            return [.plain(html.rawHTML.trimmingCharacters(in: .newlines))]
        default:
            // Directives and anything cmark adds later: keep their content rather than drop it.
            let children = markup.children.flatMap { blocks(from: $0, imagesAsPlaceholders: imagesAsPlaceholders) }
            return children.isEmpty ? [.plain(markup.format())] : children
        }
    }

    nonisolated private static func item(_ item: ListItem, imagesAsPlaceholders: Bool) -> CompanionMarkdownList.Item {
        let checkbox: CompanionMarkdownList.Checkbox? = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: nil
        }
        return .init(checkbox: checkbox, blocks: item.children.flatMap { blocks(from: $0, imagesAsPlaceholders: imagesAsPlaceholders) })
    }

    nonisolated private static func table(_ table: Table, imagesAsPlaceholders: Bool) -> CompanionMarkdownTable {
        let header = Array(table.head.cells).map { inline($0.children, imagesAsPlaceholders: imagesAsPlaceholders) }
        let rows = table.body.rows.map { row in Array(row.cells).map { inline($0.children, imagesAsPlaceholders: imagesAsPlaceholders) } }
        let count = max(table.columnAlignments.count, header.count, rows.map(\.count).max() ?? 0)
        let alignments = (0..<count).map { index -> CompanionMarkdownTable.Alignment in
            guard index < table.columnAlignments.count else { return .leading }
            switch table.columnAlignments[index] {
            case .center: return .center
            case .right: return .trailing
            default: return .leading
            }
        }
        func padded(_ cells: [AttributedString]) -> [AttributedString] {
            cells + Array(repeating: AttributedString(), count: max(0, count - cells.count))
        }
        return .init(alignments: alignments, header: padded(header), rows: rows.map(padded), markdown: table.format())
    }

    // MARK: Inline

    nonisolated static func inline(_ children: some Sequence<Markup>, intent: InlinePresentationIntent = [], link: URL? = nil, imagesAsPlaceholders: Bool = false) -> AttributedString {
        var result = AttributedString()
        for child in children {
            switch child {
            case let text as Markdown.Text: result += run(text.string, intent, link)
            case is SoftBreak, is LineBreak: result += run("\n", intent, link)
            case let code as InlineCode: result += run(code.code, intent.union(.code), link)
            case let strong as Strong: result += inline(strong.children, intent: intent.union(.stronglyEmphasized), link: link, imagesAsPlaceholders: imagesAsPlaceholders)
            case let emphasis as Emphasis: result += inline(emphasis.children, intent: intent.union(.emphasized), link: link, imagesAsPlaceholders: imagesAsPlaceholders)
            case let strike as Strikethrough: result += inline(strike.children, intent: intent.union(.strikethrough), link: link, imagesAsPlaceholders: imagesAsPlaceholders)
            case let anchor as Markdown.Link:
                let url = anchor.destination.flatMap(URL.init(string:))
                result += inline(anchor.children, intent: intent, link: url ?? link, imagesAsPlaceholders: imagesAsPlaceholders)
            case let image as Markdown.Image:
                // Images are not loaded inline; the alt text (or the source) keeps the meaning.
                let alt = image.plainText
                result += run(imagesAsPlaceholders ? "[Image not shown: \(alt.isEmpty ? "inline image" : alt)]" : (alt.isEmpty ? image.source ?? "" : alt), intent, imagesAsPlaceholders ? nil : link)
            case let html as InlineHTML: result += run(html.rawHTML, intent, link)
            case let symbol as SymbolLink: result += run(symbol.destination ?? "", intent.union(.code), link)
            default: result += inline(child.children, intent: intent, link: link, imagesAsPlaceholders: imagesAsPlaceholders)
            }
        }
        return result
    }

    nonisolated private static func run(_ string: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var run = AttributedString(string)
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if let link { run.link = link }
        return run
    }

    private final class Box: NSObject {
        // ARC-only teardown; reviewed in docs/isolated-deinit.md.
        nonisolated deinit {}
        let document: CompanionMarkdownDocument
        init(_ document: CompanionMarkdownDocument) { self.document = document }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 256
        return cache
    }()
}
