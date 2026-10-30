import CoreGraphics
import Foundation

/// A table or code block opened on its own, full screen (#180). It keeps a copy of the block, so the sheet
/// shows the same content while the reply around it keeps streaming.
struct CompanionMarkdownBlockPreview: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case table(CompanionMarkdownTable)
        case code(language: String?, code: String)
    }
    let id = UUID()
    let content: Content

    init(_ content: Content) { self.content = content }

    /// Tables and code blocks open full screen; other blocks read fine inline.
    init?(_ block: CompanionMarkdownBlock) {
        switch block {
        case .table(let table): self.init(Content.table(table))
        case .code(let language, let code): self.init(Content.code(language: language, code: code))
        default: return nil
        }
    }

    var title: String {
        switch content {
        case .table: "Table"
        case .code(let language, _): language ?? "Code"
        }
    }
    var copyTitle: String {
        switch content {
        case .table: "Copy table"
        case .code: "Copy code"
        }
    }
    /// Tables copy as Markdown, so they paste back as tables; code copies as is.
    var copyText: String {
        switch content {
        case .table(let table): table.markdown
        case .code(_, let code): code
        }
    }
}

/// Where a table's cells go. Each column is as wide as its widest cell, capped so long text wraps, and each row
/// is as tall as its tallest wrapped cell, so no row is cut short (#180). A separator sits above every body row.
struct CompanionMarkdownTableGeometry: Equatable, Sendable {
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var columnOrigins: [CGFloat]
    var rowOrigins: [CGFloat]
    /// The top of the separator above row `index + 1`.
    var separatorOrigins: [CGFloat]
    var size: CGSize

    init(columnWidths: [CGFloat], rowHeights: [CGFloat], columnSpacing: CGFloat, rowSpacing: CGFloat, separatorHeight: CGFloat) {
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        var x: CGFloat = 0
        columnOrigins = columnWidths.map { width in defer { x += width + columnSpacing }; return x }
        var y: CGFloat = 0
        var separators: [CGFloat] = []
        rowOrigins = rowHeights.enumerated().map { index, height in
            if index > 0 {
                y += rowSpacing
                separators.append(y)
                y += separatorHeight + rowSpacing
            }
            defer { y += height }
            return y
        }
        separatorOrigins = separators
        size = CGSize(width: columnWidths.isEmpty ? 0 : x - columnSpacing, height: y)
    }

    /// Each column takes its widest cell's natural width, but no more than `maxWidth`; wider cells wrap.
    static func columnWidths(idealWidths rows: [[CGFloat]], maxWidth: CGFloat) -> [CGFloat] {
        let count = rows.map(\.count).max() ?? 0
        return (0..<count).map { column in
            min(rows.compactMap { column < $0.count ? $0[column] : nil }.max() ?? 0, maxWidth).rounded(.up)
        }
    }
}

/// How much of a long block shows inline. The rest is a tap away, full screen, so no reply grows far taller than the
/// screen; the conversation's lazy stack could stall re-estimating rows that tall (#180).
enum CompanionMarkdownInlineLimit {
    static let tableRows = 8
    static let codeLines = 15

    /// The first `codeLines` lines, and how many more there are.
    static func code(_ code: String) -> (shown: String, hiddenLines: Int) {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > codeLines else { return (code, 0) }
        return (lines.prefix(codeLines).joined(separator: "\n"), lines.count - codeLines)
    }

    /// How many of the table's rows show inline.
    static func shownRows(_ table: CompanionMarkdownTable) -> Int { min(table.rows.count, tableRows) }
}

/// Pinch-to-zoom limits for the full-screen block.
enum CompanionMarkdownZoom {
    static let range: ClosedRange<CGFloat> = 0.5...4
    static func clamped(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, range.lowerBound), range.upperBound)
    }
}
