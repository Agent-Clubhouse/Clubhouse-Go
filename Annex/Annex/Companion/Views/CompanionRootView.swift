import SwiftUI
import ClubhouseTransport

/// Tab bar on iPhone (Home, Dispatch, Needs you and Search), a sidebar on iPad.
/// Each tab keeps its own navigation stack; `store.selection` mirrors the agent on screen.
struct CompanionRootView: View {
    @Bindable var store: CompanionStore
    var preferences: CompanionPreferences
    var onPair: () -> Void
    var onSettings: () -> Void
    var isPreview = false
    var pairedHostIDs: Set<String>?
    @State private var navigation: CompanionNavigation
    private struct SpawnLaunch: Identifiable {
        let project: CompanionProjectTarget
        var hostID: String? = nil
        var id: CompanionProjectTarget { project }
    }
    @State private var spawnLaunch: SpawnLaunch?
    @State private var settingsTarget: CompanionTarget?
    @State private var detailsTarget: CompanionTarget?
    @State private var review: CompanionReviewLaunch?
    @State private var terminal: CompanionTerminalScope?
    @State private var decisionsLifetime: CompanionStateLifetime<CompanionDecisionQueue>
    private var decisions: CompanionDecisionQueue { decisionsLifetime.value }

    init(store: CompanionStore, preferences: CompanionPreferences, onPair: @escaping () -> Void, onSettings: @escaping () -> Void, isPreview: Bool = false, pairedHostIDs: Set<String>? = nil) {
        _store = Bindable(store)
        self.preferences = preferences
        self.onPair = onPair
        self.onSettings = onSettings
        self.isPreview = isPreview
        self.pairedHostIDs = pairedHostIDs
        var navigation = CompanionNavigation(lastTab: preferences.lastTab, cached: preferences.dispatcherDesktops,
                                             lastHostID: preferences.lastHostID, lastDispatcherHostID: preferences.lastDispatcherHostID)
        navigation.update(hosts: store.hosts)
        if let target = store.selection { navigation.open(target, hosts: store.hosts) }
        _navigation = State(initialValue: navigation)
        _decisionsLifetime = State(initialValue: CompanionStateLifetime { [store] in
            CompanionDecisionQueue { decision in
                await store.respond(decision.approval, option: decision.option, target: decision.target)
            }
        })
    }

