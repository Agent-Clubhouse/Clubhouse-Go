import SwiftUI
import ClubhouseTransport

enum CompanionTab: Hashable { case home, needsYou, agents, search }

/// Tab bar on iPhone (Home, Needs you, Agents and the search tab), a sidebar on iPad.
/// Each tab keeps its own navigation stack; `store.selection` mirrors the agent on screen.
struct CompanionRootView: View {
    @Bindable var store: CompanionStore
    var preferences: CompanionPreferences
    var onPair: () -> Void
    var onSettings: () -> Void
    var isPreview = false
    @State private var tab: CompanionTab = .home
    @State private var paths: [CompanionTab: [CompanionTarget]] = [:]
    @State private var spawnProject: CompanionProjectTarget?
    @State private var decisions: CompanionDecisionQueue

    init(store: CompanionStore, preferences: CompanionPreferences, onPair: @escaping () -> Void, onSettings: @escaping () -> Void, isPreview: Bool = false) {
        _store = Bindable(store)
        self.preferences = preferences
        self.onPair = onPair
        self.onSettings = onSettings
        self.isPreview = isPreview
        _decisions = State(initialValue: CompanionDecisionQueue { [store] decision in
            await store.respond(decision.approval, option: decision.option, target: decision.target)
        })
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: CompanionTab.home) {
                stack(.home) {
                    CompanionHomeView(store: store, preferences: preferences, onPair: onPair, onSettings: onSettings,
                                      onNewAgent: { spawnProject = $0 }, isPreview: isPreview)
                }
            }
            Tab("Needs you", systemImage: "tray", value: CompanionTab.needsYou) {
                stack(.needsYou) { CompanionNeedsYouView(store: store, decisions: decisions) }
            }
            .badge(store.needsYouCount)
            Tab("Agents", systemImage: "sparkles", value: CompanionTab.agents) {
                stack(.agents) { CompanionAgentsView(store: store, onNewAgent: { spawnProject = $0 }) }
            }
            Tab(value: CompanionTab.search, role: .search) {
                stack(.search) { CompanionSearchView(store: store) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .companionTheme(preferences.sharedTheme(hosts: store.hosts))
        .environment(\.companionOpenAgent) { target in open(target) }
        .sheet(item: $spawnProject) { project in
            CompanionSpawnSheet(store: store, initialProject: project)
                .companionTheme(preferences.theme(forHost: project.hostID, hosts: store.hosts))
        }
        .task { store.start() }
        .onChange(of: tab) { _, current in store.selection = paths[current]?.last }
        .onChange(of: store.selection) { _, target in
            AnnexTelemetry.shared.record(.navigation)
            // A selection made elsewhere (a newly started agent) opens in the current tab.
            guard let target, paths[tab]?.last != target else { return }
            open(target)
        }
        .onChange(of: store.hosts.map(\.id)) { _, ids in
            for key in paths.keys { paths[key]?.removeAll { !ids.contains($0.hostID) } }
        }
    }

    private func stack<Content: View>(_ which: CompanionTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { paths[which] ?? [] }, set: { path in
            paths[which] = path
            guard which == tab else { return }
            store.selection = path.last
            if let hostID = path.last?.hostID { preferences.lastHostID = hostID }
        })) {
            content().navigationDestination(for: CompanionTarget.self) { destination($0) }
        }
    }

    private func open(_ target: CompanionTarget) {
        paths[tab] = [target]
        store.selection = target
        preferences.lastHostID = target.hostID
    }

    @ViewBuilder private func destination(_ target: CompanionTarget) -> some View {
        if let agent = store.agent(for: target) {
            VStack(spacing: 0) {
                if isPreview { CompanionPreviewLabel().padding(6).frame(maxWidth: .infinity) }
                CompanionConversationView(store: store, agent: agent)
            }
            .companionTheme(preferences.theme(forHost: target.hostID, hosts: store.hosts))
            // The composer owns the bottom edge in a chat, as in Messages.
            .toolbar(.hidden, for: .tabBar)
            .id(target)
        } else {
            ContentUnavailableView("Agent unavailable", systemImage: "sparkle",
                                   description: Text("This agent is no longer on its desktop, or the desktop is offline."))
        }
    }
}

