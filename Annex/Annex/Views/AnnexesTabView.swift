import SwiftUI

/// Annexes tab — lists connected instances with app-level plugins and projects.
struct AnnexesTabView: View {
    @Environment(AppStore.self) private var store
    @State private var showAddInstance = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.instances) { instance in
                    Section {
                        // Instance header row — tap to configure
                        NavigationLink(value: AnnexNav.instanceConfig(instance.id)) {
                            InstanceHeaderRow(instance: instance)
                        }
                        .listRowBackground(store.theme.surface0Color.opacity(0.5))

                        // App-level plugins (Home, Canvas, etc.)
                        let annexPlugins = instance.plugins.filter(\.annexEnabled)
                        let otherPlugins = instance.plugins.filter { !$0.annexEnabled }

                        if !annexPlugins.isEmpty || instance.canvasByProject["__app__"] != nil {
                            ForEach(appLevelItems(for: instance)) { item in
                                NavigationLink(value: AnnexNav.plugin(item)) {
                                    PluginRow(name: item.name, icon: item.icon, enabled: true)
                                }
                            }
                            .listRowBackground(store.theme.surface0Color.opacity(0.4))
                        }

                        // Projects within this instance
                        ForEach(instance.projects) { project in
                            NavigationLink(value: AnnexNav.project(project, instance.id)) {
                                ProjectRowCompact(
                                    project: project,
                                    agentCount: instance.agents(for: project).count,
                                    runningCount: instance.agents(for: project).filter { $0.status == .running }.count,
                                    iconData: store.projectIcons[project.id]
                                )
                            }
                            .listRowBackground(store.theme.surface0Color.opacity(0.4))
                        }
                    } header: {
                        HStack {
                            Circle()
                                .fill(instance.connectionState.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(instance.serverName.isEmpty ? "Server" : instance.serverName)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(store.theme.baseColor)
            .navigationTitle("Annexes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddInstance = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: AnnexNav.self) { nav in
                switch nav {
                case .instanceConfig(let id):
                    if let instance = store.instanceByID(id) {
                        InstanceDetailView(instance: instance)
                    }
                case .project(let project, let instanceId):
                    ProjectExplorerView(project: project, instanceId: instanceId)
                case .plugin(let item):
                    PluginDetailView(item: item)
                }
            }
            .navigationDestination(for: DurableAgent.self) { agent in
                AgentDetailView(agent: agent)
            }
            .navigationDestination(for: String.self) { value in
                if value.hasPrefix("live:") {
                    let id = String(value.dropFirst(5))
                    LiveTerminalView(agentId: id)
                }
            }
            .sheet(isPresented: $showAddInstance) {
                NavigationStack {
                    PairingPlaceholderView(isAddingInstance: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showAddInstance = false }
                            }
                        }
                }
            }
            .overlay {
                if store.instances.isEmpty {
                    ContentUnavailableView(
                        "No Annexes",
                        systemImage: "desktopcomputer",
                        description: Text("Tap + to connect to a Clubhouse server.")
                    )
                }
            }
        }
    }

    private func appLevelItems(for instance: ServerInstance) -> [PluginItem] {
        var items: [PluginItem] = []
        // Home is always an app-level feature
        items.append(PluginItem(
            id: "\(instance.id.value):home",
            name: "Home",
            pluginId: "home",
            icon: "house",
            instanceId: instance.id,
            projectId: nil,
            enabled: true
        ))
        // App-level canvas
        if instance.canvasByProject["__app__"] != nil {
            items.append(PluginItem(
                id: "\(instance.id.value):canvas",
                name: "Canvas",
                pluginId: "canvas",
                icon: "rectangle.on.rectangle.angled",
                instanceId: instance.id,
                projectId: nil,
                enabled: true
            ))
        }
        return items
    }
}

// MARK: - Navigation

enum AnnexNav: Hashable {
    case instanceConfig(ServerInstanceID)
    case project(Project, ServerInstanceID)
    case plugin(PluginItem)
}

struct PluginItem: Identifiable, Hashable {
    let id: String
    let name: String
    let pluginId: String
    let icon: String
    let instanceId: ServerInstanceID
    let projectId: String?
    let enabled: Bool
}

// MARK: - Instance Header Row

private struct InstanceHeaderRow: View {
    let instance: ServerInstance

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(instance.serverName.isEmpty ? "Server" : instance.serverName)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(instance.projects.count) projects")
                    Text("\(instance.runningAgentCount) running")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Compact Project Row

private struct ProjectRowCompact: View {
    let project: Project
    let agentCount: Int
    let runningCount: Int
    let iconData: Data?

    var body: some View {
        HStack(spacing: 10) {
            ProjectIconView(name: project.name, displayName: project.displayName, iconData: iconData)
                .scaleEffect(0.8)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(agentCount) agents")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if runningCount > 0 {
                        HStack(spacing: 2) {
                            Circle().fill(.green).frame(width: 5, height: 5)
                            Text("\(runningCount)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Plugin Row

private struct PluginRow: View {
    let name: String
    let icon: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(width: 24)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(enabled ? .primary : .tertiary)
            if !enabled {
                Spacer()
                Text("Not Annex-enabled")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Plugin Detail (placeholder)

struct PluginDetailView: View {
    let item: PluginItem
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch item.pluginId {
            case "canvas":
                if let instance = store.instanceByID(item.instanceId),
                   let canvas = instance.canvasByProject[item.projectId ?? "__app__"] {
                    CanvasRendererView(canvas: canvas, theme: instance.theme)
                } else {
                    ContentUnavailableView("No Canvas", systemImage: "rectangle.on.rectangle.angled", description: Text("No canvas data available."))
                }
            default:
                ContentUnavailableView(item.name, systemImage: item.icon, description: Text("Plugin view coming soon."))
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return AnnexesTabView()
        .environment(store)
}
