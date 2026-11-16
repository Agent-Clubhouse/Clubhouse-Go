import SwiftUI
import ClubhouseTransport

/// One state, followed by the desktop's request or task rather than a second state label.
struct CompanionAgentStatusLine: Equatable {
    let status: String
    let task: String?

    init(agent: CompanionAgent, detail: String? = nil) {
        let message = agent.detail?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplied = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: String
        switch agent.status {
        case .approval: state = "Needs permission"
        case .waiting: state = "Has a question"
        default: state = agent.status.label
        }
        let permissionLine = CompanionAttentionItem.permissionLine(toolName: agent.detail?.toolName)
        let questionLine = CompanionAttentionItem.questionLine
        let fallback: String?
        if agent.status == .approval, let tool = agent.detail?.toolName {
            fallback = CompanionAttentionItem.shortToolName(tool)
        } else { fallback = nil }
        let candidates = [supplied, message, agent.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)]
        status = state
        task = candidates.compactMap { $0 }.first { value in
            !value.isEmpty && value != state && value != agent.status.label
                && value != permissionLine && value != questionLine
        } ?? fallback
    }
}

struct CompanionAgentRowContext {
    var hostNames: [String: String] = [:]
    var impliedHostID: String?
    var projectAccessDefaults: [CompanionProjectTarget: CompanionPermissionLevel] = [:]
    var agentAccessDefaults: [CompanionTarget: CompanionPermissionLevel] = [:]

    func defaultAccess(for target: CompanionTarget) -> CompanionPermissionLevel? {
        agentAccessDefaults[target] ?? projectAccessDefaults[.init(hostID: target.hostID, projectID: target.projectID)]
    }

    func accessBadge(for agent: CompanionAgent) -> CompanionPermissionLevel? {
        guard let access = agent.access, access != defaultAccess(for: agent.id) else { return nil }
        return access
    }

    func hostTag(for target: CompanionTarget, fallback: String? = nil) -> String? {
        guard target.hostID != impliedHostID else { return nil }
        guard !hostNames.isEmpty else { return fallback }
        return hostNames.count > 1 ? hostNames[target.hostID] : nil
    }
}

private struct CompanionAgentRowContextKey: EnvironmentKey {
    static let defaultValue = CompanionAgentRowContext()
}

extension EnvironmentValues {
    var companionAgentRowContext: CompanionAgentRowContext {
        get { self[CompanionAgentRowContextKey.self] }
        set { self[CompanionAgentRowContextKey.self] = newValue }
    }
}

extension View {
    func companionAgentRows(store: CompanionStore, impliedHostID: String? = nil) -> some View {
        environment(\.companionAgentRowContext, CompanionAgentRowContext(
            hostNames: Dictionary(store.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            impliedHostID: impliedHostID, projectAccessDefaults: store.projectAccessDefaults,
            agentAccessDefaults: store.agentAccessDefaults))
    }
}

/// Observe disclosure once at the collection boundary. Equatable value rows avoid redrawing unchanged
/// agent labels when a different parent's disclosure changes; the domain layout never observes collapse.
struct CompanionAgentTreeRows: View {
    let tree: CompanionAgentTree
    let rows: [CompanionAgentTreeRow]
    let preferences: CompanionPreferences
    var parentLines: [CompanionTarget: String] = [:]
    @Environment(\.companionTelemetryScreen) private var screen

    var body: some View {
        let collapsed = preferences.collapsedAgents(in: rows)
        let hasDisclosureColumn = rows.contains { $0.rollup.count > 0 }
        ForEach(tree.visible(rows, collapsed: collapsed)) { row in
            CompanionAgentTreeNavigationRow(row: row, collapsed: row.rollup.count > 0 && collapsed.contains(row.id), parentLine: parentLines[row.id], hasDisclosureColumn: hasDisclosureColumn, screen: screen,
                                            toggle: { preferences.toggleAgentCollapsed(row.id) })
                .equatable()
                .listRowBackground(CompanionCardBackground())
        }
    }
}

private struct CompanionAgentTreeNavigationRow: View, Equatable {
    let row: CompanionAgentTreeRow
    let collapsed: Bool
    let parentLine: String?
    let hasDisclosureColumn: Bool
    let screen: AnnexUIAction.Screen?
    let toggle: () -> Void
    @Environment(\.companionPalette) private var palette

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.collapsed == rhs.collapsed && lhs.parentLine == rhs.parentLine && lhs.hasDisclosureColumn == rhs.hasDisclosureColumn && lhs.screen == rhs.screen
    }

    var body: some View {
        HStack(spacing: 0) {
            if row.rollup.count > 0 {
                Button {
                    CompanionUIActions.record(.expandHelpers, on: screen)
                    toggle()
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(Color(palette.secondaryLabel))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Helpers of \(row.agent.name), \(row.rollup.label)")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(collapsed ? "Shows helpers" : "Hides helpers")
                .accessibilityIdentifier("helpers-toggle-\(row.id.hostID)-\(row.id.agentID)")
            } else if hasDisclosureColumn {
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
            NavigationLink(value: row.id) {
                CompanionAgentListRow(agent: row.agent, parentLine: parentLine, helperRollup: collapsed ? row.rollup : nil)
            }
            .accessibilityIdentifier("agent-\(row.id.hostID)-\(row.id.agentID)")
            .accessibilityValue(row.parentName.map { "Helper of \($0)" } ?? "")
            .accessibilityHint("Opens conversation")
        }
        .padding(.leading, CGFloat(min(row.depth, 3)) * 14)
    }
}

struct CompanionAgentTreeFold: View {
    let kind: String
    let projectID: String
    let text: String
    let tree: CompanionAgentTree
    let rows: [CompanionAgentTreeRow]
    let preferences: CompanionPreferences
    var parentLines: [CompanionTarget: String] = [:]
    @Environment(\.companionTelemetryScreen) private var screen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let key = "\(kind):\(projectID)"
        let isOpen = preferences.expandedFolds.contains(key)
        Button {
            switch kind {
            case "sleeping": CompanionUIActions.record(.expandSleepingAgents, on: screen)
            case "finished": CompanionUIActions.record(.expandFinishedAgents, on: screen)
            case "quiet": CompanionUIActions.record(.expandQuietAgents, on: screen)
            default: break
            }
            withAnimation(reduceMotion ? nil : .snappy) { preferences.toggleFold(key) }
        } label: {
            CompanionFoldLabel(text: text, isOpen: isOpen)
        }
        .accessibilityIdentifier("fold-\(kind)-\(projectID)")
        .listRowBackground(CompanionCardBackground())
        if isOpen { CompanionAgentTreeRows(tree: tree, rows: rows, preferences: preferences, parentLines: parentLines) }
    }
}

/// One disclosure for the two quiet groups. Home adopts this alongside its desktop-filter wiring.
struct CompanionAgentTreeQuietFold: View {
    let projectID: String
    let tree: CompanionAgentTree
    let preferences: CompanionPreferences
    var parentLines: [CompanionTarget: String] = [:]

    var text: String {
        var parts: [String] = []
        if !tree.sleeping.isEmpty { parts.append("\(tree.sleeping.count) sleeping") }
        if !tree.finishedQuick.isEmpty {
            parts.append("\(tree.finishedQuick.count) finished quick agent\(tree.finishedQuick.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !text.isEmpty {
            CompanionAgentTreeFold(kind: "quiet", projectID: projectID, text: text,
                                   tree: tree, rows: tree.sleeping + tree.finishedQuick,
                                   preferences: preferences, parentLines: parentLines)
        }
    }
}