struct CompanionPreviewLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Text(dynamicTypeSize.isAccessibilitySize ? "Preview" : "UI PREVIEW · NO DESKTOP CONNECTED")
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityLabel("UI preview. No desktop connected. Actions are disabled.")
    }
}

// MARK: - Home

/// Needs you across every desktop, then projects in the order you choose.
struct CompanionHomeView: View {
    @Bindable var store: CompanionStore
    @Bindable var preferences: CompanionPreferences
    var onPair: () -> Void
    var onSettings: () -> Void
    var onNewAgent: (CompanionProjectTarget) -> Void
    var isPreview = false
    @State private var arranging = false
    @Environment(\.companionPalette) private var palette

    private var multipleHosts: Bool { store.hosts.count > 1 }
    /// Agents of an offline desktop drop out of the list instead of showing stale states.
    private func isListed(_ host: CompanionHost) -> Bool {
        switch host.connection { case .offline, .failed: false; default: true }
    }

    var body: some View {
        List {
            if isPreview { CompanionPreviewLabel().listRowBackground(Color.clear) }
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("Pair a desktop", systemImage: "laptopcomputer")
                } description: {
                    Text("Open Clubhouse on your Mac, then go to Settings → Annex to pair this phone.")
                } actions: {
                    Button("Pair a desktop", action: onPair).buttonStyle(.glassProminent).controlSize(.large)
                }
                .listRowBackground(Color.clear)
            } else {
                summary
                ForEach(store.hosts.filter { !isListed($0) }) { host in offlineCard(host) }
                needsYou
                projects
            }
        }
        .companionListStyle()
        .navigationTitle("Clubhouse")
        .safeAreaInset(edge: .top) { reconnectingBanner }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New agent", systemImage: "plus") {
                    // Start in the project at the top of Home, not the desktop's first.
                    if let entry = orderedProjects.first(where: { $0.host.connection.canOperate && $0.host.canSpawn }) { onNewAgent(entry.id) }
                }
                .disabled(!store.hosts.contains { $0.connection.canOperate && $0.canSpawn && !$0.projects.isEmpty })
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $arranging) {
            CompanionArrangeProjectsView(preferences: preferences, entries: orderedProjects)
        }
    }

    private var summary: some View {
        let working = store.allAgents.filter { $0.status == .working }.count
        return HStack(spacing: 14) {
            Label("\(working) working", systemImage: "circle.fill").foregroundStyle(Color(palette.tint))
            Label("\(store.needsYouCount) need you", systemImage: "circle.fill").foregroundStyle(Color(palette.warning))
        }
        .labelStyle(CompanionDotLabelStyle())
        .font(.subheadline)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityElement(children: .combine)
    }

    private func offlineCard(_ host: CompanionHost) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash").foregroundStyle(Color(palette.secondaryLabel))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(host.name) is \(host.connection.label.lowercased())").font(.headline)
                    Text(host.connection.detail).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                }
                Spacer(minLength: 8)
                Button("Reconnect") { Task { await store.reconnect(hostID: host.id) } }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            .listRowBackground(CompanionCardBackground())
        }
    }

    @ViewBuilder private var reconnectingBanner: some View {
        if let host = store.hosts.first(where: { [.connecting, .reconnecting, .synchronizing].contains($0.connection) }) {
            CompanionGlassBanner(systemImage: "arrow.triangle.2.circlepath",
                                 text: Text("\(host.connection.label) · \(host.name)")) { EmptyView() }
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var needsYou: some View {
        let items = store.attentionItems()
        Section {
            if items.isEmpty {
                Label("Nothing needs you right now.", systemImage: "checkmark.circle")
                    .foregroundStyle(Color(palette.secondaryLabel))
                    .listRowBackground(CompanionCardBackground())
            }
            ForEach(items) { item in
                NavigationLink(value: item.agent.id) {
                    CompanionAgentListRow(agent: item.agent, hostTag: multipleHosts ? item.hostName : nil, detail: item.detail)
                }
                .accessibilityIdentifier("agent-\(item.agent.id.hostID)-\(item.agent.id.agentID)")
                .listRowBackground(CompanionCardBackground())
            }
        } header: {
            Text("Needs you").font(.title3.bold()).foregroundStyle(Color(palette.label)).textCase(nil)
        }
    }

    private var orderedProjects: [CompanionProjectEntry] {
        CompanionProjectOrdering.ordered(store.projectEntries.filter { isListed($0.host) }, sort: preferences.projectSort,
                                         customOrder: preferences.projectOrder, lastActivity: store.lastActivity(for:))
    }

    @ViewBuilder private var projects: some View {
        Section {
        } header: {
            HStack {
                Text("Projects").font(.title3.bold()).foregroundStyle(Color(palette.label))
                Spacer()
                Menu {
                    Picker("Sort projects", selection: $preferences.projectSort) {
                        ForEach(CompanionProjectSort.allCases) { Text($0.label).tag($0) }
                    }
                    if preferences.projectSort == .custom {
                        Button("Arrange projects…", systemImage: "line.3.horizontal") { arranging = true }
                    }
                } label: {
                    Label(preferences.projectSort.label, systemImage: "chevron.up.chevron.down")
                        .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Sort projects, \(preferences.projectSort.label)")
            }
            .textCase(nil)
        }
        ForEach(orderedProjects) { entry in
            Section {
                ForEach(entry.project.agents) { agent in
                    NavigationLink(value: agent.id) { CompanionAgentListRow(agent: agent) }
                        .accessibilityIdentifier("agent-\(agent.id.hostID)-\(agent.id.agentID)")
                        .listRowBackground(CompanionCardBackground())
                }
                if entry.project.agents.isEmpty {
                    Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                        .listRowBackground(CompanionCardBackground())
                }
            } header: {
                HStack(spacing: 6) {
                    Text(entry.project.name)
                    if multipleHosts { CompanionHostTag(name: entry.host.name) }
                    Spacer()
                    Button { onNewAgent(entry.id) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!entry.host.connection.canOperate || !entry.host.canSpawn)
                        .accessibilityLabel("New agent in \(entry.project.name) on \(entry.host.name)")
                }
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
            }
        }
    }
}

private struct CompanionDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

extension CompanionAttentionItem {
    /// One line saying what is being asked.
    var detail: String {
        switch kind {
        case .approval(let approval): approval.summary.isEmpty ? approval.toolName : approval.summary
        case .question(let question): question.prompts.first?.text ?? "Has a question"
        case .failure: agent.subtitle.isEmpty ? "Stopped with an error" : agent.subtitle
        case .unreviewed: agent.subtitle
        }
    }
}

/// Drag projects into your own order. The order is kept on this phone and covers every desktop.
struct CompanionArrangeProjectsView: View {
    @Bindable var preferences: CompanionPreferences
    @State private var order: [CompanionProjectEntry]
    @Environment(\.dismiss) private var dismiss

    init(preferences: CompanionPreferences, entries: [CompanionProjectEntry]) {
        self.preferences = preferences
        _order = State(initialValue: entries)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { entry in
                    HStack {
                        Text(entry.project.name)
                        Spacer()
                        Text(entry.host.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { preferences.setProjectOrder(order.map(\.orderKey)); dismiss() }
                }
            }
        }
    }
}

// MARK: - Needs you

/// Every approval, question and failure across desktops. Taps answer at once; a full swipe
/// right allows and left denies, held for three seconds so a stray swipe can be undone.
struct CompanionNeedsYouView: View {
    @Bindable var store: CompanionStore
    var decisions: CompanionDecisionQueue
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let items = store.attentionItems()
        List {
            if items.isEmpty {
                let working = store.allAgents.filter { $0.status == .working }.count
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text(working == 0 ? "Nothing is waiting on you." : "\(working) agents are working. They'll show up here when they need you."))
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                Section {
                    CompanionAttentionCard(item: item, store: store, decisions: decisions, multipleHosts: store.hosts.count > 1)
                        .listRowBackground(CompanionCardBackground())
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if let option = swipeOption(item, kind: .allowOnce) {
                                Button("Allow", systemImage: "checkmark") { schedule(item, option) }.tint(Color(palette.success))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let option = swipeOption(item, kind: .rejectOnce) {
                                Button("Deny", systemImage: "xmark") { schedule(item, option) }.tint(Color(palette.error))
                            }
                        }
                }
            }
        }
        .companionListStyle()
        .navigationTitle("Needs you")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                ForEach(decisions.pending) { pending in
                    CompanionGlassBanner(systemImage: pending.allows ? "checkmark" : "xmark",
                                         text: Text("\(pending.allows ? "Allowing" : "Denying") \(pending.approval.toolName) for \(pending.agentName)")) {
                        Button("Undo") { decisions.undo(pending.id) }.buttonStyle(.glass)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .task(id: items.map(\.id)) {
            for item in items where !store.conversation(for: item.agent.id).isLoaded { await store.load(item.agent.id) }
        }
    }

    private func swipeOption(_ item: CompanionAttentionItem, kind: CompanionApprovalOption.Kind) -> CompanionApprovalOption? {
        guard case .approval(let approval) = item.kind, !decisions.isPending(approval.id),
              store.canOperate(item.agent.id), item.agent.capabilities.contains(.approve) else { return nil }
        return approval.options.first { $0.kind == kind }
    }

    private func schedule(_ item: CompanionAttentionItem, _ option: CompanionApprovalOption) {
        guard case .approval(let approval) = item.kind else { return }
        decisions.schedule(.init(approval: approval, option: option, target: item.agent.id, agentName: item.agent.name))
    }
}

struct CompanionAttentionCard: View {
    let item: CompanionAttentionItem
    @Bindable var store: CompanionStore
    var decisions: CompanionDecisionQueue
    var multipleHosts: Bool
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CompanionAgentAvatar(agent: item.agent, size: 26)
                Text(item.agent.name).font(.subheadline.weight(.semibold))
                if multipleHosts { CompanionHostTag(name: item.hostName) }
                Spacer()
                CompanionStatusText(status: item.agent.status).font(.caption.weight(.medium))
            }
            Text(item.detail).font(.headline).fixedSize(horizontal: false, vertical: true)
            if case .approval(let approval) = item.kind, let detail = approval.detail, !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color(palette.raisedCard), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            actions
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        switch item.kind {
        case .approval(let approval) where decisions.isPending(approval.id):
            Label("Sending in a moment…", systemImage: "clock").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
        case .approval(let approval):
            let canRespond = store.canOperate(item.agent.id) && item.agent.capabilities.contains(.approve)
            HStack(spacing: 8) {
                if let deny = approval.options.first(where: { $0.kind == .rejectOnce }) {
                    Button { Task { await store.respond(approval, option: deny, target: item.agent.id) } } label: {
                        Text(deny.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
                    Button { Task { await store.respond(approval, option: allow, target: item.agent.id) } } label: {
                        Text(allow.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!canRespond || approval.resolution != .pending)
        default:
            NavigationLink(value: item.agent.id) { Text(item.kind == .failure ? "Open chat" : "Answer in chat") }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Agents

/// One flat list of every agent on every paired desktop.
struct CompanionAgentsView: View {
    @Bindable var store: CompanionStore
    var onNewAgent: (CompanionProjectTarget) -> Void
    @State private var filter: Filter = .all
    @Environment(\.companionPalette) private var palette

    typealias Filter = CompanionAgentFilter

    var body: some View {
        let agents = store.agentsNeedsYouFirst().filter { filter.matches($0.status) }
        let names = Dictionary(store.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        List {
            Section {
                CompanionChips(options: Filter.allCases.map { ($0, $0 == .needsYou && store.needsYouCount > 0 ? "Needs you · \(store.needsYouCount)" : $0.label) },
                               selection: $filter)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                ForEach(agents) { agent in
                    NavigationLink(value: agent.id) {
                        CompanionAgentListRow(agent: agent, hostTag: store.hosts.count > 1 ? names[agent.id.hostID] : nil,
                                              detail: store.host(for: agent.id)?.projects.first { $0.id == agent.id.projectID }?.name)
                    }
                    .accessibilityIdentifier("agent-\(agent.id.hostID)-\(agent.id.agentID)")
                    .listRowBackground(CompanionCardBackground())
                }
            }
            if agents.isEmpty {
                ContentUnavailableView("No agents", systemImage: "sparkles",
                                       description: Text(store.hosts.isEmpty ? "Pair a desktop to see its agents." : "No agents match this filter."))
                    .listRowBackground(Color.clear)
            }
        }
        .companionListStyle()
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New agent", systemImage: "plus") {
                    if let entry = store.projectEntries.first(where: { $0.host.connection.canOperate && $0.host.canSpawn }) { onNewAgent(entry.id) }
                }
                .disabled(!store.hosts.contains { $0.connection.canOperate && $0.canSpawn && !$0.projects.isEmpty })
            }
        }
    }
}

// MARK: - Search

/// Agent names and tasks, and projects, across every paired desktop. Offline desktops' results stay, dimmed.
struct CompanionSearchView: View {
    @Bindable var store: CompanionStore
    @State private var query = ""
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = trimmed.isEmpty ? [] : store.allAgents.filter { "\($0.name) \($0.subtitle)".localizedCaseInsensitiveContains(trimmed) }
        let projects = trimmed.isEmpty ? [] : store.projectEntries.filter { $0.project.name.localizedCaseInsensitiveContains(trimmed) }
        List {
            if trimmed.isEmpty {
                ContentUnavailableView("Search your agents", systemImage: "magnifyingglass",
                                       description: Text("Find agents by name or task, and projects, on every paired desktop."))
                    .listRowBackground(Color.clear)
            } else if agents.isEmpty && projects.isEmpty {
                ContentUnavailableView.search(text: trimmed).listRowBackground(Color.clear)
            }
            if !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { agent in
                        let host = store.host(for: agent.id)
                        NavigationLink(value: agent.id) {
                            CompanionAgentListRow(agent: agent, hostTag: host?.connection.canOperate == false ? "Offline" : (store.hosts.count > 1 ? host?.name : nil),
                                                  detail: host?.projects.first { $0.id == agent.id.projectID }?.name)
                        }
                        .opacity(host?.connection.canOperate == false ? 0.5 : 1)
                        .listRowBackground(CompanionCardBackground())
                    }
                }
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { entry in
                        NavigationLink {
                            CompanionProjectAgentsView(entry: entry)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.project.name)
                                    Text("\(entry.project.agents.count) agents · \(entry.host.name)").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                                }
                            } icon: { Image(systemName: "folder") }
                        }
                        .listRowBackground(CompanionCardBackground())
                    }
                }
            }
        }
        .companionListStyle()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Agents, tasks and projects")
    }
}

struct CompanionProjectAgentsView: View {
    let entry: CompanionProjectEntry
    var body: some View {
        List {
            ForEach(entry.project.agents) { agent in
                NavigationLink(value: agent.id) { CompanionAgentListRow(agent: agent) }
                    .listRowBackground(CompanionCardBackground())
            }
        }
        .companionListStyle()
        .navigationTitle(entry.project.name)
    }
}
