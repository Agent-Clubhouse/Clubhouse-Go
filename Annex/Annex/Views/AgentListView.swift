import SwiftUI

struct AgentListView: View {
    let project: Project
    @Environment(AppStore.self) private var store
    @State private var showSpawnSheet = false

    private var durableAgents: [DurableAgent] {
        store.agents(for: project)
    }

    private var quickAgents: [QuickAgent] {
        store.allQuickAgents(for: project)
    }

    var body: some View {
        List {
            if !durableAgents.isEmpty {
                Section("Agents") {
                    ForEach(durableAgents) { agent in
                        NavigationLink(value: agent) {
                            AgentRowView(agent: agent)
                        }
                        .listRowBackground(store.theme.surface0Color.opacity(0.5))
                    }
                }
            }

            if !quickAgents.isEmpty {
                Section("Quick Tasks") {
                    ForEach(quickAgents) { agent in
                        NavigationLink(value: agent) {
                            QuickAgentRowView(agent: agent)
                        }
                        .listRowBackground(store.theme.surface0Color.opacity(0.5))
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.removeQuickAgent(agentId: quickAgents[index].id)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
        .navigationTitle(project.label)
        .navigationDestination(for: DurableAgent.self) { agent in
            AgentDetailView(agent: agent)
        }
        .navigationDestination(for: QuickAgent.self) { agent in
            QuickAgentDetailView(agent: agent)
        }
        .navigationDestination(for: FileBrowserDestination.self) { dest in
            switch dest {
            case .directory(let projId, let projName, let dirPath, _):
                FileBrowserView(projectId: projId, projectName: projName, path: dirPath)
            case .file(let projId, let filePath, _):
                FileContentView(projectId: projId, path: filePath)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: FileBrowserDestination.directory(
                    projectId: project.id,
                    projectName: project.label,
                    path: ".",
                    name: project.label
                )) {
                    Label("Files", systemImage: "folder")
                }

                Button {
                    showSpawnSheet = true
                } label: {
                    Label("New Quick Agent", systemImage: "bolt.fill")
                }
            }
        }
        .sheet(isPresented: $showSpawnSheet) {
            SpawnQuickAgentSheet(
                projectId: project.id,
                parentAgentId: nil,
                orchestrators: store.orchestrators
            )
        }
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return NavigationStack {
        AgentListView(project: MockData.projects[0])
    }
    .environment(store)
}
