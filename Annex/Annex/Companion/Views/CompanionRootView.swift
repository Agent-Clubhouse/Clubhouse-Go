import SwiftUI

struct CompanionRootView: View {
    @Bindable var store: CompanionStore
    var onPair: () -> Void
    var onSettings: () -> Void
    @State private var search = ""
    @State private var spawnProject: CompanionProjectTarget?
    @State private var filter: AgentFilter = .all
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private enum AgentFilter: String, CaseIterable, Identifiable {
        case all = "All agents", working = "Working", attention = "Needs you"
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Clubhouse")
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 420)
        } detail: {
            if let target = store.selection, let agent = store.agent(for: target) {
                CompanionConversationView(store: store, agent: agent)
                    .id(target)
            } else {
                ContentUnavailableView {
                    Label("Your agents, within reach", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(store.hosts.isEmpty ? "Pair a desktop to pick up a conversation and keep work moving." : "Choose an agent to see its conversation, review requests, or send a new direction.")
                } actions: {
                    if store.hosts.isEmpty { Button("Pair a desktop", action: onPair).buttonStyle(.borderedProminent) }
                }
            }
        }
        .sheet(item: $spawnProject) { project in
            CompanionSpawnSheet(store: store, initialProject: project)
        }
        .task { store.start() }
    }

    private var sidebar: some View {
        List(selection: $store.selection) {
            Section {
                HStack(spacing: 16) {
                    overviewMetric("Working", count: allAgents.filter { $0.status == .working }.count, symbol: "waveform", color: .accentColor)
                    Divider()
                    overviewMetric("Needs you", count: allAgents.filter { $0.status == .approval || $0.status == .waiting || $0.status == .failed }.count, symbol: "hand.raised", color: .orange)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            if store.hosts.isEmpty {
                ContentUnavailableView("No desktops paired", systemImage: "desktopcomputer", description: Text("Connect over your local network or a direct Tailscale address."))
                    .listRowBackground(Color.clear)
                Button("Pair a desktop", systemImage: "plus", action: onPair)
            }
            ForEach(store.hosts) { host in
                Section {
                    if !host.connection.canOperate {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(host.connection.label, systemImage: "wifi.exclamationmark")
                                .font(.subheadline.weight(.semibold))
                            Text(host.connection.detail).font(.caption).foregroundStyle(.secondary)
                            Button("Reconnect") { Task { await store.reconnect(hostID: host.id) } }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(host.projects) { project in
                        let agents = project.agents.filter(matches)
                        if !agents.isEmpty || search.isEmpty && filter == .all {
                            HStack {
                                Label(project.name, systemImage: "folder")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button {
                                    spawnProject = .init(hostID: host.id, projectID: project.id)
                                } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .disabled(!host.connection.canOperate || !host.canSpawn)
                                    .accessibilityLabel("New agent in \(project.name) on \(host.name)")
                            }
                            .listRowSeparator(.hidden)
                            ForEach(agents) { agent in
                                NavigationLink(value: agent.id) { CompanionAgentRow(agent: agent) }
                                    .accessibilityIdentifier("agent-\(agent.id.hostID)-\(agent.id.agentID)")
                            }
                            if agents.isEmpty {
                                Text("No agents yet").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(host.name)
                        Spacer()
                        Image(systemName: host.connection.canOperate ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(host.connection.canOperate ? .green : .secondary)
                            .accessibilityLabel(host.connection.label)
                    }
                    .textCase(nil)
                } footer: {
                    Text(host.endpoint).font(.caption2).textCase(nil)
                }
            }
            if !search.isEmpty && allAgents.filter(matches).isEmpty {
                ContentUnavailableView.search(text: search).listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, prompt: "Find an agent or task")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Show agents", selection: $filter) {
                        ForEach(AgentFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button("Pair a desktop", systemImage: "desktopcomputer.badge.plus", action: onPair)
                } label: { Label("Filter and desktops", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                Button("New agent", systemImage: "square.and.pencil") {
                    if let host = store.hosts.first(where: { $0.connection.canOperate && $0.canSpawn }), let project = host.projects.first {
                        spawnProject = .init(hostID: host.id, projectID: project.id)
                    }
                }
                .disabled(!store.hosts.contains { $0.connection.canOperate && $0.canSpawn && !$0.projects.isEmpty })
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var allAgents: [CompanionAgent] { store.hosts.flatMap(\.projects).flatMap(\.agents) }
    private func matches(_ agent: CompanionAgent) -> Bool {
        let matchesFilter = filter == .all || filter == .working && agent.status == .working || filter == .attention && (agent.status == .approval || agent.status == .waiting || agent.status == .failed)
        return matchesFilter && (search.isEmpty || "\(agent.name) \(agent.subtitle)".localizedCaseInsensitiveContains(search))
    }
    private func overviewMetric(_ title: String, count: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(count, format: .number).font(.title2.weight(.semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CompanionAgentRow: View {
    let agent: CompanionAgent
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name).font(.headline)
                if !agent.subtitle.isEmpty { Text(agent.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                CompanionStatusLabel(status: agent.status)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct CompanionStatusLabel: View {
    let status: CompanionAgentStatus
    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .approval, .waiting: .orange
        case .failed: .red
        case .working: .accentColor
        case .completed: .green
        default: .secondary
        }
    }
}