    var body: some View {
        TabView(selection: Binding(get: { navigation.tab }, set: { navigation.select($0); mirrorSelection() })) {
            Tab("Home", systemImage: "house", value: CompanionTab.home) {
                stack(.home) {
                    CompanionHomeView(store: store, preferences: preferences, onPair: { navigation.interact(); onPair() }, onSettings: { navigation.interact(); onSettings() },
                                      onNewAgent: { target, hostID in navigation.interact(); spawnLaunch = .init(project: target, hostID: hostID) }, isPreview: isPreview,
                                      onInteraction: { navigation.interact() })
                }
            }
            if navigation.tabs.contains(.dispatcher) {
                Tab("Dispatch", systemImage: "point.3.connected.trianglepath.dotted", value: CompanionTab.dispatcher) {
                    stack(.dispatcher) { dispatcherRoot }
                }
                .badge(store.dispatcherNeedsYouCount + navigation.dispatcherReplies.unreadHostIDs.count)
            }
            Tab("Needs you", systemImage: "tray", value: CompanionTab.needsYou) {
                stack(.needsYou) { CompanionNeedsYouView(store: store, decisions: decisions) }
            }
            .badge(store.needsYouCount)
            Tab(value: CompanionTab.search, role: .search) {
                stack(.search) { CompanionSearchView(store: store, recentAgents: preferences.recentAgents, agentSort: preferences.projectSort) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .companionTheme(preferences.sharedTheme(hosts: store.hosts))
        .environment(\.companionHelperLabels, Dictionary(uniqueKeysWithValues: store.hosts.map { ($0.id, $0.helperRoutingLabels) }))
        .environment(\.companionOpenAgent) { target in open(target) }
        .environment(\.companionAgentSettings, .init(canOpen: { [store] in store.canEditSettings($0) }, open: { settingsTarget = $0 },
                                                      openDetails: { detailsTarget = $0 }))
        .environment(\.companionAgentWake, .init(choices: { [store] in store.mayWake($0) ? store.wakeChoices(for: $0) : [] },
                                                   wake: { [store] target, choice in Task { await store.wake(target, choice) } }))
        .environment(\.companionOpenReview) { review = $0 }
        .environment(\.companionTerminal, .init(availability: { [store] in store.terminalAvailability($0) }, open: { terminal = $0 }))
        .fullScreenCover(item: $terminal) { scope in
            CompanionTerminalScreenView(store: store, scope: scope)
                .companionTheme(preferences.theme(forHost: scope.hostID, hosts: store.hosts))
        }
        .fullScreenCover(item: $review) { launch in
            CompanionReviewView(store: store, launch: launch, theme: { [store, preferences] in preferences.theme(forHost: $0.hostID, hosts: store.hosts) }) { target in
                review = nil
                open(target)
            }
            .companionTheme(preferences.sharedTheme(hosts: store.hosts))
        }
        .sheet(item: $spawnLaunch) { launch in
            CompanionSpawnSheet(store: store, initialProject: launch.project, initialHostID: launch.hostID)
                .companionTheme(preferences.theme(forHost: launch.project.hostID, hosts: store.hosts))
        }
        .sheet(item: $settingsTarget) { target in
            CompanionAgentSettingsSheet(store: store, target: target)
                .companionTheme(preferences.theme(forHost: target.hostID, hosts: store.hosts))
        }
        .sheet(item: $detailsTarget) { target in
            CompanionAgentDetailsSheet(store: store, target: target)
                .companionTheme(preferences.theme(forHost: target.hostID, hosts: store.hosts))
        }
        .modifier(CompanionHelperStartAlerts(store: store))
        .task { store.start(); mirrorSelection() }
        .onChange(of: navigation.tab) { _, _ in mirrorSelection() }
        .onChange(of: navigation.visibleAgent) { _, _ in mirrorSelection() }
        .onChange(of: store.hosts, initial: true) { _, hosts in
            preferences.pruneAgentCollapse(hosts: hosts)
            preferences.pruneRecentAgents(hosts: hosts)
        }
        .onChange(of: store.selection) { _, target in
            AnnexTelemetry.shared.record(.navigation)
            // A selection made elsewhere (a newly started agent) opens in the current tab.
            guard let target, navigation.visibleAgent != target else { return }
            open(target)
        }
        .onChange(of: pairedHostIDs, initial: true) { _, ids in
            guard let ids else { return }
            navigation.retainPairedDesktops(ids)
            preferences.retainRecentAgents(on: ids)
            if preferences.dispatcherDesktops != nil { preferences.dispatcherDesktops = navigation.dispatcherDesktops }
            mirrorSelection()
        }
        .onChange(of: store.hosts) { previous, hosts in
            navigation.update(hosts: hosts)
            let removedHost = !Set(previous.map(\.id)).isSubset(of: Set(hosts.map(\.id)))
            if removedHost || hosts.contains(where: { $0.dispatcher != nil || $0.connection.canOperate }) {
                preferences.dispatcherDesktops = navigation.dispatcherDesktops
                if !hosts.isEmpty, preferences.lastDispatcherHostID != navigation.dispatcherHostID { preferences.lastDispatcherHostID = navigation.dispatcherHostID }
            }
            mirrorSelection()
        }
    }

    private func stack<Content: View>(_ which: CompanionTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { navigation.paths[which] ?? [] }, set: { path in
            navigation.setPath(path, for: which, hosts: store.hosts)
            guard which == navigation.tab || navigation.tab == .dispatcher else { return }
            mirrorSelection()
            if let hostID = path.last?.hostID { preferences.lastHostID = hostID }
        })) {
            content().navigationDestination(for: CompanionRoute.self) { route in
                switch route {
                case .agent(let target): destination(target)
                case .project(let project):
                    CompanionProjectPage(store: store, preferences: preferences, project: project, onNewAgent: { spawnLaunch = .init(project: $0) })
                        .companionTheme(preferences.theme(forHost: project.hostID, hosts: store.hosts))
                }
            }
        }
    }

    private func open(_ target: CompanionTarget) {
        navigation.open(target, hosts: store.hosts)
        mirrorSelection()
        preferences.lastHostID = target.hostID
    }

    private func mirrorSelection() {
        if preferences.lastTab != navigation.tab { preferences.lastTab = navigation.tab }
        let target = navigation.visibleAgent
        if let target, store.agent(for: target) != nil { preferences.recordOpenedAgent(target) }
        if store.selection != target { store.selection = target }
        if let hostID = target?.hostID, preferences.lastHostID != hostID { preferences.lastHostID = hostID }
    }

    /// Retain each desktop’s editor state; hidden conversations unmount their transcript content.
    /// The store’s per-target reading bookmark restores the visible transcript after tab or desktop switches.
    private var dispatcherRoot: some View {
        let cached = Dictionary(uniqueKeysWithValues: navigation.dispatcherDesktops.compactMap { desktop -> (String, CompanionDispatcherReplyCheckpoint)? in
            guard let target = desktop.target else { return nil }
            let conversation = store.conversation(for: target)
            guard conversation.isLoaded else { return nil }
            return (desktop.id, .init(target: target, conversation: conversation))
        })
        let followsLatest = navigation.dispatcherTarget.map { store.readingBookmark(for: $0).followsLatest } ?? true
        let isStreaming = navigation.dispatcherTarget.map { target in
            store.conversation(for: target).items.contains { item in
                if case .message(let message) = item { return message.role == .assistant && message.isStreaming }
                return false
            }
        } ?? false
        let visibleHostID = navigation.tab == .dispatcher && (navigation.paths[.dispatcher] ?? []).isEmpty ? navigation.dispatcherHostID : nil
        let conversations = ZStack {
            ForEach(navigation.dispatcherDesktops) { desktop in
                let visible = navigation.tab == .dispatcher && navigation.dispatcherHostID == desktop.id
                    && (navigation.paths[.dispatcher] ?? []).isEmpty
                VStack(spacing: 0) {
                    if let target = desktop.target, let agent = store.agent(for: target) {
                        conversation(agent, visible: visible).id(target)
                    } else if store.hosts.contains(where: { $0.id == desktop.id && $0.dispatcher?.mcpOff != nil }) {
                        CompanionDispatcherUnavailableView(store: store, hostID: desktop.id)
                    } else {
                        ProgressView("Loading the Dispatcher…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .opacity(navigation.dispatcherHostID == desktop.id ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(!visible)
            }
        }
        let switcher = CompanionDispatcherSwitcher(desktops: navigation.dispatcherDesktops, hosts: store.hosts,
            selectedHostID: navigation.dispatcherHostID, replies: navigation.dispatcherReplies.unreadHostIDs,
            isWorking: isStreaming || !followsLatest, select: { hostID in
                navigation.chooseDispatcher(hostID: hostID)
                preferences.lastHostID = hostID
                preferences.lastDispatcherHostID = hostID
                mirrorSelection()
            }) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatch-reports") {
                CompanionDispatcherPreviewReports(store: store, desktops: navigation.dispatcherDesktops, selectedHostID: navigation.dispatcherHostID)
            }
            #endif
            conversations
        }
        return switcher
        .navigationTitle(navigation.dispatcherTitle(hosts: store.hosts))
        .navigationBarTitleDisplayMode(.inline)
        .companionTelemetryScreen(.dispatcher)
        .onChange(of: cached, initial: true) { _, next in
            navigation.dispatcherReplies.update(next, visibleHostID: visibleHostID, followsLatest: followsLatest)
        }
        .onChange(of: visibleHostID) { _, next in
            navigation.dispatcherReplies.update(cached, visibleHostID: next, followsLatest: followsLatest)
        }
        .onChange(of: followsLatest) { _, next in
            navigation.dispatcherReplies.update(cached, visibleHostID: visibleHostID, followsLatest: next)
        }
        .onChange(of: navigation.dispatcherHostID, initial: true) { _, next in
            if let next { preferences.lastDispatcherHostID = next }
        }
    }

    private func conversation(_ agent: CompanionAgent, visible: Bool? = nil) -> some View {
        VStack(spacing: 0) {
            if isPreview { CompanionPreviewLabel().padding(6).frame(maxWidth: .infinity) }
            if agent.isDispatcher, let off = store.host(for: agent.id)?.dispatcher?.mcpOff {
                VStack(alignment: .leading, spacing: 6) {
                    Text(off.note)
                    if off.running && !off.allows("chat.send") {
                        Text("New messages are unavailable while MCP is off.").font(.caption)
                    }
                    CompanionSleepControl(store: store, target: agent.id, title: "Sleep")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("dispatcher-mcp-off-notice")
            }
            CompanionConversationView(store: store, agent: agent, showsActions: visible ?? true, isVisible: visible)
        }
        .companionTheme(preferences.theme(forHost: agent.id.hostID, hosts: store.hosts))
    }

    @ViewBuilder private func destination(_ target: CompanionTarget) -> some View {
        if let agent = store.agent(for: target) {
            conversation(agent)
            // The composer owns the bottom edge in a chat, as in Messages.
            .toolbar(.hidden, for: .tabBar)
            .id(target)
        } else if store.isAgentLoading(target), let host = store.host(for: target) {
            switch host.connection {
            case .offline, .failed:
                ContentUnavailableView(host.connection.label, systemImage: "wifi.exclamationmark",
                                       description: Text(host.connection.detail))
            case .connected:
                ProgressView("Loading agent…")
            default:
                ProgressView(host.connection.label)
            }
        } else if store.isDispatcher(target) {
            CompanionDispatcherUnavailableView(store: store, hostID: target.hostID)
        } else {
            ContentUnavailableView("Agent unavailable", systemImage: "sparkle",
                                   description: Text("This agent is no longer on its desktop."))
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

extension NavigationLink where Destination == Never {
    /// `NavigationLink(value: agent.id)` pushes the agent's chat route. More specific than SwiftUI's generic
    /// initializer, so every agent link picks it up.
    init(value: CompanionTarget, @ViewBuilder label: () -> Label) {
        self.init(value: CompanionRoute.agent(value), label: label)
    }
}

// MARK: - Home

/// Needs you across every desktop, then projects in the order you choose.
struct CompanionHomeView: View {
    @Bindable var store: CompanionStore
    @Bindable var preferences: CompanionPreferences
    var onPair: () -> Void
    var onSettings: () -> Void
    var onNewAgent: (CompanionProjectTarget, String?) -> Void
    var isPreview = false
    var onInteraction: () -> Void = {}
    @State private var arranging = false
    @State private var desktopSelection: CompanionDesktopSelection = .all
    @State private var expandedOfflineHosts: Set<String> = []
    @State private var observedConnectedAt: [String: Date] = [:]
    private struct ProjectAction: Identifiable {
        let project: CompanionProjectTarget
        let selection: CompanionDesktopSelection
        let action: CompanionProjectMachineAction
        var id: CompanionProjectTarget { project }
    }
    @State private var infoProject: CompanionProjectTarget?
    @State private var choosingProjectAction: ProjectAction?
    @State private var pendingProjectChoice: (CompanionProjectMachineAction, CompanionProjectTarget)?
    @State private var wakingProject: CompanionProjectTarget?
    @State private var pendingProjectWake: (target: CompanionTarget, message: String)?
    @State private var finishedActionError: String?
    /// The order rows were in when a scroll began. A changing Recent order waits until the list settles.
    @State private var hold: CompanionListHold?
    @Environment(\.companionPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionTerminal) private var terminal

    private var scope: CompanionHomeScope { .init(hosts: store.hosts, selectedHostID: desktopSelection.hostID) }
    private var scopedHosts: [CompanionHost] { scope.hosts }
    private var scopedAttention: [CompanionAttentionItem] { store.attentionItems().filter { scope.contains($0.agent.id) } }
    private var multipleHosts: Bool { scope.showsHostTags }
    /// Agents of an offline desktop drop out of the list instead of showing stale states.
    private func isListed(_ host: CompanionHost) -> Bool {
        switch host.connection { case .offline, .failed: false; default: true }
    }

    var body: some View {
        List {
            if !store.hosts.isEmpty {
                summary
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("home-summary")
                    .accessibilityAddTraits(.isHeader)
            }
            // Keep the scope owner mounted when the visible chip row disappears;
            // removing a selected desktop must restore All before filtering Home.
            CompanionDesktopChips(hosts: store.hosts, selection: $desktopSelection, onSelect: onInteraction)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if isPreview { CompanionPreviewLabel().listRowBackground(Color.clear) }
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("Pair a desktop", systemImage: "laptopcomputer")
                } description: {
                    Text("Open Clubhouse on your Mac, then go to Settings → Annex to pair this phone.")
                } actions: {
                    Button("Pair a desktop", action: onPair).buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(scopedHosts.filter { $0.canLinkProjects && $0.projectLinksError != nil }) { host in
                    Label(host.projectLinksError ?? "", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color(palette.warning))
                }
                ForEach(scopedHosts.filter(\.hasAppUpdateAffordance)) { host in
                    CompanionAppUpdateLink(store: store, host: presentationHost(host))
                }
                if CompanionConnectionNotice(hosts: scopedHosts).isVisible {
                    CompanionDesktopConnectionBanner(store: store, identifierPrefix: "home", presentationHosts: presentationHosts)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                needsYou
                dispatchers
                projects
                if let error = finishedActionError ?? store.finishedError {
                    Text(error).foregroundStyle(Color(palette.warning))
                        .accessibilityIdentifier("home-finished-error")
                }
            }
        }
        .companionListStyle()
        .companionTelemetryScreen(.home)
        .companionAgentRows(store: store, impliedHostID: scope.impliedHostID)
        .onChange(of: desktopSelection) { _, _ in hold = nil }
        .onAppear { observeConnectedHosts(store.hosts) }
        .onChange(of: store.hosts) { _, hosts in
            observeConnectedHosts(hosts)
            expandedOfflineHosts.formIntersection(Set(hosts.map(\.id)))
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { onInteraction() }
            if phase == .idle { withAnimation(reduceMotion ? nil : .snappy) { hold = nil } }
            else if hold == nil { hold = layout.hold }
        }
        .animation(reduceMotion ? nil : .snappy, value: layout.hold)
        .navigationTitle("Clubhouse")
        .alert("Couldn't change the project", isPresented: Binding(get: { store.projectStateError != nil }, set: { if !$0 { store.projectStateError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.projectStateError ?? "") }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
                    .companionToolbarSecondary()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New agent", systemImage: "plus") {
                    // Start in the project at the top of Home, not the desktop's first.
                    if let entry = (layout.projects + layout.idle).map(\.entry).first(where: \.canSpawn) { onNewAgent(entry.id, scope.selectedHostID) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .companionProminentLabel()
                .disabled(!scopedHosts.contains { $0.connection.canOperate && $0.canSpawn && !$0.projects.isEmpty })
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $arranging) {
            CompanionArrangeProjectsView(preferences: preferences, entries: orderedProjects)
        }
        .sheet(item: $infoProject) { target in
            CompanionProjectInfoSheet(store: store, project: target)
        }
        .sheet(item: $choosingProjectAction, onDismiss: completeProjectChoice) { launch in
            CompanionProjectMachineChooser(store: store, project: launch.project, selection: launch.selection,
                                           action: launch.action, screen: .home) { target in
                pendingProjectChoice = (launch.action, target)
                choosingProjectAction = nil
            }
        }
        .sheet(item: $wakingProject, onDismiss: completeProjectWake) { target in
            CompanionWakeSheet(store: store, project: target) { pendingProjectWake = ($0, $1) }
        }
    }

    private var presentationHosts: [CompanionHost] { scopedHosts.map(presentationHost) }

    private func presentationHost(_ host: CompanionHost) -> CompanionHost {
        guard store.hosts.count == 1 else { return host }
        var display = host
        display.name = "This desktop"
        return display
    }

    private func machineLabel(_ entry: CompanionProjectEntry, _ member: CompanionProjectMember) -> String {
        store.hosts.count == 1 ? member.project.name : entry.label(for: member)
    }

    /// The first scrolling content row: the native title slot cannot fit the full summary at XXXL.
    private var summary: Text {
        let counts = CompanionHomeSummary(hosts: scopedHosts, needsYou: scopedAttention.count)
        let connection = CompanionHomeSummary(hosts: store.hosts, needsYou: 0).connectionLabel
        let workingDot = Text("●").font(.caption2).foregroundColor(Color(palette.success))
        let attentionDot = Text("●").font(.caption2).foregroundColor(Color(palette.warning))
        let working = Text(counts.workingLabel).foregroundColor(Color(palette.secondaryLabel))
        let attention = Text(counts.attentionLabel).foregroundColor(Color(palette.secondaryLabel))
        let separator = dynamicTypeSize.isAccessibilitySize ? "\n" : " · "
        let status = Text("\(workingDot) \(working)\(separator)\(attentionDot) \(attention)")
        let text = connection.map {
            Text("\(status)\n\(Text($0).foregroundColor(Color(palette.secondaryLabel)))")
        } ?? status
        return text.font(.subheadline).accessibilityLabel(([counts.workingLabel, counts.attentionLabel] + [connection].compactMap { $0 }).joined(separator: ", "))
    }

    @ViewBuilder private var needsYou: some View {
        let items = scopedAttention
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
            HStack {
                Text("Needs you").font(.title3.bold()).foregroundStyle(Color(palette.label))
                Spacer()
                CompanionReviewButton(needsYouOnly: false)
            }
            .textCase(nil)
        }
    }

    private var listedEntries: [CompanionProjectEntry] { scope.projects(store.projectEntries).filter { scope.selectedHostID != nil || $0.members.contains { isListed($0.host) } } }

    /// Each listed desktop's Dispatcher while it's on: a pinned row above the projects, as on the desktop's sidebar.
    @ViewBuilder private var dispatchers: some View {
        let shown = scopedHosts.filter { isListed($0) && $0.dispatcher?.isVisible == true }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { host in
                    CompanionDispatcherRow(store: store, host: host, hostTag: multipleHosts ? host.name : nil)
                        .listRowBackground(CompanionCardBackground())
                }
            }
        }
    }

    private var orderedProjects: [CompanionProjectEntry] {
        preferences.projectSort == .recent
            ? CompanionHomeProjectActivity.ordered(listedEntries, recordedProjectActivity: projectActivity)
            : CompanionProjectOrdering.ordered(listedEntries, sort: preferences.projectSort,
                                                customOrder: preferences.projectOrder, lastActivity: projectActivity)
    }

    /// Recorded catalog/turn activity, or the last time the project was marked active here.
    /// Agent and chat activity, plus the project's own activity: the desktop's when it shares project state,
    /// otherwise the last time it was marked active here.
    private func projectActivity(_ target: CompanionProjectTarget) -> Date? {
        let marked = store.sharedProjectState(target).map(\.lastActivity) ?? preferences.projectActivity[CompanionProjectOrdering.key(target)]
        let agents = store.hosts.first { $0.id == target.hostID }?.projects.first { $0.id == target.projectID }?.agents ?? []
        // Recorded catalog/turn times are stable between reports; per-tool chat timestamps churn.
        return ([marked] + agents.flatMap { [$0.lastActivity, $0.turnStartedAt] })
            .compactMap { $0 }.filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()
    }

    private var layout: CompanionHomeLayout {
        CompanionHomeLayout.build(listedEntries, sort: preferences.projectSort, customOrder: preferences.projectOrder,
                                  rule: preferences.idleRule, hold: hold, shared: { store.sharedProjectState($0.id) },
                                  projectActivity: projectActivity, agentActivity: store.lastActivity(of:))
    }

    @ViewBuilder private var projects: some View {
        let layout = layout
        let parentLines = CompanionAgentTree.parentLines(hosts: store.hosts)
        Section {
        } header: {
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Projects").font(.title3.bold()).foregroundStyle(Color(palette.label))
                    projectSortMenu
                } else {
                    HStack {
                        Text("Projects").font(.title3.bold()).foregroundStyle(Color(palette.label))
                        Spacer()
                        projectSortMenu
                    }
                }
            }
            .textCase(nil)
        }
        ForEach(layout.projects) { group in projectSection(group, parentLines: parentLines) }
        if !layout.idle.isEmpty {
            Section {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { preferences.idleExpanded.toggle() }
                } label: {
                    CompanionFoldLabel(text: "\(layout.idle.count) idle project\(layout.idle.count == 1 ? "" : "s")", isOpen: preferences.idleExpanded)
                }
                .accessibilityIdentifier("idle-projects-fold")
                .listRowBackground(CompanionCardBackground())
            } footer: {
                if preferences.idleExpanded { EmptyView() } else {
                    Text(idleFooter(layout.idle))
                }
            }
            if preferences.idleExpanded { ForEach(layout.idle) { group in projectSection(group, parentLines: parentLines) } }
        }
    }

    private var projectSortMenu: some View {
        Menu {
            Picker("Sort projects", selection: $preferences.projectSort) {
                ForEach(CompanionProjectSort.allCases) { Text($0.label).tag($0) }
            }
            if preferences.projectSort == .custom {
                Button("Arrange projects…", systemImage: "line.3.horizontal") { arranging = true }
            }
        } label: {
            CompanionAccessoryLabel(title: preferences.projectSort.label, isMenu: true)
        }
        .accessibilityLabel("Sort projects, \(preferences.projectSort.label)")
        .accessibilityIdentifier("project-sort-menu")
    }

    private func projectSection(_ group: CompanionProjectGroup, parentLines: [CompanionTarget: String]) -> some View {
        let entry = group.entry
        let projectID = "\(entry.host.id)-\(entry.project.id)"
        return Section {
            if entry.isLinked {
                ForEach(entry.members) { member in
                    if member.host.connection.canOperate {
                        Text(machineLabel(entry, member))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(palette.secondaryLabel))
                            .accessibilityIdentifier("project-machine-\(member.host.id)-\(member.project.id)")
                            .listRowBackground(CompanionCardBackground())
                        projectRows(tree: CompanionAgentTree.build(member.project.agents.filter { !CompanionFinishedRuns.hasFinished($0) }, sort: preferences.projectSort,
                                                                   held: hold?.agents[entry.id], lastActivity: store.lastActivity(of:)),
                                    projectID: "\(member.host.id)-\(member.project.id)", target: member.id, parentLines: parentLines)
                            .companionAgentRows(store: store, impliedHostID: member.host.id)
                    } else {
                        offlineMember(entry, member)
                    }
                }
            } else if entry.host.connection.canOperate {
                projectRows(tree: group.tree, projectID: projectID, target: entry.id, parentLines: parentLines)
            } else {
                Text("Agents appear when this desktop reconnects.")
                    .foregroundStyle(Color(palette.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(CompanionCardBackground())
                    .accessibilityIdentifier("home-project-unavailable-\(projectID)")
            }
        } header: {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 6))
            headerLayout {
                HStack(spacing: 6) {
                    CompanionProjectBadge(project: entry.project)
                        .overlay(alignment: .bottomTrailing) {
                            if let state = CompanionHomeProjectActivity(entry: entry, recordedProjectActivity: projectActivity).status {
                                Circle().fill(Color(state.dot.color(in: palette))).frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                    projectLink(entry)
                    if group.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color(palette.secondaryLabel))
                            .accessibilityLabel("Pinned")
                    }
                }
                HStack(spacing: 6) {
                    if entry.isLinked {
                        let count = Set(entry.members.map(\.host.id)).count
                        Label("\(count)", systemImage: "desktopcomputer")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Color(palette.secondaryLabel))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(palette.fill), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("\(count) desktop\(count == 1 ? "" : "s")")
                    }
                    if multipleHosts && !entry.isLinked { CompanionHostTag(name: entry.host.name) }
                    Spacer(minLength: 0)
                    Button { onNewAgent(entry.id, scope.selectedHostID) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!entry.canSpawn)
                        .accessibilityLabel(entry.isLinked || !multipleHosts ? "New agent in \(entry.project.name)" : "New agent in \(entry.project.name) on \(entry.host.name)")
                }
            }
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
            .opacity(group.isIdle ? 0.7 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project-\(projectID)")
            .contextMenu { projectContextMenuItems(group) }
        }
    }

    private func observeConnectedHosts(_ hosts: [CompanionHost]) {
        let present = Set(hosts.map(\.id))
        observedConnectedAt = observedConnectedAt.filter { present.contains($0.key) }
        for host in hosts where host.connection.canOperate { observedConnectedAt[host.id] = Date() }
    }

    private func lastSeen(_ host: CompanionHost) -> Date? {
        // Presence is read-only context. Never infer desktop reachability from an agent's activity.
        let reported = store.hosts.flatMap { $0.dispatcherPresence?.remotes ?? [] }
            .filter { $0.machineId.caseInsensitiveCompare(host.id) == .orderedSame }
            .compactMap { remote in remote.lastSeen.flatMap {
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0))
                    ?? (try? Date.ISO8601FormatStyle().parse($0))
            } }
        return (reported + [observedConnectedAt[host.id]].compactMap { $0 })
            .filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()
    }

    @ViewBuilder private func offlineMember(_ entry: CompanionProjectEntry, _ member: CompanionProjectMember) -> some View {
        let expanded = expandedOfflineHosts.contains(member.host.id)
        let cached = member.project.agents.filter { !CompanionFinishedRuns.hasFinished($0) }
        let count: Int? = member.host.hasLoadedCatalog || !member.project.agents.isEmpty ? cached.count : nil
        let label = CompanionHomeOfflineMachineSummary(name: machineLabel(entry, member), lastSeen: lastSeen(member.host), agentCount: count).text
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                if expanded { expandedOfflineHosts.remove(member.host.id) }
                else { expandedOfflineHosts.insert(member.host.id) }
            }
        } label: {
            CompanionFoldLabel(text: label, isOpen: expanded)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("project-machine-\(member.host.id)-\(member.project.id)")
        .listRowBackground(CompanionCardBackground())
        if expanded {
            ForEach(cached) { agent in
                CompanionAgentListRow(agent: agent)
                    .companionAgentRows(store: store, impliedHostID: member.host.id)
                    .environment(\.companionAgentSettings, nil)
                    .environment(\.companionAgentWake, nil)
                    .environment(\.companionTerminal, nil)
                    .disabled(true).allowsHitTesting(false)
                    .opacity(0.5)
                    .accessibilityLabel("\(agent.name), cached on \(machineLabel(entry, member)), desktop not connected")
                    .accessibilityIdentifier("cached-agent-\(agent.id.hostID)-\(agent.id.projectID)-\(agent.id.agentID)")
                    .listRowBackground(CompanionCardBackground())
            }
        }
    }

    @ViewBuilder private func projectRows(tree: CompanionAgentTree, projectID: String, target: CompanionProjectTarget,
                                          parentLines: [CompanionTarget: String]) -> some View {
        let runs = store.finished(in: target)
        CompanionAgentTreeRows(tree: tree, rows: tree.active, preferences: preferences, parentLines: parentLines)
        CompanionAgentTreeQuietFold(projectID: projectID, tree: tree, preferences: preferences,
                                   parentLines: parentLines, finishedRuns: runs,
                                   onDismissFinished: dismissFinished,
                                   onClearFinished: { clearFinished(target) },
                                   canOpenFinished: { store.agent(for: $0) != nil })
        if tree.all.isEmpty && runs.isEmpty {
            Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                .listRowBackground(CompanionCardBackground())
        }
    }

    private func dismissFinished(_ run: CompanionFinishedRun) {
        finishedActionError = nil
        Task {
            await store.dismissFinished(run.target)
            finishedActionError = store.finishedError
        }
    }

    private func clearFinished(_ target: CompanionProjectTarget) {
        finishedActionError = nil
        Task {
            await store.clearFinished(in: target)
            finishedActionError = store.finishedError
        }
    }

    /// The idle window the folded projects use: their desktop's when it shares project state, else this phone's.
    private func idleFooter(_ idle: [CompanionProjectGroup]) -> String {
        let windows = Set(idle.map { group in
            store.sharedProjectState(group.id) != nil ? group.entry.host.idleDays : preferences.idleDays
        })
        guard windows.count == 1, let days = windows.first ?? nil else { return "No recent activity, or marked inactive." }
        return days > 0 ? "No activity for \(days) days, or marked inactive." : "Marked inactive."
    }

    /// Home shares Wake/Info with Project; linked state always follows the catalog's group contract.
    @ViewBuilder private func projectContextMenuItems(_ group: CompanionProjectGroup) -> some View {
        let entry = group.entry
        let catalogEntry = store.projectEntry(containing: entry.id) ?? entry
        CompanionProjectMenuItems(store: store, preferences: preferences, entry: catalogEntry,
            canWake: entry.members.contains { CompanionProjectMachineAction.wake.isAvailable($0, store: store, terminal: terminal) },
            onWake: { beginProjectAction(.wake, entry: entry) }, onInfo: { infoProject = entry.id })
        if let shared = store.linkedProjectState(catalogEntry) {
            Button(shared.pinned ? "Unpin project" : "Pin project", systemImage: shared.pinned ? "pin.slash" : "pin") {
                Task { await store.setLinkedProject(catalogEntry, pinned: !shared.pinned) }
            }
            .disabled(!store.canChangeLinkedProjectState(catalogEntry))
            if group.isIdle || shared.inactive {
                Button("Mark active", systemImage: "sun.max") {
                    Task { await store.setLinkedProject(catalogEntry, inactive: false) }
                }
                .disabled(!store.canChangeLinkedProjectState(catalogEntry))
            } else if !shared.pinned {
                Button("Mark inactive", systemImage: "moon.zzz") {
                    Task { await store.setLinkedProject(catalogEntry, inactive: true) }
                }
                .disabled(!store.canChangeLinkedProjectState(catalogEntry))
            }
            if let hint = store.linkedProjectStateConnectionHint(catalogEntry) { Text(hint) }
        } else if entry.isLinked {
            // Old hosts retain their per-copy state and days-idle rule.
            ForEach(entry.members) { member in
                let single = CompanionProjectEntry(host: member.host, project: member.project)
                let state = store.sharedProjectState(member.id)
                Menu(machineLabel(entry, member)) {
                    projectMenuItems(.init(entry: single,
                        isPinned: state?.pinned ?? preferences.pinnedProjects.contains(single.orderKey),
                        isIdle: state?.idle ?? preferences.idleRule.isIdle(single.orderKey,
                            running: member.host.connection.canOperate && member.project.agents.contains(where: CompanionHomeLayout.isAwake),
                            lastActivity: projectActivity(member.id), now: Date()), tree: group.tree))
                }
                .disabled(state != nil && !member.host.connection.canOperate)
            }
        } else if catalogEntry.isLinked { projectMenuItems(group) }
        if entry.members.contains(where: { terminal?.availability(.project($0.id)).isShown == true }) {
            Button("Terminal", systemImage: "terminal") {
                CompanionUIActions.record(.openProjectTerminal, on: .home)
                beginProjectAction(.terminal, entry: entry)
            }
            .disabled(!entry.members.contains { CompanionProjectMachineAction.terminal.isAvailable($0, store: store, terminal: terminal) })
        }
    }

    private func beginProjectAction(_ action: CompanionProjectMachineAction, entry: CompanionProjectEntry) {
        if entry.isLinked {
            choosingProjectAction = .init(project: entry.id, selection: desktopSelection, action: action)
        } else if let target = entry.members.first?.id { performProjectAction(action, on: target) }
    }

    private func completeProjectChoice() {
        guard let (action, target) = pendingProjectChoice else { return }
        pendingProjectChoice = nil
        performProjectAction(action, on: target)
    }

    private func performProjectAction(_ action: CompanionProjectMachineAction, on target: CompanionProjectTarget) {
        guard let member = store.projectEntry(containing: target)?.members.first(where: { $0.id == target }),
              action.isAvailable(member, store: store, terminal: terminal) else { return }
        switch action {
        case .terminal: terminal?.open(.project(target))
        case .wake: wakingProject = target
        }
    }

    private func completeProjectWake() {
        guard let wake = pendingProjectWake else { return }
        pendingProjectWake = nil
        Task { await store.wake(wake.target, message: wake.message) }
    }

    private func projectMenuItems(_ group: CompanionProjectGroup) -> some View {
        let key = group.entry.orderKey, project = group.id
        let shared = store.sharedProjectState(project)
        let isMarked = shared?.inactive ?? preferences.inactiveProjects.contains(key)
        func change(local: @escaping () -> Void, remote: @escaping () async -> Void) {
            if store.sharedProjectState(project) == nil { withAnimation(reduceMotion ? nil : .snappy) { local() } }
            else { Task { await remote() } }
        }
        return Group {
            Button(group.isPinned ? "Unpin project" : "Pin project", systemImage: group.isPinned ? "pin.slash" : "pin") {
                change(local: { preferences.togglePinned(key) }, remote: { await store.setProject(project, pinned: !group.isPinned) })
            }
            if group.isIdle || isMarked {
                Button("Mark active", systemImage: "sun.max") {
                    change(local: { preferences.markActive(key) }, remote: { await store.setProject(project, inactive: false) })
                }
            } else if !group.isPinned {
                Button("Mark inactive", systemImage: "moon.zzz") {
                    change(local: { preferences.markInactive(key) }, remote: { await store.setProject(project, inactive: true) })
                }
            }
        }
    }
}

