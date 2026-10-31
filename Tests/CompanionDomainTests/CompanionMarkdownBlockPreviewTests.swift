import CoreGraphics
import Foundation
import Testing
@testable import CompanionDomain

/// Tables and code blocks open full screen (#180).
@Suite struct CompanionMarkdownBlockPreviewTests {
    private let source = """
    | Area | Change |
    |:-----|-------:|
    | **Desktop** | Upgraded to Electron 45.1 with dependency security fixes |
    | Phone | `swift test` |
    """

    @Test func tableCopiesAsMarkdownThatParsesBackToTheSameTable() throws {
        guard case .table(let table) = CompanionMarkdown.parse(source).blocks.first else { Issue.record("Expected a table"); return }
        let preview = try #require(CompanionMarkdownBlockPreview(CompanionMarkdownBlockPreview.Content.table(table)))
        #expect(preview.title == "Table")
        #expect(preview.copyTitle == "Copy table")
        #expect(preview.copyText.contains("**Desktop**"), "Inline styles survive the copy")
        #expect(preview.copyText.contains("`swift test`"))
        guard case .table(let reparsed) = CompanionMarkdown.parse(preview.copyText).blocks.first else { Issue.record("Copy must stay a table"); return }
        #expect(reparsed.header == table.header)
        #expect(reparsed.rows == table.rows)
        #expect(reparsed.alignments == [.leading, .trailing])
    }

    @Test func codeCopiesAsIsAndTakesItsLanguageAsTitle() throws {
        let preview = try #require(CompanionMarkdownBlockPreview(CompanionMarkdownBlock.code(language: "swift", code: "let a = 1\nlet b = 2")))
        #expect(preview.title == "swift")
        #expect(preview.copyTitle == "Copy code")
        #expect(preview.copyText == "let a = 1\nlet b = 2")
        #expect(CompanionMarkdownBlockPreview(CompanionMarkdownBlock.code(language: nil, code: "x"))?.title == "Code")
    }

    @Test func onlyTablesAndCodeOpenFullScreen() {
        #expect(CompanionMarkdownBlockPreview(.paragraph("Hi")) == nil)
        #expect(CompanionMarkdownBlockPreview(.rule) == nil)
        #expect(CompanionMarkdownBlockPreview(.plain("| a |")) == nil)
    }

    @Test func eachOpeningIsItsOwnSheet() {
        let block = CompanionMarkdownBlock.code(language: nil, code: "x")
        #expect(CompanionMarkdownBlockPreview(block)?.id != CompanionMarkdownBlockPreview(block)?.id)
    }

    @Test func columnsTakeTheirWidestCellUpToTheCap() {
        let widths = CompanionMarkdownTableGeometry.columnWidths(idealWidths: [[40, 900, 12.2], [60, 30, 12]], maxWidth: 240)
        #expect(widths == [60, 240, 13])
    }

    @Test func shortRowsDoNotDropColumns() {
        #expect(CompanionMarkdownTableGeometry.columnWidths(idealWidths: [[40], [10, 20]], maxWidth: 240) == [40, 20])
        #expect(CompanionMarkdownTableGeometry.columnWidths(idealWidths: [], maxWidth: 240) == [])
    }

    /// The device bug: a wrapped second row was cut off. Every row's full height is in the table's height.
    @Test func everyRowFitsWithSeparatorsBetweenRows() {
        let geometry = CompanionMarkdownTableGeometry(columnWidths: [60, 240], rowHeights: [20, 80, 40], columnSpacing: 16, rowSpacing: 8,
                                                      separatorHeight: 1)
        #expect(geometry.columnOrigins == [0, 76])
        #expect(geometry.rowOrigins == [0, 37, 134])
        #expect(geometry.separatorOrigins == [28, 125])
        #expect(geometry.size == CGSize(width: 316, height: 174))
        for (origin, height) in zip(geometry.rowOrigins, geometry.rowHeights) {
            #expect(origin + height <= geometry.size.height)
        }
    }

    @Test func emptyTableHasNoSize() {
        let geometry = CompanionMarkdownTableGeometry(columnWidths: [], rowHeights: [], columnSpacing: 16, rowSpacing: 8, separatorHeight: 1)
        #expect(geometry.size == .zero)
        #expect(geometry.separatorOrigins.isEmpty)
    }

    @Test func zoomStaysInRange() {
        #expect(CompanionMarkdownZoom.clamped(0.1) == 0.5)
        #expect(CompanionMarkdownZoom.clamped(2) == 2)
        #expect(CompanionMarkdownZoom.clamped(40) == 4)
        #expect(CompanionMarkdownZoom.clamped(.nan) == 1)
    }

    @Test func longCodeShowsItsFirstLinesInline() {
        let code = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let (shown, hidden) = CompanionMarkdownInlineLimit.code(code)
        #expect(shown.split(separator: "\n").count == CompanionMarkdownInlineLimit.codeLines)
        #expect(shown.hasPrefix("line 1\n"))
        #expect(hidden == 40 - CompanionMarkdownInlineLimit.codeLines)
        #expect(CompanionMarkdownInlineLimit.code("a\nb") == ("a\nb", 0), "Short code shows whole")
    }

    @Test func longTablesShowTheirFirstRowsInline() {
        func table(rows: Int) -> CompanionMarkdownTable {
            .init(alignments: [.leading], header: ["A"], rows: Array(repeating: ["x"], count: rows), markdown: "")
        }
        #expect(CompanionMarkdownInlineLimit.shownRows(table(rows: 3)) == 3)
        #expect(CompanionMarkdownInlineLimit.shownRows(table(rows: 14)) == CompanionMarkdownInlineLimit.tableRows)
    }

    /// The UI test's fixtures: a wide, many-row table and a long code block, each ending where the test scrolls to.
    @Test @MainActor func longBlocksFixturesHaveAWideTableAndLongCode() {
        let tableBlocks = CompanionMarkdown.parse(CompanionPreviewService.longTableReply).blocks
        guard tableBlocks.count == 2, case .table(let table) = tableBlocks[1] else {
            Issue.record("Expected a paragraph and a table, got \(tableBlocks)"); return
        }
        #expect(table.columnCount == 5)
        #expect(table.rows.count == 14)
        #expect(table.rows.last.map { String($0[0].characters) } == "Wrap-up")
        guard case .code(let language, let code) = CompanionMarkdown.parse(CompanionPreviewService.longCodeReply).blocks.first else {
            Issue.record("Expected code"); return
        }
        #expect(language == "typescript")
        let lines = code.split(separator: "\n")
        #expect(lines.count > 60)
        #expect(lines.last == "// End of the release checks")
        #expect(lines.contains { $0.count > 100 }, "One line is wider than the phone")
    }
}
