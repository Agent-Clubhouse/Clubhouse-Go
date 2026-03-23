import SwiftUI

struct InstancesView: View {
    @Environment(AppStore.self) private var store
    @State private var showAddInstance = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.instances) { instance in
                    NavigationLink(value: instance.id) {
                        InstanceRowView(instance: instance)
                    }
                    .listRowBackground(store.theme.surface0Color.opacity(0.5))
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.disconnect(instanceId: store.instances[index].id)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(store.theme.baseColor)
            .navigationTitle("Instances")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddInstance = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: ServerInstanceID.self) { instanceId in
                if let instance = store.instanceByID(instanceId) {
                    InstanceDetailView(instance: instance)
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
                        "No Instances",
                        systemImage: "desktopcomputer",
                        description: Text("Tap + to connect to a Clubhouse server.")
                    )
                }
            }
        }
    }
}

private struct InstanceRowView: View {
    let instance: ServerInstance
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(instance.connectionState.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: 2)
            }
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

            if instance.protocolConfig.isV2 {
                ChipView(text: "v2", bg: .green.opacity(0.15), fg: .green)
            }

            if instance.pendingPermissions.count > 0 {
                Text("\(instance.pendingPermissions.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.orange))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }
}

struct InstanceDetailView: View {
    let instance: ServerInstance
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Label("Connection", systemImage: "wifi")
                    Spacer()
                    Text(instance.connectionState.label)
                        .foregroundStyle(instance.connectionState.isConnected ? .green : .red)
                }
                HStack {
                    Label("Address", systemImage: "network")
                    Spacer()
                    Text("\(instance.protocolConfig.host):\(instance.protocolConfig.mainPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Theme", systemImage: "paintpalette")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(instance.theme.accentColor).frame(width: 10, height: 10)
                        Circle().fill(instance.theme.baseColor).frame(width: 10, height: 10)
                        Circle().fill(instance.theme.surface0Color).frame(width: 10, height: 10)
                    }
                }
            }

            Section("Projects (\(instance.projects.count))") {
                ForEach(instance.projects) { project in
                    NavigationLink(value: project) {
                        ProjectRowView(
                            project: project,
                            agentCount: instance.agents(for: project).count
                        )
                    }
                }
            }

            Section("All Agents (\(instance.totalAgentCount))") {
                ForEach(instance.allAgents) { agent in
                    NavigationLink(value: agent) {
                        AgentRowView(agent: agent)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    store.disconnect(instanceId: instance.id)
                } label: {
                    Label("Disconnect", systemImage: "wifi.slash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
        .navigationTitle(instance.serverName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Project.self) { project in
            AgentListView(project: project)
        }
        .navigationDestination(for: DurableAgent.self) { agent in
            AgentDetailView(agent: agent)
        }
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return InstancesView()
        .environment(store)
}
