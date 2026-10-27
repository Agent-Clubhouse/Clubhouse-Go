import SwiftUI

struct CompanionMessageView: View {
    let message: CompanionMessage
    var canRetry: Bool
    var retry: () -> Void
    var canRemoveQueued = false
    var removeQueued: (() -> Void)?
    @Environment(\.companionPalette) private var palette

    /// Like the desktop: agent replies have no author label; your messages sit on the right with their source.
    var body: some View {
        Group {
            switch message.role {
            case .user: userMessage
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    CompanionRichText(text: message.text, isStreaming: message.isStreaming)
                    if message.isStreaming { ProgressView().controlSize(.small).accessibilityLabel("Responding") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                VStack(alignment: .leading, spacing: 10) {
                    Label("Activity", systemImage: "sparkle").font(.subheadline.weight(.semibold))
                    CompanionRichText(text: message.text, isStreaming: message.isStreaming)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if message.sourceLabel != nil || message.timestamp != nil {
                HStack(spacing: 6) {
                    if let label = message.sourceLabel { Text(label) }
                    if let timestamp = message.timestamp { Text(timestamp, style: .time).foregroundStyle(.tertiary) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(userCaption)
                .accessibilityIdentifier("companion-message-source")
            }
            if !message.images.isEmpty { CompanionMessageImages(images: message.images) }
            if !message.text.isEmpty || message.images.isEmpty {
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(palette.tintSoft), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel(message.sourceLabel == nil && message.timestamp == nil ? "You: \(message.text)" : message.text)
            }
            deliveryStatus
            if let state = message.queueState {
                VStack(alignment: .trailing, spacing: 8) {
                    Label(queueLabel(state), systemImage: state == .removed ? "minus.circle" : "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    if state == .queued, let removeQueued {
                        Button("Remove from queue", systemImage: "minus.circle", action: removeQueued)
                            .font(.subheadline).disabled(!canRemoveQueued)
                    }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userCaption: String {
        var parts = ["You"]
        if let label = message.sourceLabel { parts.append(label) }
        if let timestamp = message.timestamp { parts.append(timestamp.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var deliveryStatus: some View {
        if let label = message.delivery.label {
            VStack(alignment: .leading, spacing: 5) {
                Label(label, systemImage: deliverySymbol).font(.caption.weight(.medium)).foregroundStyle(deliveryColor)
                switch message.delivery {
                case .failed(let detail):
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Button("Try sending again", action: retry).font(.subheadline.weight(.semibold)).disabled(!canRetry)
                case .uncertain(let detail):
                    Text("\(detail) Refresh the conversation before sending this again to avoid running it twice.")
                        .font(.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
        }
    }
    private var deliverySymbol: String {
        switch message.delivery {
        case .sending: "clock"
        case .uploading: "arrow.up.circle"
        case .accepted, .confirmed: "checkmark"
        case .failed: "exclamationmark.circle"
        case .uncertain: "questionmark.circle"
        }
    }
    private var deliveryColor: Color {
        switch message.delivery {
        case .failed: .red
        case .uncertain: .orange
        default: .secondary
        }
    }
    private func queueLabel(_ state: CompanionMessage.QueueState) -> String {
        switch state {
        case .queued: "Queued for the next turn"
        case .dispatching: "Sending to the agent"
        case .delivered: "Delivered to the agent"
        case .failed: "Queue delivery unknown — refresh before sending again"
        case .removed: "Removed from queue"
        case .submitted: "Follow-up submitted"
        }
    }
}

/// Native text remains selectable and accessible. Block Markdown (headings, lists, quotes, rules, GFM tables)
/// maps to SwiftUI views; fenced code and tables scroll horizontally instead of widening the conversation.
struct CompanionRichText: View {
    let text: String
    var isStreaming = false
    var body: some View {
        CompanionMarkdownBlocks(blocks: CompanionMarkdown.document(text, streaming: isStreaming).blocks, depth: 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompanionMarkdownBlocks: View {
    let blocks: [CompanionMarkdownBlock]
    let depth: Int
    var spacing: CGFloat = 12
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                CompanionMarkdownBlockView(block: block, depth: depth)
            }
        }
    }
}

struct CompanionMarkdownBlockView: View {
    let block: CompanionMarkdownBlock
    let depth: Int
    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(text).font(Self.headingFont(level)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .list(let list):
            CompanionMarkdownListView(list: list, depth: depth)
        case .quote(let blocks):
            CompanionMarkdownBlocks(blocks: blocks, depth: depth, spacing: 8)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.45)).frame(width: 3)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Quote")
        case .rule:
            Divider().padding(.vertical, 4)
        case .code(let language, let code):
            CompanionCodeBlock(language: language, code: code)
        case .table(let table):
            CompanionMarkdownTableView(table: table)
        case .plain(let text):
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

struct CompanionMarkdownListView: View {
    let list: CompanionMarkdownList
    let depth: Int
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 20
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index: index, item: item).frame(minWidth: markerWidth, alignment: .trailing)
                    CompanionMarkdownBlocks(blocks: item.blocks, depth: depth + 1, spacing: 6)
                }
            }
        }
    }

    @ViewBuilder private func marker(index: Int, item: CompanionMarkdownList.Item) -> some View {
        if let checkbox = item.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checkbox == .checked ? Color.accentColor : .secondary)
                .accessibilityLabel(checkbox == .checked ? "Done" : "Not done")
        } else if let start = list.start {
            Text("\(start + index).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(["•", "◦", "▪"][depth % 3]).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// A GFM table in a horizontally scrolling `Grid`. Long cells wrap at a readable width rather than
/// stretching a column off screen. VoiceOver reads it row by row, pairing each cell with its column.
struct CompanionMarkdownTableView: View {
    let table: CompanionMarkdownTable
    @ScaledMetric(relativeTo: .body) private var maxCellWidth: CGFloat = 240
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[column], column: column).font(.subheadline.weight(.semibold))
                            .gridColumnAlignment(Self.horizontal(table.alignments[column]))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(row[column], column: column).font(.subheadline)
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(table.rows.count) rows, \(table.columnCount) columns")
        .accessibilityChildren {
            VStack {
                Text("Columns: " + table.header.map { String($0.characters) }.joined(separator: ", "))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    Text(rowLabel(index: index, row: row))
                }
            }
        }
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        Text(text).textSelection(.enabled)
            .multilineTextAlignment(Self.text(table.alignments[column]))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxCellWidth, alignment: Alignment(horizontal: Self.horizontal(table.alignments[column]), vertical: .top))
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

struct CompanionCodeBlock: View {
    let language: String?
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
                    .font(.caption).accessibilityLabel("Copy code")
            }.padding(12)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
            }
        }
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CompanionToolCard: View {
    let tool: CompanionTool
    @State private var expanded = false
    @Environment(\.companionPalette) private var palette
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !tool.summary.isEmpty { Text(tool.summary).font(.callout.monospaced()).textSelection(.enabled) }
                if let output = tool.output, !output.isEmpty {
                    Divider()
                    Text(output).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name).font(.subheadline.weight(.semibold))
                    Text(tool.state == .running ? "Running" : tool.state == .completed ? "Completed" : "Failed")
                        .font(.caption).foregroundStyle(.secondary)
                    if !tool.summary.isEmpty { Text(tool.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .tint(.secondary)
        .padding(14)
        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
    private var symbol: String { tool.state == .running ? "terminal" : tool.state == .completed ? "checkmark.circle" : "exclamationmark.circle" }
    private var color: Color { tool.state == .failed ? Color(palette.error) : tool.state == .completed ? Color(palette.success) : Color(palette.tint) }
}

/// A run of finished tool calls folded into one row, expanded on tap.
struct CompanionToolGroupCard: View {
    let tools: [CompanionTool]
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @State private var expanded = false
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bolt").foregroundStyle(Color(palette.secondaryLabel))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ran \(tools.count) tools").font(.subheadline.weight(.semibold))
                        Text(names).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                        .foregroundStyle(Color(palette.secondaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapses the tool calls" : "Shows each tool call")
            if expanded {
                ForEach(tools) { tool in
                    CompanionToolCard(tool: tool)
                    CompanionContentLinks(references: CompanionContentReference.references(in: .tool(tool)))
                }
            }
        }
        .padding(14)
        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var names: String {
        var seen: [String] = []
        for tool in tools where !seen.contains(tool.name) { seen.append(tool.name) }
        return seen.joined(separator: ", ")
    }
}

struct CompanionApprovalCard: View {
    let approval: CompanionApproval
    let canRespond: Bool
    /// When the bar above the composer carries Deny and Allow once, the card keeps only the other options.
    var actionsArePinned = false
    let respond: (CompanionApprovalOption) -> Void
    @State private var showDetails = false
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = approval.isExpired(at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                Label(title(expired: expired), systemImage: "hand.raised.fill")
                    .font(.headline).foregroundStyle(Color(palette.warning))
                Text(approval.toolName).font(.subheadline.weight(.semibold))
                Text(approval.summary).font(.body).textSelection(.enabled)
                if let detail = approval.detail, !detail.isEmpty {
                    DisclosureGroup("Review details", isExpanded: $showDetails) {
                        ScrollView(.horizontal) {
                            Text(detail).font(.callout.monospaced()).textSelection(.enabled).padding(.vertical, 8)
                        }
                    }.font(.subheadline)
                }
                if let deadline = approval.deadline, !expired, approval.resolution == .pending {
                    HStack(spacing: 4) {
                        Text("Expires")
                        Text(deadline, style: .relative)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if approval.resolution == .pending && !expired {
                    ViewThatFits(in: .horizontal) {
                        HStack { decisionButtons }
                        VStack(alignment: .leading) { decisionButtons }
                    }
                    .disabled(!canRespond)
                } else if approval.resolution == .submitting {
                    ProgressView("Sending decision…").font(.subheadline)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(approval.resolution == .pending && !expired ? Color(palette.warning).opacity(0.7) : Color(palette.separator), lineWidth: 1.5))
            .accessibilityElement(children: .contain)
        }
    }
    @ViewBuilder private var decisionButtons: some View {
        if actionsArePinned {
            Label("Answer below", systemImage: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(approval.options.filter { !actionsArePinned || ($0.kind != .allowOnce && $0.kind != .rejectOnce) }) { option in
            if option.kind == .allowOnce {
                Button(option.label, systemImage: "checkmark") { respond(option) }.buttonStyle(.borderedProminent).companionProminentLabel()
            } else {
                Button(option.label, systemImage: "xmark", role: .destructive) { respond(option) }.buttonStyle(.bordered)
            }
        }
        if approval.options.isEmpty {
            Text("Review this request on desktop.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func title(expired: Bool) -> String {
        switch approval.resolution {
        case .pending: expired ? "Request expired" : "Your approval is needed"
        case .submitting: "Sending your decision"
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .expired: "Request expired"
        case .cancelled: "Request withdrawn"
        case .uncertain: "Decision delivery unknown — refresh to check"
        }
    }
}