/// A row that opens and closes a fold, with a turning chevron.
struct CompanionFoldLabel: View {
    let text: String
    let isOpen: Bool
    @Environment(\.companionPalette) private var palette
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
            Text(text)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(Color(palette.secondaryLabel))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(isOpen ? "Hides them" : "Shows them")
    }
}

extension CompanionHomeView {
    /// A project's name opens its page (#158).
    func projectLink(_ entry: CompanionProjectEntry) -> some View {
        NavigationLink(value: CompanionRoute.project(entry.id)) {
            HStack(spacing: 4) {
                Text(entry.project.name).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color(palette.secondaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(entry.project.name)")
        .accessibilityIdentifier("open-project-\(entry.host.id)-\(entry.project.id)")
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
                        Text(entry.machineNames).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() }.companionToolbarClose() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { preferences.setProjectOrder(order.map(\.orderKey)); dismiss() }
                        .labelStyle(.iconOnly).buttonStyle(.glassProminent).companionProminentLabel()
                }
            }
        }
    }
}

// MARK: - Dispatcher

/// The Dispatcher's pinned row: its status and latest activity, or a plain row while the desktop starts it.
struct CompanionDispatcherRow: View {
    @Bindable var store: CompanionStore
    let host: CompanionHost
    var hostTag: String?
    @Environment(\.companionOpenAgent) private var openAgent
    @Environment(\.companionPalette) private var palette

