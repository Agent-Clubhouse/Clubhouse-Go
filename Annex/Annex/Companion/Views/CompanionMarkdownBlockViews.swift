import SwiftUI

/// Opens a table or code block full screen.
struct CompanionMarkdownBlockPresenter {
    var open: @MainActor (CompanionMarkdownBlockPreview) -> Void
}

private struct CompanionMarkdownBlockPresenterKey: EnvironmentKey {
    static let defaultValue: CompanionMarkdownBlockPresenter? = nil
}

extension EnvironmentValues {
    var companionMarkdownBlockPresenter: CompanionMarkdownBlockPresenter? {
        get { self[CompanionMarkdownBlockPresenterKey.self] }
        set { self[CompanionMarkdownBlockPresenterKey.self] = newValue }
    }
}

extension View {
    /// Presents full-screen blocks from here, once, like `companionContentPreviews`: streaming re-creates rows,
    /// and a sheet owned by a row would close with it (#134).
    func companionMarkdownBlockPreviews() -> some View {
        modifier(CompanionMarkdownBlockPreviews())
    }
}

private struct CompanionMarkdownBlockPreviews: ViewModifier {
    @State private var selected: CompanionMarkdownBlockPreview?
    func body(content: Content) -> some View {
        content
            .environment(\.companionMarkdownBlockPresenter, .init(open: { selected = $0 }))
            .sheet(item: $selected) { preview in
                CompanionMarkdownBlockSheet(preview: preview) { selected = nil }
            }
    }
}

/// The frame around an inline table or code block: a caption with Open and Copy, then the block, scrolling sideways.
/// Tap anywhere on it to open it full screen; long-press for Open and Copy. The message's own menu stays
/// on everything else (#180).
struct CompanionMarkdownBlockFrame<Content: View>: View {
    let preview: CompanionMarkdownBlockPreview
    var caption: String
    var background: Color
    @ViewBuilder var content: Content
    @Environment(\.companionMarkdownBlockPresenter) private var presenter
    /// Outside a conversation (no presenter), the block presents its own sheet.
    @State private var local: CompanionMarkdownBlockPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(preview.content.isTable ? "Open table" : "Open code")
                    .accessibilityIdentifier("companion-markdown-open")
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .accessibilityLabel(preview.copyTitle)
            }
            .font(.caption)
            .padding(12)
            Divider()
            ScrollView(.horizontal) { content }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                // As tall as the block, whatever the conversation's lazy stack proposes. Left flexible, a long block
                // was cut short (#180), and its height chased the stack's estimates in an endless update loop.
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)
            Button(preview.copyTitle, systemImage: "doc.on.doc", action: copy)
        }
        .sheet(item: $local) { preview in
            CompanionMarkdownBlockSheet(preview: preview) { local = nil }
        }
    }

    private func open() {
        // A fresh id each time, so reopening the same block presents again.
        let preview = CompanionMarkdownBlockPreview(preview.content)
        if let presenter { presenter.open(preview) } else { local = preview }
    }
    private func copy() { UIPasteboard.general.string = preview.copyText }
}

extension CompanionMarkdownBlockPreview.Content {
    var isTable: Bool { if case .table = self { true } else { false } }
}

// MARK: Table

/// A GFM table laid out cell by cell. Columns are as wide as their widest cell up to a readable cap, long cells
/// wrap, and every row is as tall as its tallest cell, so nothing is clipped (#180). VoiceOver reads it row by
/// row, pairing each cell with its column.
struct CompanionMarkdownTableGrid: View {
    let table: CompanionMarkdownTable
    /// Full screen, cells can be selected; inline, a long-press opens the block's menu instead.
    var selectable = false
    @ScaledMetric(relativeTo: .body) private var maxCellWidth: CGFloat = 240
    @Environment(\.pixelLength) private var pixel

