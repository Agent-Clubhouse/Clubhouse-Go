import SwiftUI

/// An agent's details, as the desktop's hover card and Details pane: what it runs on, where it works, its access,
/// MCP servers and changes. Built from the snapshot and the chat session straight away; a durable agent's settings
/// fill in the rest when its desktop offers them. Rows a desktop doesn't send are left out.
struct CompanionAgentDetailsSheet: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette
    @State private var settings: CompanionAgentSettings?
    @State private var loading = false
    @State private var loadError: String?

    private var agent: CompanionAgent? { store.agent(for: target) }
    private var canLoadSettings: Bool { store.canEditSettings(target) }
    private var isDispatcher: Bool { store.isDispatcher(target) }
    /// Re-read when the agent wakes, sleeps or is renamed, as the settings sheet does.
    private var refreshKey: String {
        [agent?.status.rawValue ?? "", agent?.name ?? "", store.host(for: target)?.connection.label ?? ""].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let agent {
                    list(CompanionAgentDetails(agent: agent, providers: store.host(for: target)?.providers ?? [], settings: settings))
                } else {
                    ContentUnavailableView("Agent unavailable", systemImage: "sparkle",
                                           description: Text("This agent is no longer on its desktop, or the desktop is offline."))
                }
            }
            .navigationTitle(agent?.name ?? "Agent details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: refreshKey) { await load() }
        }
        .accessibilityIdentifier("agent-details-sheet")
    }

    @ViewBuilder private func list(_ details: CompanionAgentDetails) -> some View {
        List {
            Section {
                LabeledContent("Status") {
                    Label(details.status.label, systemImage: details.status.symbol).foregroundStyle(Color(palette.secondaryLabel))
                }
                .accessibilityIdentifier("agent-details-status")
                if loading && settings == nil {
                    HStack { ProgressView(); Text("Loading details…").foregroundStyle(Color(palette.secondaryLabel)) }
                        .font(.subheadline)
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                        .accessibilityIdentifier("agent-details-error")
                }
            }

            Section("Runs on") {
                row("CLI", details.cli, id: "agent-details-cli")
                row("Runtime", details.runtime, id: "agent-details-runtime")
                row("Model", details.model, id: "agent-details-model")
                row("Effort", details.effort, id: "agent-details-effort")
            }

            // The Dispatcher works in a folder of its own, outside every project and git.
            if !isDispatcher, details.branch != nil || details.worktree != nil || details.hasWorkspace {
                Section("Workspace") {
                    row("Branch", details.branch, monospaced: true, id: "agent-details-branch")
                    if let worktree = details.worktree {
                        LabeledContent("Worktree") {
                            Text(worktree).font(.subheadline.monospaced()).lineLimit(2).truncationMode(.middle)
                                .foregroundStyle(Color(palette.secondaryLabel)).textSelection(.enabled)
                        }
                        .accessibilityIdentifier("agent-details-worktree")
                    } else if details.hasWorkspace {
                        LabeledContent("Worktree", value: "Works in the project folder")
                            .accessibilityIdentifier("agent-details-worktree")
                    }
                }
            }

            Section {
                row("Permissions", details.access, id: "agent-details-access")
                LabeledContent("Free Agent Mode") {
                    Text(details.freeAgentMode ? "On, all bypassed" : "Off")
                        .foregroundStyle(details.freeAgentMode ? Color(palette.error) : Color(palette.secondaryLabel))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agent-details-free-agent-mode")
                row("Auto-sleep", details.autoSleep, id: "agent-details-auto-sleep")
            } header: { Text("Access") }

            Section {
                if let servers = details.mcpServers, !servers.isEmpty {
                    ForEach(servers) { server in
                        LabeledContent {
                            Text(server.status.label).foregroundStyle(Color(palette.secondaryLabel))
                        } label: {
                            Label {
                                Text(server.displayName)
                            } icon: {
                                Image(systemName: server.status == .connected ? "circle.fill" : "circle")
                                    .font(.caption2).foregroundStyle(mcpTint(server.status))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text(details.status == .sleeping || details.status == .stopped
                         ? "MCP servers show here while the agent is running." : "This agent isn't connected to any MCP servers.")
                        .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                }
            } header: {
                Text("MCP servers")
            } footer: {
                if details.mcpServers != nil { Text(details.mcpSummary).accessibilityIdentifier("agent-details-mcp-summary") }
            }

            if !details.isQuick && !isDispatcher {
                Section {
                    if let changes = details.changes {
                        LabeledContent("Branch vs \(changes.base ?? "main")", value: changes.summary)
                            .accessibilityIdentifier("agent-details-changes")
                        if let detail = changes.detail {
                            Text(detail).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                        }
                    } else {
                        Text(changesUnavailable(details)).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                            .accessibilityIdentifier("agent-details-changes")
                    }
                } header: { Text("Changes") }
            }

            if canLoadSettings {
                Section {
                    NavigationLink {
                        CompanionAgentSettingsForm(store: store, target: target)
                    } label: {
                        Label("Agent settings", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("agent-details-open-settings")
                }
            }
        }
    }

    /// A row only when there's a value: fields a desktop doesn't send are left out, not guessed.
    @ViewBuilder private func row(_ label: String, _ value: String?, monospaced: Bool = false, id: String) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value).font(monospaced ? .subheadline.monospaced() : nil).lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(Color(palette.secondaryLabel))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
        }
    }

    private func changesUnavailable(_ details: CompanionAgentDetails) -> String {
        if details.hasWorkspace { return details.status == .starting ? "Changes show once the agent is set up." : "The desktop couldn't read this agent's changes." }
        if loading { return "Loading…" }
        return canLoadSettings ? "Update Clubhouse on your desktop to see this agent's changes." : "Changes aren't available from this desktop."
    }

    private func mcpTint(_ status: CompanionMCPServer.Status) -> Color {
        switch status {
        case .connected: Color(palette.success)
        case .needsAuth: Color(palette.warning)
        case .failed: Color(palette.error)
        default: Color(palette.secondaryLabel)
        }
    }

    private func load() async {
        guard canLoadSettings else { return }
        loading = true
        defer { loading = false }
        do {
            settings = try await store.settings(for: target).keepingOptions(of: settings)
            loadError = nil
        } catch {
            // The snapshot's details still show; say what's missing.
            if settings == nil { loadError = "Some details are unavailable. \(error.localizedDescription)" }
        }
    }
}
