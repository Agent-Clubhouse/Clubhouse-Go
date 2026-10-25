import SwiftUI

struct CompanionMessageView: View {
    let message: CompanionMessage
    var canRetry: Bool
    var retry: () -> Void
    var canRemoveQueued = false
    var removeQueued: (() -> Void)?
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: message.role == .user ? "person.crop.circle" : "sparkle")
                    .accessibilityHidden(true)
                Text(message.role == .user ? "You" : message.role == .assistant ? "Agent" : "Activity")
                    .font(.subheadline.weight(.semibold))
                if let timestamp = message.timestamp {
                    Text(timestamp, style: .time).font(.caption).foregroundStyle(.tertiary)
                }
                if message.isStreaming { ProgressView().controlSize(.mini).accessibilityLabel("Responding") }
            }
            if message.role == .user {
                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CompanionRichText(text: message.text)
            }
            deliveryStatus
            if let state = message.queueState {
                VStack(alignment: .leading, spacing: 8) {
                    Label(queueLabel(state), systemImage: state == .removed ? "minus.circle" : "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    if state == .queued, let removeQueued {
                        Button("Remove from queue", systemImage: "minus.circle", action: removeQueued)
                            .font(.subheadline).disabled(!canRemoveQueued)
                    }
                }
            }
        }
        .padding(message.role == .user ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color(palette.tintSoft) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
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

/// Native text remains selectable and accessible. Fenced code scrolls horizontally
/// instead of forcing the entire conversation wider than the device.
struct CompanionRichText: View {
    let text: String
    private var segments: [String] { text.components(separatedBy: "```") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index.isMultiple(of: 2) {
                    Text(markdown(segment)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let parts = segment.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let language = parts.count > 1 ? String(parts[0]) : "Code"
                    let code = parts.count > 1 ? String(parts[1]) : segment
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
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
        }
    }
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
                    CompanionContentLinks(references: tool.images + CompanionContentReference.files(in: tool.output ?? ""), store: store, target: target)
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
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(palette.warning).opacity(0.7), lineWidth: 1.5))
            .accessibilityElement(children: .contain)
        }
    }
    @ViewBuilder private var decisionButtons: some View {
        if actionsArePinned {
            Label("Answer below", systemImage: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(approval.options.filter { !actionsArePinned || ($0.kind != .allowOnce && $0.kind != .rejectOnce) }) { option in
            if option.kind == .allowOnce {
                Button(option.label, systemImage: "checkmark") { respond(option) }.buttonStyle(.borderedProminent)
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
        case .uncertain: "Decision delivery unknown — refresh to check"
        }
    }
}