    var body: some View {
        CompanionMarkdownTableLayout(columns: table.columnCount, maxColumnWidth: maxCellWidth) {
            rowElement("Columns: " + table.header.map { String($0.characters) }.joined(separator: ", "))
            ForEach(0..<table.columnCount, id: \.self) { column in
                cell(table.header[column], column: column).font(.subheadline.weight(.semibold))
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                Rectangle().fill(Color(.separator)).frame(height: pixel)
                    .layoutValue(key: CompanionMarkdownTableLayout.Role.self, value: .separator)
                rowElement(rowLabel(index: index, row: row))
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(row[column], column: column).font(.subheadline)
                }
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(table.rows.count) rows, \(table.columnCount) columns")
    }

    /// One element per row, laid over it, so VoiceOver reads the row whole and in place.
    private func rowElement(_ label: String) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isStaticText)
            .layoutValue(key: CompanionMarkdownTableLayout.Role.self, value: .row)
    }

    @ViewBuilder private func cell(_ text: AttributedString, column: Int) -> some View {
        let alignment = table.alignments[column]
        let view = Text(text)
            .multilineTextAlignment(Self.text(alignment))
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: Self.horizontal(alignment), vertical: .top))
            .accessibilityHidden(true)
        if selectable { view.textSelection(.enabled) } else { view }
    }

    private func rowLabel(index: Int, row: [AttributedString]) -> String {
        let cells = zip(table.header, row).map { header, cell in
            let name = String(header.characters)
            return name.isEmpty ? String(cell.characters) : "\(name): \(String(cell.characters))"
        }
        return "Row \(index + 1). " + cells.joined(separator: ", ")
    }

    static func horizontal(_ alignment: CompanionMarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    static func text(_ alignment: CompanionMarkdownTable.Alignment) -> TextAlignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

/// Places a table's cells, row by row, from `CompanionMarkdownTableGeometry`. Subviews are cells in row order,
/// plus a separator before each body row and an accessibility element per row, marked by `Role`.
struct CompanionMarkdownTableLayout: Layout {
    enum Role: LayoutValueKey {
        case cell, separator, row
        static let defaultValue = Role.cell
    }
    var columns: Int
    var maxColumnWidth: CGFloat
    var columnSpacing: CGFloat = 16
    var rowSpacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> CompanionMarkdownTableGeometry? { nil }
    func updateCache(_ cache: inout CompanionMarkdownTableGeometry?, subviews: Subviews) { cache = nil }

    /// The table keeps its own size whatever it is offered; it sits in a horizontal scroll view.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CompanionMarkdownTableGeometry?) -> CGSize {
        geometry(subviews, &cache).size
    }

    /// No alignment guides of its own. The default merges every cell's guides, re-measuring each cell for every
    /// query the conversation's lazy stack makes, which stalled scrolling past a long table.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout CompanionMarkdownTableGeometry?) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout CompanionMarkdownTableGeometry?) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CompanionMarkdownTableGeometry?) {
        let geometry = geometry(subviews, &cache)
        var cell = 0, separator = 0, row = 0
        for subview in subviews {
            switch subview[Role.self] {
            case .cell:
                let (r, c) = (cell / columns, cell % columns)
                cell += 1
                guard r < geometry.rowOrigins.count else { continue }
                subview.place(at: CGPoint(x: bounds.minX + geometry.columnOrigins[c], y: bounds.minY + geometry.rowOrigins[r]),
                              proposal: .init(width: geometry.columnWidths[c], height: nil))
            case .separator:
                guard separator < geometry.separatorOrigins.count else { continue }
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + geometry.separatorOrigins[separator]),
                              proposal: .init(width: geometry.size.width, height: nil))
                separator += 1
            case .row:
                guard row < geometry.rowOrigins.count else { continue }
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + geometry.rowOrigins[row]),
                              proposal: .init(width: geometry.size.width, height: geometry.rowHeights[row]))
                row += 1
            }
        }
    }

    private func geometry(_ subviews: Subviews, _ cache: inout CompanionMarkdownTableGeometry?) -> CompanionMarkdownTableGeometry {
        if let cache { return cache }
        let cells = subviews.filter { $0[Role.self] == .cell }
        let rows: [[LayoutSubview]] = columns > 0 ? stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) } : []
        let widths = CompanionMarkdownTableGeometry.columnWidths(
            idealWidths: rows.map { $0.map { $0.sizeThatFits(.unspecified).width } }, maxWidth: maxColumnWidth)
        let heights = rows.map { row in
            row.enumerated().map { column, cell in cell.sizeThatFits(.init(width: widths[column], height: nil)).height.rounded(.up) }.max() ?? 0
        }
        let separatorHeight = subviews.first { $0[Role.self] == .separator }?.sizeThatFits(.unspecified).height ?? 0
        let geometry = CompanionMarkdownTableGeometry(columnWidths: widths, rowHeights: heights, columnSpacing: columnSpacing,
                                                      rowSpacing: rowSpacing, separatorHeight: separatorHeight)
        cache = geometry
        return geometry
    }
}

// MARK: Full screen

/// One table or code block on its own: scrolls both ways, pinches to zoom, and offers Copy, Share and Done.
struct CompanionMarkdownBlockSheet: View {
    let preview: CompanionMarkdownBlockPreview
    let close: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var contentSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                content
                    .onGeometryChange(for: CGSize.self, of: \.size) { contentSize = $0 }
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
            }
            .accessibilityIdentifier("companion-markdown-block-sheet")
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? zoom
                    pinchStart = start
                    zoom = CompanionMarkdownZoom.clamped(start * value.magnification)
                }
                .onEnded { _ in pinchStart = nil })
            .background(Color(.systemGroupedBackground))
            .privacySensitive()
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close).accessibilityIdentifier("companion-markdown-block-done")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(preview.copyTitle, systemImage: "doc.on.doc") { UIPasteboard.general.string = preview.copyText }
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("companion-markdown-block-copy")
                    Spacer()
                    ShareLink(item: preview.copyText, subject: Text(preview.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("companion-markdown-block-share")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch preview.content {
        case .table(let table):
            CompanionMarkdownTableGrid(table: table, selectable: true)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(16)
        case .code(_, let code):
            // Lines never wrap here; the sheet scrolls sideways instead.
            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize()
                .accessibilityIdentifier("companion-markdown-code")
                .padding(16)
        }
    }
}
