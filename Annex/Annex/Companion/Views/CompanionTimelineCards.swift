import SwiftUI

private struct CompanionSenderResolverKey: EnvironmentKey {
    static let defaultValue = CompanionSenderResolver(agents: [])
}
extension EnvironmentValues {
    var companionSenderResolver: CompanionSenderResolver {
        get { self[CompanionSenderResolverKey.self] }
        set { self[CompanionSenderResolverKey.self] = newValue }
    }
}

struct CompanionMessageView: View {
    let message: CompanionMessage
    var canRetry: Bool
    var retry: () -> Void
    var canRemoveQueued = false
    var removeQueued: (() -> Void)?
    /// In the conversation, a long reply is shown a slice per row (#188); the archive shows it whole.
    var slice: CompanionMessageSlice?
    var expansion: CompanionTranscriptExpansion
    @Environment(\.companionPalette) private var palette

    /// Like the desktop: agent replies have no author label; your messages sit on the right with their source.
    var body: some View {
        Group {
            switch message.role {
            case .user:
                switch message.display {
                case .others(let parts): routedMessages(parts)
                case .you(let text): userMessage(text)
                }
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    richText
                    if message.isStreaming && slice?.isLast != false { ProgressView().controlSize(.small).accessibilityLabel("Responding") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                VStack(alignment: .leading, spacing: 10) {
                    if slice?.index ?? 0 == 0 { Label("Activity", systemImage: "sparkle").font(.subheadline.weight(.semibold)) }
                    richText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
    }

    @ViewBuilder private var richText: some View {
        if let slice {
            CompanionMarkdownBlocks(blocks: slice.blocks, depth: 0).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CompanionRichText(text: message.text, isStreaming: message.isStreaming)
        }
    }

    /// A burst remains separate messages; only a part's open state is observed by its own view.
    private func routedMessages(_ parts: [CompanionRoutedMessagePart]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CompanionSentPartsView(parts: parts, message: message, expansion: expansion)
            if !message.images.isEmpty { CompanionMessageImages(images: message.images) }
            deliveryStatus
            queueStatus
        }
        .multilineTextAlignment(.leading)
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Text((["You"] + message.metaLabels).joined(separator: " · "))
                if let timestamp = message.timestamp { Text(timestamp, style: .time).foregroundStyle(.tertiary) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("companion-message-source")
            if !message.images.isEmpty { CompanionMessageImages(images: message.images) }
            if !text.isEmpty || message.images.isEmpty {
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(palette.tintSoft), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            deliveryStatus
            queueStatus
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var queueStatus: some View {
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

/// This is the only resolver subscriber. Assistant, system and own-message rows never read its environment.
private struct CompanionSentPartsView: View {
    let parts: [CompanionRoutedMessagePart]
    let message: CompanionMessage
    let expansion: CompanionTranscriptExpansion
    @Environment(\.companionSenderResolver) private var senderResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                CompanionSentPartView(part: part, message: message, index: index,
                                      identity: senderResolver.avatarIdentity(for: part.sender),
                                      expansion: expansion.part(messageID: message.id, index: index))
            }
        }
    }
}

/// The caption is a native button for long parts. Its body is constructed only while open.
private struct CompanionSentPartView: View {
    let part: CompanionRoutedMessagePart
    let message: CompanionMessage
    let index: Int
    let identity: CompanionSenderIdentity?
    let expansion: CompanionPartExpansion
    @Environment(\.companionPalette) private var palette

    private var name: String { identity?.name ?? part.sender?.name ?? (part.fromClubhouse ? "Clubhouse" : message.source == "group_project" ? "Group project" : "Another agent") }
    private var identifier: String { "companion-routed-\(message.id)-\(index)" }
    private var caption: String { part.caption(source: message.source, isSteered: message.isSteered, currentName: name) }
    private var longCaption: String { (["\(name) sent a long message"] + message.metaLabels).joined(separator: " · ") }

    var body: some View {
        let collapsible = CompanionMessageRouting.isLongMessage(part.text)
        let open = expansion.isOpen(for: part.text)
        HStack(alignment: .top, spacing: 8) {
            if let identity {
                CompanionIdentityFace(name: identity.name, color: identity.color, emoji: identity.emoji,
                                      iconData: identity.iconData, size: 24)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name) avatar")
                    .accessibilityHidden(false)
                    .accessibilityIdentifier("companion-sender-avatar-\(message.id)-\(index)")
            }
            if collapsible {
                VStack(alignment: .leading, spacing: 6) {
                    Button { expansion.open = !open } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(longCaption)
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                            timestamp
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "\(name): \(part.text)" : "\(longCaption), collapsed")
                    .accessibilityValue(open ? (["Expanded"] + accessibilityMetadata).joined(separator: ", ") : "Collapsed")
                    .accessibilityHint(open ? "Collapse message" : "Expand message")
                    .accessibilityIdentifier(identifier)
                    .contextMenu { copyMessage }
                    if open && !part.text.isEmpty {
                        bubble.accessibilityIdentifier("companion-routed-body-\(message.id)-\(index)")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { Text(caption); timestamp }
                        .font(.caption).foregroundStyle(.secondary)
                    if !part.text.isEmpty { bubble }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name): \(part.text)")
                .accessibilityValue(accessibilityMetadata.joined(separator: ", "))
                .accessibilityIdentifier(identifier)
                .contextMenu { copyMessage }
            }
        }
    }
    private var accessibilityMetadata: [String] {
        message.metaLabels + [message.timestamp?.formatted(date: .omitted, time: .shortened)].compactMap { $0 }
    }
    @ViewBuilder private var timestamp: some View {
        if let timestamp = message.timestamp { Text(timestamp, style: .time).foregroundStyle(.tertiary) }
    }
    private var bubble: some View {
        Group {
            if part.sender != nil { CompanionRichText(text: part.text) }
            else { Text(part.text).textSelection(.enabled) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(palette.tintSoft), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { copyMessage }
    }
    private var copyMessage: some View {
        Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
    }
}

extension CompanionTimelineEntry {
    /// Rows sit 22pt apart; slices of one reply sit as close as its blocks, or its list items when one is cut.
    var spacingBefore: CGFloat {
        guard case .slice(_, let slice) = self, slice.index > 0 else { return 22 }
        return slice.continuesBlock ? 6 : 12
    }
}

/// Native text remains selectable and accessible. Block Markdown (headings, lists, quotes, rules, GFM tables)
/// maps to SwiftUI views; fenced code and tables scroll horizontally instead of widening the conversation,
/// and open full screen when tapped.
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

/// A GFM table that scrolls sideways when it is wide and grows to fit its rows. Long tables show their first rows,
/// then "Show all"; tap anywhere to open the whole table full screen.
struct CompanionMarkdownTableView: View {
    let table: CompanionMarkdownTable
    var body: some View {
        let shown = CompanionMarkdownInlineLimit.shownRows(table)
        CompanionMarkdownBlockFrame(preview: .init(.table(table)), caption: "Table · \(table.rows.count) \(table.rows.count == 1 ? "row" : "rows")",
                                    background: Color(.secondarySystemGroupedBackground).opacity(0.6),
                                    showAll: shown < table.rows.count ? "Show all \(table.rows.count) rows" : nil) {
            CompanionMarkdownTableGrid(table: table, rowLimit: shown)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

/// Fenced code that scrolls sideways rather than wrapping. Long code shows its first lines, then "Show all";
/// tap anywhere to open the whole block full screen.
struct CompanionCodeBlock: View {
    let language: String?
    let code: String
    var body: some View {
        let (shown, hidden) = CompanionMarkdownInlineLimit.code(code)
        CompanionMarkdownBlockFrame(preview: .init(.code(language: language, code: code)), caption: language ?? "Code",
                                    background: Color(.tertiarySystemGroupedBackground),
                                    showAll: hidden > 0 ? "Show all \(CompanionMarkdownInlineLimit.codeLines + hidden) lines" : nil) {
            Text(shown).font(.system(.callout, design: .monospaced)).fixedSize().padding(12)
        }
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
                    CompanionToolTitle(tool: tool)
                    Text(tool.awaitsApproval ? "Waiting for approval" : tool.state == .running ? "Running" : tool.state == .completed ? "Completed" : "Failed")
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

/// A tool's verb and what it acts on ("Read Sources/App.swift"), as the desktop labels tool rows.
/// Without a kind from the desktop, the tool's own title.
struct CompanionToolTitle: View {
    let tool: CompanionTool
    var body: some View {
        if let verb = tool.verb {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verb).font(.subheadline.weight(.semibold))
                Text(tool.target).font(.subheadline).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(tool.name).font(.subheadline.weight(.semibold))
        }
    }
}

/// A run of read-only tool calls folded into one "Explored 3 files, 2 searches" row, expanded on tap.
/// Each call's content links stay reachable inside; previews open from the conversation, not from this row.
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
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(palette.secondaryLabel))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CompanionTimelineFolding.exploreLabel(tools)).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("companion-explore-label")
                        Text(names).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                    }
                    Spacer()
                    if isRunning { ProgressView().controlSize(.small).accessibilityLabel("Running") }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                        .foregroundStyle(Color(palette.secondaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapses the tool calls" : "Shows each tool call")
            .accessibilityIdentifier("companion-explore-group")
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

    private var isRunning: Bool { tools.contains { $0.state == .running } }

    /// What was looked at, once each: file names rather than full paths.
    private var names: String {
        var seen: [String] = []
        for tool in tools {
            let name = tool.location.map { ($0 as NSString).lastPathComponent } ?? tool.name
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: ", ")
    }
}

struct CompanionApprovalCard: View {
    let approval: CompanionApproval
    /// "1 of 3" when several approvals are waiting.
    var queuePosition: String?
    let canRespond: Bool
    /// When the bar above the composer carries Deny and Allow once, the card keeps only the other options.
    var actionsArePinned = false
    /// The desktop takes lasting options ("Allow always") from the phone (`permissions.persistentApprovals`).
    var persistentApprovals = false
    let respond: (CompanionApprovalOption) -> Void
    @State private var showDetails = false
    @State private var confirming: CompanionApprovalOption?
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = approval.isExpired(at: context.date)
            let live = approval.resolution == .pending && !expired
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    // Like the desktop's dock: the request's title, with the warning colour on the icon only.
                    Label {
                        Text(live ? requestTitle : title(expired: expired))
                            .foregroundStyle(live ? Color.primary : Color(palette.warning))
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color(palette.warning))
                    }
                    .font(.headline)
                    .accessibilityIdentifier("companion-approval-title")
                    if live, let queuePosition {
                        Spacer(minLength: 8)
                        Text(queuePosition).font(.caption).foregroundStyle(.secondary).fixedSize()
                            .accessibilityLabel("Request \(queuePosition)")
                            .accessibilityIdentifier("companion-approval-position")
                    }
                }
                if !live { Text(requestTitle).font(.subheadline.weight(.semibold)) }
                if approval.summary != requestTitle { Text(approval.summary).font(.body).textSelection(.enabled) }
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
                if live {
                    ViewThatFits(in: .horizontal) {
                        HStack { decisionButtons }
                        VStack(alignment: .leading) { decisionButtons }
                    }
                    .disabled(!canRespond)
                    persistentOptions
                } else if approval.resolution == .submitting {
                    ProgressView("Sending decision…").font(.subheadline)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(live ? Color(palette.warning).opacity(0.7) : Color(palette.separator), lineWidth: 1.5))
            .accessibilityElement(children: .contain)
        }
        .confirmationDialog(confirming.map { "\($0.label)?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { option in
            Button(option.label) { respond(option) }
        } message: { option in
            Text(option.kind == .allowSession
                 ? "The agent won't ask again for \(option.scope ?? "this") until the session ends."
                 : "The agent won't ask again for \(option.scope ?? "this"). You can change this on your desktop.")
        }
    }
    @ViewBuilder private var decisionButtons: some View {
        if actionsArePinned {
            Label("Answer below", systemImage: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(approval.options.filter { $0.isOneOff && (!actionsArePinned || ($0.kind != .allowOnce && $0.kind != .rejectOnce)) }) { option in
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
    /// Options that change the agent's permissions for good ("Allow always"). The desktop lists them with the rest, numbered.
    /// Desktops that take them from a phone get secondary buttons; older ones show what to choose there.
    @ViewBuilder private var persistentOptions: some View {
        let persistent = approval.options.enumerated().filter { !$0.element.isOneOff }
        let answerable = persistent.filter { $0.element.isAnswerable(persistentApprovals: persistentApprovals) }
        if !answerable.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(answerable, id: \.element.id) { _, option in
                    Button {
                        if option.needsConfirmation { confirming = option } else { respond(option) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(option.label)
                            if let scope = option.scope { Text(scope).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .buttonStyle(.bordered).font(.subheadline)
                    .accessibilityIdentifier("companion-approval-option-\(option.id)")
                }
            }
            .disabled(!canRespond)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion-approval-persistent-actions")
        }
        let readOnly = persistent.filter { !$0.element.isAnswerable(persistentApprovals: persistentApprovals) }
        if !readOnly.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(readOnly, id: \.element.id) { index, option in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(option.label).font(.subheadline)
                        if let scope = option.scope { Text(scope).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Choose this on your desktop")
                }
                Text("Choose this on your desktop").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion-approval-persistent")
        }
    }
    /// The request's own title, else the tool asking.
    private var requestTitle: String { approval.title ?? approval.toolName }
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