    var body: some View {
        if let agent = host.dispatcherAgent {
            Button { openAgent(agent.id) } label: {
                CompanionAgentListRow(agent: agent, hostTag: hostTag, detail: host.dispatcher?.statusNote ?? activity(agent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dispatcher-row-\(host.id)")
        } else {
            HStack(spacing: 12) {
                ProgressView().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(CompanionDispatcher.name).font(.body)
                        if let hostTag { CompanionHostTag(name: hostTag) }
                    }
                    Text("Loading the Dispatcher…").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dispatcher-row-pending-\(host.id)")
        }
    }

    /// "Asked Atlas to fix the build", or when it was last active.
    private func activity(_ agent: CompanionAgent) -> String? {
        if let message = agent.detail?.message, !message.isEmpty { return message }
        guard let date = store.lastActivity(of: agent) else { return nil }
        return date.formatted(.relative(presentation: .named))
    }
}

/// An open Dispatcher chat whose Dispatcher went: turned off on the desktop, or its desktop is offline.
struct CompanionDispatcherUnavailableView: View {
    @Bindable var store: CompanionStore
    let hostID: String

    var body: some View {
        let host = store.hosts.first { $0.id == hostID }
        if let host, host.connection.canOperate, let dispatcher = host.dispatcher, dispatcher.isLoading {
            ProgressView("Loading the Dispatcher…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let host, host.connection.canOperate, let dispatcher = host.dispatcher, !dispatcher.enabled {
            ContentUnavailableView {
                Label("The Dispatcher is off", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(dispatcher.turnOnBlocker ?? "It was turned off on \(host.name). Its folder and notes are kept, so turning it back on carries on where it left off.")
            } actions: {
                if dispatcher.turnOnBlocker == nil {
                    Button("Turn on Dispatcher") { Task { await store.setDispatcher(enabled: true, hostID: hostID) } }
                        .buttonStyle(.glassProminent).companionProminentLabel()
                        .disabled(store.dispatcherSwitching.contains(hostID))
                }
                if let error = store.dispatcherErrors[hostID] { Text(error).font(.footnote) }
            }
        } else {
            ContentUnavailableView {
                Label("Dispatcher unavailable", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("The desktop is offline. The Dispatcher shows again when it reconnects.")
            } actions: {
                Button("Retry") { Task { await store.reconnect(hostID: hostID) } }
            }
        }
    }
}

// MARK: - Needs you

struct CompanionDecisionNoticesView: View {
    @Bindable var store: CompanionStore
    let notices: [CompanionDecisionNotice]
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notices) { notice in
                HStack(alignment: .top) {
                    Label(notice.message, systemImage: "exclamationmark.circle")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss", systemImage: "xmark") { store.dismissDecisionNotice(notice) }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Dismiss \(notice.label) notice")
                }
                .padding().background(Color(palette.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("companion-not-sent-notice")
            }
        }
    }
}

/// Every approval, question and failure across desktops. Taps answer at once; a full swipe
/// right allows and left denies, held for three seconds so a stray swipe can be undone.
struct CompanionNeedsYouView: View {
    @Bindable var store: CompanionStore
    var decisions: CompanionDecisionQueue
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let items = store.attentionItems()
        let availability = CompanionAttentionAvailability(hosts: store.hosts)
        List {
            if dynamicTypeSize.isAccessibilitySize, let connectionSummary {
                Text(connectionSummary)
                    .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("needs-you-availability-summary")
                    .listRowBackground(Color.clear)
            }
            if !store.attentionDecisionNotices.isEmpty {
                Section {
                    CompanionDecisionNoticesView(store: store, notices: store.attentionDecisionNotices)
                }
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(availability.emptyTitle)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    } icon: { Image(systemName: availability.emptySystemImage) }
                } description: { Text(availability.emptyDetail) }
                .listRowBackground(Color.clear)
            }
            ForEach(store.attentionProjects(items)) { project in
                Section {
                    ForEach(project.items) { item in attentionRow(item) }
                } header: {
                    Text(project.name).textCase(nil)
                        .accessibilityIdentifier("needs-you-project-\(project.id.hostID)-\(project.id.projectID)")
                }
            }
            if CompanionConnectionNotice(hosts: store.hosts).isVisible {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        CompanionDesktopConnectionBanner(store: store, identifierPrefix: "needs-you")
                        Text(availability.unavailableHosts.count == 1 ? "Its requests show up when it reconnects." : "Their requests show up when they reconnect.")
                            .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text(availability.unavailableHosts.contains(where: \.isConnecting) ? "Unavailable desktops" : "Offline")
                }
            }
        }
        .companionListStyle()
        .navigationTitle("Needs you")
        .navigationSubtitle(subtitle(requestCount: items.count))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CompanionReviewButton(needsYouOnly: true) } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                ForEach(decisions.pending) { pending in
                    CompanionGlassBanner(systemImage: pending.allows ? "checkmark" : "xmark",
                                         text: Text("\(pending.allows ? "Allowing" : "Denying") \(CompanionAttentionItem.shortToolName(pending.approval.toolName)) for \(pending.agentName)")) {
                        Button("Undo") { decisions.undo(pending.id) }.buttonStyle(.glass)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .task(id: items.map(\.id)) {
            for item in items where !store.conversation(for: item.agent.id).isLoaded { await store.load(item.agent.id) }
        }
        .alert("Request no longer waiting", isPresented: Binding(get: { store.grantRequestNotice != nil }, set: { if !$0 { store.grantRequestNotice = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(store.grantRequestNotice ?? "") }
    }

    private var connectionSummary: String? {
        let unavailable = store.hosts.filter { !$0.connection.canOperate }
        if unavailable.count == 1 {
            let host = unavailable[0]
            return "\(host.name) \(host.connection.presentation().label.lowercased())"
        }
        return unavailable.isEmpty ? nil : "\(unavailable.count) desktops not connected"
    }

    private func subtitle(requestCount: Int) -> Text {
        let count = "\(requestCount) \(requestCount == 1 ? "request" : "requests")"
        // The native subtitle has one line at accessibility sizes. Availability
        // remains visible in the first scrolling row instead of a clipped line.
        let connection = dynamicTypeSize.isAccessibilitySize ? nil : connectionSummary
        return Text([count, connection].compactMap { $0 }.joined(separator: " · "))
            .foregroundColor(Color(palette.secondaryLabel))
    }

    private func attentionRow(_ item: CompanionAttentionItem) -> some View {
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

    private func swipeOption(_ item: CompanionAttentionItem, kind: CompanionApprovalOption.Kind) -> CompanionApprovalOption? {
        guard case .approval(let approval) = item.kind, !decisions.isPending(approval.id),
              store.canOperate(item.agent.id), item.agent.capabilities.contains(.approve) else { return nil }
        guard kind != .allowOnce || store.canApprove(approval, target: item.agent.id) else { return nil }
        return approval.options.first { $0.kind == kind }
    }

    private func schedule(_ item: CompanionAttentionItem, _ option: CompanionApprovalOption) {
        guard case .approval(let approval) = item.kind else { return }
        decisions.schedule(.init(approval: approval, option: option, target: item.agent.id, agentName: item.agent.name))
    }
}

/// How long an approval has before it times out. Within the last two minutes it turns red, and Needs you lists it first.
struct CompanionApprovalCountdown: View {
    let deadline: Date
    @Environment(\.companionPalette) private var palette
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = deadline.timeIntervalSince(context.date)
            let urgent = remaining <= CompanionAttentionItem.urgentWindow
            Label(Self.text(remaining: remaining), systemImage: urgent ? "exclamationmark.triangle.fill" : "clock")
                .font(.caption.weight(urgent ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(Color(urgent ? palette.error : palette.secondaryLabel))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.text(remaining: remaining))
                .accessibilityIdentifier("companion-approval-countdown")
        }
    }
    static func text(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Timed out" }
        let seconds = Int(remaining.rounded(.up))
        return seconds < 60 ? "Times out in \(seconds) s" : "Times out in \(Int((Double(seconds) / 60).rounded(.up))) min"
    }
}

struct CompanionAttentionCard: View {
    let item: CompanionAttentionItem
    @Bindable var store: CompanionStore
    var decisions: CompanionDecisionQueue
    var multipleHosts: Bool
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CompanionAgentAvatar(agent: item.agent, size: 26)
                Text(item.agent.name).font(.subheadline.weight(.semibold))
                if multipleHosts { CompanionHostTag(name: item.hostName) }
                Spacer()
            }
            Text(item.cardHeadline).font(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("attention-action-\(item.id)")
            if let prompt = item.cardSupportingText {
                Text(prompt).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
            }
            if item.cardToolName != nil || item.deadline != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let tool = item.cardToolName { Text(tool).accessibilityIdentifier("attention-tool-\(item.id)") }
                    if item.cardToolName != nil && item.deadline != nil { Text("·") }
                    if let deadline = item.deadline { CompanionApprovalCountdown(deadline: deadline) }
                }
                .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            }
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
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if let deny = approval.options.first(where: { $0.kind == .rejectOnce }) {
                    Button { Task { await store.respond(approval, option: deny, target: item.agent.id) } } label: {
                        Text(deny.label).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("attention-deny-\(item.id)")
                }
                if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
                    Button { Task { await store.respond(approval, option: allow, target: item.agent.id) } } label: {
                        Text(allow.label).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).companionProminentLabel()
                    .disabled(!store.canApprove(approval, target: item.agent.id))
                    .accessibilityIdentifier("attention-allow-\(item.id)")
                }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!canRespond || approval.resolution != .pending)
            if let reason = store.fullReviewReason(approval, target: item.agent.id) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                NavigationLink(value: item.agent.id) { Text("Review full request in chat") }
            }
        case .helperRequest(let request):
            CompanionHelperRequestActions(request: request, store: store)
        case .grantRequest(let request):
            CompanionGrantRequestActions(request: request, store: store)
        default:
            NavigationLink(value: item.agent.id) { Text(item.kind == .failure ? "Open chat" : "Answer in chat") }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// Approve and Decline for a helper start or dispose, with the desktop's rules: a dispose asks first, as the
/// desktop's dispose dialog does; one with work at risk is "Dispose anyway"; one that couldn't be checked can
/// only be declined.
struct CompanionHelperRequestActions: View {
    let request: CompanionHelperRequest
    @Bindable var store: CompanionStore
    @State private var confirmingDispose = false
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let busy = store.helperRequestsInFlight.contains(request.slot)
        let enabled = store.canAnswer(request)
        VStack(alignment: .leading, spacing: 8) {
            if let requested = request.requestedRouting {
                Text(requested.summary).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityIdentifier("helper-request-routing")
            }
            if let warning = request.startWarning {
                CompanionHelperWarningView(warning: warning, phase: "Warning when requested")
                    .accessibilityIdentifier("helper-request-warning")
            }
            if let note = Self.note(for: request) {
                Text(note).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("helper-request-note")
            }
            HStack(spacing: 8) {
                Button { Task { await store.answer(request, approve: false) } } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("helper-request-decline")
                if request.canApprove && (request.kind != .start || !store.isMCPReportOnly(request.agentTarget)) {
                    Button {
                        if request.kind == .dispose { confirmingDispose = true }
                        else { Task { await store.answer(request, approve: true) } }
                    } label: {
                        Text(busy ? "Sending…" : request.approveLabel).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).companionProminentLabel()
                    .tint(request.kind == .dispose ? Color(palette.error) : nil)
                    .accessibilityIdentifier("helper-request-approve")
                }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!enabled)
            if request.kind == .start, store.isMCPReportOnly(request.agentTarget) {
                Text(CompanionOrchestration.reportOnlyHelp).font(.caption)
            }
            if let error = store.helperRequestErrors[request.slot] {
                Text(error).font(.caption).foregroundStyle(Color(palette.error)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("helper-request-error")
            }
        }
        .confirmationDialog("Dispose of \(request.helperName)?", isPresented: $confirmingDispose, titleVisibility: .visible) {
            Button(request.approveLabel, role: .destructive) { Task { await store.answer(request, approve: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.confirmation(for: request))
        }
    }

    /// The desktop dispose dialog's notes.
    static func note(for request: CompanionHelperRequest) -> String? {
        guard request.kind == .dispose, let dispose = request.dispose else { return nil }
        if !dispose.canDispose {
            return dispose.checkError == nil
                ? "This phone can't see what disposing would lose. Decline, or answer on the desktop."
                : "Clubhouse can’t dispose of a helper it couldn’t check, even if you’re sure nothing would be lost."
        }
        if dispose.workAtRisk { return "Dispose anyway deletes this work. To keep it, commit and push from \(request.helperName) first." }
        return nil
    }

    /// The desktop dispose dialog's intro, and what disposing does.
    static func confirmation(for request: CompanionHelperRequest) -> String {
        let name = request.helperName
        let intro = request.dispose?.workAtRisk == true
            ? "\(request.requesterName) asked to dispose of \(name), but it has work that would be lost."
            : "\(request.requesterName) asked to dispose of \(name)."
        return "\(intro) This stops \(name), deletes its folder and its local branch. Anything already pushed stays on the remote."
    }
}

/// A Clubhouse permission request, as the desktop's Needs you shows it: the host's line for the call, its arguments
/// in full (Allow once covers exactly these), the agent's reason, what Allow does, and only the answers it takes.
struct CompanionGrantRequestActions: View {
    let request: CompanionGrantRequest
    @Bindable var store: CompanionStore
    var showsOpenChat = true
    @Environment(\.companionOpenAgent) private var openAgent
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let busy = store.grantRequestsInFlight.contains(request.slot)
        VStack(alignment: .leading, spacing: 8) {
            CompanionDecisionNoticesView(store: store, notices: store.decisionNotices(for: request))
            if let detail = request.detail {
                Text(detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("grant-request-detail")
            }
            if let arguments = request.arguments {
                Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color(palette.raisedCard), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Arguments: \(arguments)")
                    .accessibilityIdentifier("grant-request-arguments")
            }
            if let reason = request.reason {
                Text("“\(reason)”").font(.subheadline.italic()).foregroundStyle(Color(palette.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Reason: \(reason)")
                    .accessibilityIdentifier("grant-request-reason")
            }
            if let effect = request.allowEffect ?? (request.isAppUpdate ? CompanionAppUpdateText.restart : nil) {
                Text(effect).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("grant-request-effect")
            }
            if let update = request.update {
                Text(update.workingAgents.isEmpty ? "No working agents at the time of this request."
                     : "Working agents: " + update.workingAgents.map { "\($0.name) (\($0.agentId))" }.joined(separator: ", "))
                    .font(.subheadline).accessibilityIdentifier("app-update-working-agents")
                Text(CompanionAppUpdateText.platform).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { decisions(busy: busy) }
                VStack(spacing: 8) { decisions(busy: busy) }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!store.canAnswer(request))
            if let error = store.grantRequestErrors[request.slot] {
                Text(error).font(.caption).foregroundStyle(Color(palette.error)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("grant-request-error")
            }
            if showsOpenChat {
                Group {
                    if store.isDispatcher(request.agentTarget) {
                        // Switch tabs directly instead of pushing a route that immediately reroutes to the Dispatcher.
                        Button("Open chat") { openAgent(request.agentTarget) }
                    } else {
                        NavigationLink(value: request.agentTarget) { Text("Open chat") }
                    }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .accessibilityIdentifier("grant-request-open-chat")
            }
        }
    }

    @ViewBuilder private func decisions(busy: Bool) -> some View {
        if request.update != nil {
            if request.allowAnswer == .allowOnce {
                Button("Restart now") { Task { await store.answer(request, with: .allowOnce, updateMode: .now) } }
                    .buttonStyle(.borderedProminent).companionProminentLabel()
                    .accessibilityIdentifier("app-update-restart-now")
                Button("Restart when idle") { Task { await store.answer(request, with: .allowOnce, updateMode: .whenIdle) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("app-update-restart-when-idle")
            }
            if request.canDecline {
                Button("Cancel", role: .cancel) { Task { await store.answer(request, with: .decline) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("app-update-decline")
            }
        } else {
            if request.canDecline {
                Button { Task { await store.answer(request, with: .decline) } } label: {
                    Text("Decline").fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("grant-request-decline")
            }
            if let allow = request.allowAnswer {
                Button { Task { await store.answer(request, with: allow) } } label: {
                    Text(busy ? "Sending…" : allow.label).fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).companionProminentLabel()
                .accessibilityIdentifier("grant-request-allow")
            }
        }
    }
}

// MARK: - Search

/// Agent names and tasks, and projects, across every paired desktop. Offline desktops' results stay, dimmed.
struct CompanionSearchView: View {
    @Bindable var store: CompanionStore
    var recentAgents: [CompanionTarget] = []
    /// Projects' agents follow the Home sort.
    var agentSort: CompanionProjectSort = .recent
    @State private var query = ""
    @State private var filter: CompanionAgentFilter = .all
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let parentLines = CompanionAgentTree.parentLines(hosts: store.hosts, includingLocal: true)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = trimmed.isEmpty ? store.agentsNeedsYouFirst().filter { filter.matches($0.status) }
            : store.allAgents.filter { "\($0.name) \($0.subtitle)".localizedCaseInsensitiveContains(trimmed) }
        let recent = recentAgents.compactMap { store.agent(for: $0) }.filter { filter.matches($0.status) }
        let projects = trimmed.isEmpty ? [] : store.projectEntries.filter { $0.project.name.localizedCaseInsensitiveContains(trimmed) }
        List {
            if trimmed.isEmpty {
                Section {
                    CompanionChips(options: CompanionAgentFilter.allCases.map { value in
                        (value, value == .sleeping ? "Asleep" : value.label)
                    }, selection: $filter)
                    .accessibilityIdentifier("companion-search-filters")
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { agent in
                            agentRow(agent, parentLine: parentLines[agent.id], identifier: "search-recent-\(agent.id.hostID)-\(agent.id.agentID)")
                        }
                    }
                }
                if agents.isEmpty {
                    ContentUnavailableView("No agents", systemImage: "sparkles",
                                           description: Text(store.hosts.isEmpty ? "Pair a desktop to see its agents." : "No agents match this filter."))
                        .listRowBackground(Color.clear)
                }
            } else if agents.isEmpty && projects.isEmpty {
                ContentUnavailableView.search(text: trimmed).listRowBackground(Color.clear)
            }
            if !agents.isEmpty {
                Section(trimmed.isEmpty ? "All agents · \(agents.count)" : "Agents") {
                    ForEach(agents) { agent in
                        agentRow(agent, parentLine: parentLines[agent.id], identifier: "agent-\(agent.id.hostID)-\(agent.id.agentID)")
                    }
                }
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { entry in
                        NavigationLink {
                            CompanionProjectAgentsView(entry: entry, agents: CompanionAgentOrdering.ordered(entry.project.agents, sort: agentSort,
                                                                                                            lastActivity: store.lastActivity(of:)))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.project.name)
                                    Text("\(entry.project.agents.count) agents · \(entry.machineNames)").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
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

    private func agentRow(_ agent: CompanionAgent, parentLine: String?, identifier: String) -> some View {
        let host = store.host(for: agent.id)
        return NavigationLink(value: agent.id) {
            CompanionAgentListRow(agent: agent, hostTag: host?.connection.canOperate == false ? "Offline" : (store.hosts.count > 1 ? host?.name : nil),
                                  detail: store.projectName(for: agent.id), parentLine: parentLine)
        }
        .accessibilityIdentifier(identifier)
        .opacity(host?.connection.canOperate == false ? 0.5 : 1)
        .listRowBackground(CompanionCardBackground())
    }
}

struct CompanionProjectAgentsView: View {
    let entry: CompanionProjectEntry
    var agents: [CompanionAgent]
    var body: some View {
        List {
            ForEach(agents) { agent in
                NavigationLink(value: agent.id) {
                    CompanionAgentListRow(agent: agent, hostTag: entry.isLinked ? entry.members.first { $0.host.id == agent.id.hostID }?.host.name : nil)
                }
                    .listRowBackground(CompanionCardBackground())
            }
        }
        .companionListStyle()
        .navigationTitle(entry.project.name)
    }
}
