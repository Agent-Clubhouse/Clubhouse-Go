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
    /// nil preserves cached selection while authority is unknown. Only a known set,
    /// including a known empty set, may prune it; external launches also wait for readiness.
    var pairedHostIDs: Set<String>?
    var externalLaunchRestoreFailed: Bool
    var externalLaunchReady: Bool
    private struct DispatcherLaunchPrompt: Identifiable {
        let id: UUID
        let desktops: [CompanionDispatcherDesktop]
    }
    @State private var dispatcherLaunchPrompt: DispatcherLaunchPrompt?
    @State private var dispatcherLaunchChoice: String?
    @State private var externalLaunchDismissal = false
    @State private var dispatcherComposerFocus: CompanionDispatcherComposerFocus?
    @State private var navigationState: CompanionNavigation
    @StateObject private var homeScrollAnchor = CompanionHomeScrollAnchorState()
    /// Suspend at the navigation write itself, before departing List geometry can run.
    /// Native path bindings, tab selection, external opens and the hosted Root share this setter.
    private var navigation: CompanionNavigation {
        get { navigationState }
        nonmutating set {
            homeScrollAnchor.setPresented(newValue.tab == .home && (newValue.paths[.home] ?? []).isEmpty)
            navigationState = newValue
        }
    }
    private var navigationBinding: Binding<CompanionNavigation> {
        Binding(get: { navigation }, set: { navigation = $0 })
    }
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

    init(store: CompanionStore, preferences: CompanionPreferences, onPair: @escaping () -> Void, onSettings: @escaping () -> Void, isPreview: Bool = false, pairedHostIDs: Set<String>? = nil, externalLaunchReady: Bool = false, externalLaunchRestoreFailed: Bool = false) {
        _store = Bindable(store)
        self.preferences = preferences
        self.onPair = onPair
        self.onSettings = onSettings
        self.isPreview = isPreview
        self.pairedHostIDs = pairedHostIDs
        self.externalLaunchReady = externalLaunchReady
        self.externalLaunchRestoreFailed = externalLaunchRestoreFailed
        var navigation = CompanionNavigation(lastTab: preferences.lastTab, cached: preferences.dispatcherDesktops,
                                             lastHostID: preferences.lastHostID, lastDispatcherHostID: preferences.lastDispatcherHostID)
        navigation.update(hosts: store.hosts)
        if let target = store.selection { navigation.open(target, hosts: store.hosts) }
        _navigationState = State(initialValue: navigation)
        _decisionsLifetime = State(initialValue: CompanionStateLifetime { [store] in
            CompanionDecisionQueue { decision in
                await store.respond(decision.approval, option: decision.option, target: decision.target)
            }
        })
    }

    var body: some View {
        let _ = homeScrollAnchor.setPresented(navigation.tab == .home && (navigation.paths[.home] ?? []).isEmpty)
        TabView(selection: Binding(get: { navigation.tab }, set: {
            if let action = navigation.selectFromTabBar($0) {
                CompanionUIActions.record(action.control, on: action.screen)
            }
            mirrorSelection()
        })) {
            Tab("Home", systemImage: "house", value: CompanionTab.home) {
                stack(.home) {
                    CompanionHomeView(store: store, preferences: preferences, onPair: { navigation.interact(); onPair() }, onSettings: { navigation.interact(); CompanionUIActions.record(.openSettings, on: .home); onSettings() },
                                      onNewAgent: { target, hostID in navigation.interact(); spawnLaunch = .init(project: target, hostID: hostID) }, isPreview: isPreview,
                                      onInteraction: { navigation.interact() },
                                      isVisible: navigation.tab == .home,
                                      isPushed: !(navigation.paths[.home] ?? []).isEmpty, navigationAnchor: homeScrollAnchor)
                }
            }
            if navigation.tabs.contains(.dispatcher) {
                Tab("Dispatch", systemImage: "point.3.connected.trianglepath.dotted", value: CompanionTab.dispatcher) {
                    stack(.dispatcher) {
                        CompanionDispatcherRootBody { AnyView(dispatcherRoot) }
                    }
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
        .fullScreenCover(item: $terminal, onDismiss: resumeDispatcherLaunch) { scope in
            CompanionTerminalScreenView(store: store, scope: scope)
                .companionTheme(preferences.theme(forHost: scope.hostID, hosts: store.hosts))
        }
        .fullScreenCover(item: $review, onDismiss: resumeDispatcherLaunch) { launch in
            CompanionReviewView(store: store, launch: launch, theme: { [store, preferences] in preferences.theme(forHost: $0.hostID, hosts: store.hosts) }) { target in
                review = nil
                open(target)
            }
            .companionTheme(preferences.sharedTheme(hosts: store.hosts))
        }
        .sheet(item: $spawnLaunch, onDismiss: resumeDispatcherLaunch) { launch in
            CompanionSpawnSheet(store: store, initialProject: launch.project, initialHostID: launch.hostID)
                .companionTheme(preferences.theme(forHost: launch.project.hostID, hosts: store.hosts))
        }
        .sheet(item: $settingsTarget, onDismiss: resumeDispatcherLaunch) { target in
            CompanionAgentSettingsSheet(store: store, target: target)
                .companionTheme(preferences.theme(forHost: target.hostID, hosts: store.hosts))
        }
        .sheet(item: $detailsTarget, onDismiss: resumeDispatcherLaunch) { target in
            CompanionAgentDetailsSheet(store: store, target: target)
                .companionTheme(preferences.theme(forHost: target.hostID, hosts: store.hosts))
        }
        .sheet(item: $dispatcherLaunchPrompt, onDismiss: {
            if let hostID = dispatcherLaunchChoice {
                dispatcherLaunchChoice = nil
                openExternalDispatcher(hostID)
            }
            handleDispatcherLaunch()
        }) { prompt in
            CompanionDispatcherLaunchSheet(desktops: prompt.desktops) { hostID in
                dispatcherLaunchChoice = hostID
                dispatcherLaunchPrompt = nil
                CompanionUIActions.record(.selectDesktop, on: .dispatcher)
            }
            .companionTheme(preferences.sharedTheme(hosts: store.hosts))
        }
        .onChange(of: CompanionDispatcherLaunchInbox.shared.pending, initial: true) { _, _ in handleDispatcherLaunch() }
        .onChange(of: externalLaunchReady) { _, _ in handleDispatcherLaunch() }
        .onChange(of: navigation.dispatcherDesktops) { _, _ in handleDispatcherLaunch() }
        #if DEBUG
        .onAppear { CompanionHomeBuildProbe.navigation?(navigationBinding) }
        #endif
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
            handleDispatcherLaunch()
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
            handleDispatcherLaunch()
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

    private var launchPairedIDs: Set<String>? {
        pairedHostIDs ?? (isPreview ? Set(store.hosts.map(\.id)) : nil)
    }

    private func handleDispatcherLaunch() {
        guard let request = CompanionDispatcherLaunchInbox.shared.pending,
              dispatcherLaunchPrompt == nil, !externalLaunchDismissal else { return }
        let result = navigation.resolveDispatcherLaunch(pairedHostIDs: launchPairedIDs,
            restorationComplete: externalLaunchReady, restorationFailed: externalLaunchRestoreFailed, hosts: store.hosts)
        // Retain the handoff until the active presentation's onDismiss. Setting another
        // sheet immediately would consume a request behind an already-presented controller.
        guard result != .waiting else { return }
        if spawnLaunch != nil || settingsTarget != nil || detailsTarget != nil || review != nil || terminal != nil {
            externalLaunchDismissal = true
            clearExternalLaunchPresentations()
            return
        }
        switch result {
        case .waiting: return
        case .open(let desktop): openExternalDispatcher(desktop.id)
        case .choose(let desktops): dispatcherLaunchPrompt = .init(id: request.id, desktops: desktops)
        case .unavailable: dispatcherLaunchPrompt = .init(id: request.id, desktops: [])
        }
        CompanionUIActions.record(.messageDispatcher, on: .dispatcher)
        CompanionDispatcherLaunchInbox.shared.consume(request.id)
    }

    private func resumeDispatcherLaunch() {
        externalLaunchDismissal = false
        handleDispatcherLaunch()
    }

    private func clearExternalLaunchPresentations() {
        spawnLaunch = nil; settingsTarget = nil; detailsTarget = nil; review = nil; terminal = nil
    }

    private func openExternalDispatcher(_ hostID: String) {
        // Revalidate after chooser dismissal: forgotten or withdrawn targets cannot be opened.
        guard launchPairedIDs?.contains(hostID) == true,
              let desktop = navigation.dispatcherDesktops.first(where: { $0.id == hostID }),
              let target = desktop.target else { return }
        clearExternalLaunchPresentations()
        navigation.chooseDispatcher(hostID: hostID)
        navigation.select(.dispatcher)
        preferences.lastDispatcherHostID = hostID
        preferences.lastHostID = hostID
        mirrorSelection()
        dispatcherComposerFocus = .init(id: UUID(), target: target)
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
                        conversation(agent, visible: visible)
                            .environment(\.companionDispatcherFocus, .init(request: visible ? dispatcherComposerFocus : nil, handled: { id in
                                if dispatcherComposerFocus?.id == id { dispatcherComposerFocus = nil }
                            }))
                            .id(target)
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
            isWorking: CompanionDispatcherTurn.inTurn(agent: navigation.dispatcherTarget.flatMap { store.agent(for: $0) }, isStreaming: isStreaming),
            isLive: CompanionDispatcherTurn.isLive(navigation.dispatcherTarget.flatMap { store.host(for: $0) }?.connection), select: { hostID in
                navigation.chooseDispatcher(hostID: hostID)
                preferences.lastHostID = hostID
                preferences.lastDispatcherHostID = hostID
                mirrorSelection()
            }, openSettings: { navigation.interact(); CompanionUIActions.record(.openSettings, on: .dispatcher); onSettings() }) {
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

/// Dispatcher transcript/reply observations belong to this child, not the Root that
/// constructs Home. No state owner or alternate navigation path is introduced.
private struct CompanionDispatcherRootBody: View {
    let content: @MainActor () -> AnyView
    var body: AnyView { content() }
}

/// Needs you across every desktop, then projects in the order you choose.
struct CompanionHomeView: View {
    @Bindable var store: CompanionStore
    @Bindable var preferences: CompanionPreferences
    var onPair: () -> Void
    var onSettings: () -> Void
    var onNewAgent: (CompanionProjectTarget, String?) -> Void
    var isPreview = false
    var onInteraction: () -> Void = {}
    var isVisible = true
    var isPushed = false
    /// Root owns navigation-time suspension. Direct Home callers keep a lazy local owner.
    var navigationAnchor: CompanionHomeScrollAnchorState? = nil
    #if DEBUG
    var hostedProjectMenu: ((CompanionLinkedProjectStateMenuItems) -> Void)? = nil
    #endif
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
    /// Recent peers keep their order for the entire Home tab session, including pushed routes.
    @State private var hold: CompanionListHold?
    @State private var heldScope: CompanionDesktopSelection = .all
    @State private var heldSort: CompanionProjectSort = .recent
    @State private var holdGeneration: UInt64 = 0
    @State private var homeScrollPosition = ScrollPosition()
    @StateObject private var localScrollAnchor = CompanionHomeScrollAnchorState()
    private var scrollAnchor: CompanionHomeScrollAnchorState { navigationAnchor ?? localScrollAnchor }
    @StateObject private var renderSession = CompanionHomeRenderSession()
    // Lazy List closures can retain earlier Home value copies. All copies consult the same
    // non-observable session so none can fall back to live Store reads during a push.
    fileprivate var display: CompanionHomeRenderSnapshot? { renderSession.snapshot }
    private var frozenInputs: CompanionHomeRenderSnapshot? { display }
    private var frozenActions: CompanionHomeFrozenActions? { renderSession.actions }
    /// Set on the value copy handed to Content. The owner alone may use live fallbacks.
    var contentValues: CompanionHomeContentValues? = nil
    @State private var arrangingEntries: [CompanionProjectEntry] = []
    @Environment(\.companionPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionTerminal) private var terminal
    @Environment(\.companionAgentSettings) private var agentSettings
    @Environment(\.companionAgentWake) private var agentWake
    @Environment(\.companionOpenAgent) private var openAgent
    @Environment(\.companionOpenReview) private var openReview
    @Environment(\.scenePhase) private var scenePhase

    private var renderHosts: [CompanionHost] { display?.hosts ?? contentValues?.hosts ?? store.hosts }
    private var renderEntries: [CompanionProjectEntry] { display?.entries ?? contentValues?.entries ?? store.projectEntries }
    private func renderFinished(_ target: CompanionProjectTarget) -> [CompanionFinishedRun] {
        if let display { return display.finished[target] ?? [] }
        if let contentValues { return contentValues.finished[target] ?? [] }
        return store.finished(in: target)
    }
    private func renderState(_ target: CompanionProjectTarget) -> CompanionProjectState? {
        if let display { return display.states[target]?.state }
        if let contentValues { return contentValues.states[target]?.state }
        return store.sharedProjectState(target)
    }
    private func renderLinked(_ entry: CompanionProjectEntry) -> CompanionProjectState? {
        if let display { return display.linkedStates[entry.orderKey]?.state }
        if let contentValues { return contentValues.linkedStates[entry.orderKey]?.state }
        return store.linkedProjectState(entry)
    }
    private func renderHasAgent(_ target: CompanionTarget) -> Bool {
        if let display { return display.agents.contains(target) }
        if let contentValues { return contentValues.hosts.contains { $0.allAgents.contains { $0.id == target } } }
        return store.agent(for: target) != nil
    }

    private var scope: CompanionHomeScope {
        #if DEBUG
        CompanionHomeBuildProbe.record?(.scope)
        #endif
        return .init(hosts: renderHosts, selectedHostID: desktopSelection.hostID)
    }
    private var scopedHosts: [CompanionHost] { scope.hosts }
    private var scopedAttention: [CompanionAttentionItem] {
        #if DEBUG
        CompanionHomeBuildProbe.record?(.attention)
        #endif
        return (display?.attention ?? contentValues?.attention ?? store.homeAttentionItems()).filter { scope.contains($0.agent.id) }
    }
    private var multipleHosts: Bool { scope.showsHostTags }
    /// Agents of an offline desktop drop out of the list instead of showing stale states.
    private func isListed(_ host: CompanionHost) -> Bool {
        switch host.connection { case .offline, .failed: false; default: true }
    }

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.record?(.owner)
        #endif
        // Suspend before departing geometry can replace the visible bookmark.
        let _ = navigationAnchor == nil ? scrollAnchor.setPresented(isVisible && !isPushed) : ()
        // Freeze synchronously before constructing any pushed List content; no onChange gap.
        let _ = renderSession.prepare(visible: isVisible, pushed: isPushed) {
            let snapshot = makeFrozenInputs()
            let live = CompanionHomeFrozenActions(settings: agentSettings, wake: agentWake, terminal: terminal,
                                                  openAgent: openAgent, openReview: openReview)
            return (snapshot, live.capturingDisplay(snapshot, store: store))
        }
        // A concrete owner keeps pending Home sheets alive across content removal.
        VStack(spacing: 0) {
            if isVisible {
                visibleContent
                    // Environment readers belong ABOVE the equality boundary. They cannot leave
                    // live Store dependencies registered on the frozen content or its rows.
                    .modifier(CompanionHomeRowInputs(store: store, snapshot: isPushed ? frozenInputs : nil,
                        impliedHostID: isPushed ? frozenInputs?.rowContext.impliedHostID : scope.impliedHostID,
                        actions: isPushed ? frozenActions : nil))
                    .tint(Color((isPushed ? frozenInputs?.palette : nil)?.tint ?? palette.tint))
                    .foregroundStyle(Color((isPushed ? frozenInputs?.palette : nil)?.label ?? palette.label))
            }
            else { Color.clear }
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            if !visible { hold = nil; holdGeneration &+= 1 }
            #if DEBUG
            CompanionHomeBuildProbe.visibility?(visible)
            #endif
        }
        .onChange(of: isPushed, initial: true) { wasPushed, pushed in
            // Project pages already expose this inline; Back must not replay it as a Home alert.
            if wasPushed && !pushed { store.projectStateError = nil }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { hold = nil; holdGeneration &+= 1 }
            #if DEBUG
            CompanionHomeBuildProbe.phase?(phase)
            #endif
        }
        .onChange(of: desktopSelection) { _, _ in hold = nil; holdGeneration &+= 1; scrollAnchor.reset() }
        .onChange(of: preferences.projectSort) { _, _ in hold = nil; holdGeneration &+= 1 }
        .navigationTitle("Clubhouse")
        .alert("Couldn't change the project", isPresented: Binding(get: { isVisible && !isPushed && frozenInputs == nil && store.projectStateError != nil }, set: { if !$0 { store.projectStateError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.projectStateError ?? "") }
        .toolbar { homeToolbar }
        .sheet(isPresented: $arranging) {
            CompanionArrangeProjectsView(preferences: preferences, entries: arrangingEntries)
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

    private var visibleContent: some View {
        let currentLayout = layout
        var contentHome = self
        contentHome.contentValues = makeContentValues(layout: currentLayout)
        return CompanionHomeContent(home: contentHome, layout: currentLayout).equatable()
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape", action: onSettings).companionToolbarSecondary()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New agent", systemImage: "plus") {
                // Existing launch semantics; no unrelated action-authority changes in this PR.
                let current = layout
                if let entry = (current.projects + current.idle).map(\.entry).first(where: \.canSpawn) {
                    onNewAgent(entry.id, scope.selectedHostID)
                }
            }
            .labelStyle(.iconOnly).buttonStyle(.glassProminent).buttonBorderShape(.circle)
            .companionProminentLabel()
            .disabled(!isVisible || isPushed || !scopedHosts.contains { $0.connection.canOperate && $0.canSpawn && !$0.projects.isEmpty })
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // Evaluate the live projection in the owner, not under the content observation scope.
    // A pushed content body must not retain the live conversation-activity subscription.
    fileprivate func content(_ layout: CompanionHomeLayout) -> some View {
        let renderedScope = desktopSelection, renderedSort = preferences.projectSort
        let renderedGeneration = holdGeneration
        #if DEBUG
        let _ = CompanionHomeBuildProbe.record?(.content)
        let _ = CompanionHomeBuildProbe.renderedSort?(renderedSort)
        let _ = CompanionHomeBuildProbe.projection?(layout)
        let _ = CompanionHomeBuildProbe.frozen?(display != nil)
        let _ = CompanionHomeBuildProbe.frame?(display != nil, CompanionConnectionNotice(hosts: presentationHosts).title)
        #endif
        return ScrollViewReader { proxy in
        List {
            if !renderHosts.isEmpty {
                summary
                    .companionHomeAnchor(.summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("home-summary")
                    .accessibilityAddTraits(.isHeader)
            }
            // Keep the scope owner mounted when the visible chip row disappears;
            // removing a selected desktop must restore All before filtering Home.
            CompanionDesktopChips(hosts: renderHosts, selection: $desktopSelection, onSelect: onInteraction)
                .companionHomeAnchor(.desktops)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if isPreview { CompanionPreviewLabel().listRowBackground(Color.clear) }
            if renderHosts.isEmpty {
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
                    CompanionDesktopConnectionBanner(store: store, identifierPrefix: "home", presentationHosts: presentationHosts, capturedHosts: display?.hosts ?? contentValues?.hosts)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                needsYou
                dispatchers
                projects(layout)
                if let error = finishedActionError ?? (display != nil ? display?.finishedError : contentValues?.finishedError) {
                    Text(error).foregroundStyle(Color(palette.warning))
                        .accessibilityIdentifier("home-finished-error")
                }
            }
        }
        .companionListStyle()
        .companionTelemetryScreen(.home)
        .environment(\.companionHomeScrollAnchor, scrollAnchor)
        #if DEBUG
        .environment(\.companionHomeBuildCounting, true)
        #endif
        .onChange(of: layout.hold, initial: true) { _, current in
            if !isPushed && scenePhase == .active && preferences.projectSort == .recent { setHold(current, scope: renderedScope, sort: renderedSort, generation: renderedGeneration) }
        }
        .onChange(of: !isPushed && scenePhase == .active && hold == nil, initial: true) { _, needsSnapshot in
            if needsSnapshot && preferences.projectSort == .recent { setHold(layout.hold, scope: renderedScope, sort: renderedSort, generation: renderedGeneration) }
        }
        .scrollPosition($homeScrollPosition)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            scrollAnchor.setGeometry(geometry)
            if !isPushed { scrollAnchor.resume(proxy, position: $homeScrollPosition) { anchorAvailable($0, layout: layout) } }
        }
        .onChange(of: isPushed) { _, pushed in
            if !pushed { scrollAnchor.resume(proxy, position: $homeScrollPosition) { anchorAvailable($0, layout: layout) } }
        }
        .onAppear {
            observeConnectedHosts(renderHosts)
            expandedOfflineHosts.formIntersection(Set(renderHosts.map(\.id)))
        }
        .onAppear {
            #if DEBUG
            CompanionHomeBuildProbe.state?(scrollAnchor, $desktopSelection)
            #endif
        }
        .onChange(of: renderHosts) { _, hosts in
            observeConnectedHosts(hosts)
            expandedOfflineHosts.formIntersection(Set(hosts.map(\.id)))
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { scrollAnchor.cancelRestoration(); onInteraction() }
            if preferences.projectSort != .recent {
                if phase == .idle { withAnimation(reduceMotion ? nil : .snappy) { hold = nil } }
                else if hold == nil { setHold(layout.hold, scope: renderedScope, sort: renderedSort, generation: renderedGeneration) }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: layout.hold)

        }
    }

    private func renderCanWake(_ member: CompanionProjectMember) -> Bool {
        if let display { return display.wakeProjects.contains(member.id) }
        return CompanionProjectMachineAction.wake.isAvailable(member, store: store, terminal: terminal)
    }

    private func renderTerminal(_ target: CompanionTerminalScope) -> CompanionTerminalAvailability {
        if let display { return display.terminal[target] ?? .hidden }
        return terminal?.availability(target) ?? .hidden
    }

    /// Build once in the owner. Deferred List/ForEach closures never establish live
    /// catalog/state subscriptions that can survive the transition to a frozen backdrop.
    /// Conversation-dependent menu/activity inputs stay in their live leaf bodies,
    /// or are captured once by makeFrozenInputs. Never subscribe this owner to chats.
    private func makeContentValues(layout: CompanionHomeLayout) -> CompanionHomeContentValues {
        if let display { return .init(snapshot: display) }
        #if DEBUG
        CompanionHomeBuildProbe.record?(.contentInputs)
        #endif
        let hosts = store.hosts, entries = store.projectEntries
        let attention = store.homeAttentionItems()
        let shown = layout.projects + (preferences.idleExpanded ? layout.idle : [])
        let full = Dictionary(entries.map { ($0.orderKey, $0) }, uniquingKeysWith: { first, _ in first })
        var finished: [CompanionProjectTarget: [CompanionFinishedRun]] = [:]
        var states: [CompanionProjectTarget: CompanionProjectMenuDisplay] = [:]
        var linked: [String: CompanionProjectMenuDisplay] = [:]
        var activity: [CompanionProjectTarget: Date] = [:]
        // The closed idle footer still needs the shared-state presence, but not agent predicates or menus.
        for group in layout.projects + layout.idle {
            for member in group.entry.members { states[member.id] = .init(state: store.sharedProjectState(member.id)) }
        }
        for group in shown {
            let entry = group.entry, catalog = full[group.entry.orderKey] ?? group.entry
            linked[entry.orderKey] = .init(state: store.linkedProjectState(catalog),
                canChange: store.canChangeLinkedProjectState(catalog), connectionHint: store.linkedProjectStateConnectionHint(catalog))
            for member in entry.members {
                finished[member.id] = store.finished(in: member.id)
                activity[member.id] = projectActivity(member.id)
            }
        }
        return .init(hosts: hosts, entries: entries, attention: attention,
            finished: finished, finishedError: store.finishedError, states: states, linkedStates: linked,
            projectActivity: activity)
    }

    /// Capture only on entering a pushed route, never on a streamed chunk. No commands/authority are cached.
    private func makeFrozenInputs() -> CompanionHomeRenderSnapshot {
        #if DEBUG
        CompanionHomeBuildProbe.record?(.snapshot)
        #endif
        let layout = layout, scoped = scope
        let values = makeContentValues(layout: layout)
        let hosts = values.hosts, entries = values.entries
        let attention = values.attention.filter { scoped.contains($0.agent.id) }
        let shown = layout.projects + (preferences.idleExpanded ? layout.idle : [])
        var states = values.states
        var terminals: [CompanionTerminalScope: CompanionTerminalAvailability] = [:]
        var wakeProjects: Set<CompanionProjectTarget> = []
        var dispatcherActivity: [CompanionTarget: CompanionCapturedActivity] = [:]
        let full = Dictionary(entries.map { ($0.orderKey, $0) }, uniquingKeysWith: { first, _ in first })
        // History and permission predicates are read only at this push-time snapshot,
        // never by the live owner's display projection. Execution still resolves live.
        for host in hosts {
            if let agent = host.dispatcherAgent { dispatcherActivity[agent.id] = .init(date: store.lastActivity(of: agent)) }
        }
        for group in shown {
            let catalog = full[group.entry.orderKey] ?? group.entry
            for member in group.entry.members {
                states[member.id] = .init(state: values.states[member.id]?.state,
                    lastActivity: catalog.isLinked ? nil : store.lastActivity(for: member.id))
                terminals[.project(member.id)] = terminal?.availability(.project(member.id)) ?? .hidden
                if renderCanWake(member) { wakeProjects.insert(member.id) }
            }
        }
        var rowAgents: [CompanionTarget: CompanionAgent] = [:]
        for group in shown {
            let key = "quiet:" + quietKey(group)
            let rows = group.tree.active + (preferences.expandedFolds.contains(key) ? group.tree.sleeping + group.tree.finishedQuick : [])
            for row in group.tree.visible(rows, collapsed: preferences.collapsedAgents(in: rows)) { rowAgents[row.id] = row.agent }
        }
        for item in attention { rowAgents[item.agent.id] = item.agent }
        for host in scoped.hosts where isListed(host) && host.dispatcher?.isVisible == true {
            if let agent = host.dispatcherAgent { rowAgents[agent.id] = agent }
        }
        var settings: Set<CompanionTarget> = []
        var wake: [CompanionTarget: [CompanionWakeChoice]] = [:]
        // Only rows actually represented in this scope/layout/open folds get per-agent Store predicates.
        for agent in rowAgents.values {
            if agentSettings?.canOpen(agent.id) == true { settings.insert(agent.id) }
            wake[agent.id] = agentWake?.choices(agent.id) ?? []
            terminals[.agentShell(agent.id)] = terminal?.availability(.agentShell(agent.id)) ?? .hidden
        }
        #if DEBUG
        CompanionHomeBuildProbe.snapshotAgents?(rowAgents.count)
        #endif
        return .init(hosts: hosts, palette: palette,
            helperLabels: Dictionary(hosts.map { ($0.id, $0.helperRoutingLabels) }, uniquingKeysWith: { first, _ in first }),
            entries: entries, layout: layout, attention: attention,
            rowContext: .init(hostNames: Dictionary(hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                impliedHostID: scoped.impliedHostID, projectAccessDefaults: store.projectAccessDefaults, agentAccessDefaults: store.agentAccessDefaults),
            finished: values.finished, finishedError: values.finishedError, states: states, linkedStates: values.linkedStates,
            projectActivity: values.projectActivity, dispatcherActivity: dispatcherActivity, agents: Set(hosts.flatMap(\.allAgents).map(\.id)),
            settings: settings, wake: wake, terminal: terminals, wakeProjects: wakeProjects)
    }

    private func setHold(_ next: CompanionListHold, scope: CompanionDesktopSelection, sort: CompanionProjectSort, generation: UInt64) {
        // A callback from the previous render must not relabel its old ordering as a new session.
        guard generation == holdGeneration, scope == desktopSelection, sort == preferences.projectSort else { return }
        heldScope = scope
        heldSort = sort
        if hold != next { hold = next }
    }

    private func linkedQuiet(_ entry: CompanionProjectEntry) -> CompanionHomeLinkedRows {
        #if DEBUG
        CompanionHomeBuildProbe.record?(.quiet)
        #endif
        return .init(entry: entry, finished: renderFinished)
    }

    private func quietKey(_ group: CompanionProjectGroup) -> String {
        group.entry.isLinked ? group.entry.orderKey : "\(group.entry.host.id)-\(group.entry.project.id)"
    }

    /// If the former row disappeared or moved into a closed fold, restoration explicitly falls back to the top.
    private func anchorAvailable(_ anchor: CompanionHomeAnchor, layout: CompanionHomeLayout) -> Bool {
        let groups = layout.projects + (preferences.idleExpanded ? layout.idle : [])
        switch anchor {
        case .summary: return !renderHosts.isEmpty
        case .desktops: return true
        case .idle: return !layout.idle.isEmpty
        case .project(let target): return groups.contains { $0.entry.id == target }
        case .agent(let target):
            return groups.contains { group in
                let rows = group.tree.active + (preferences.expandedFolds.contains("quiet:" + quietKey(group)) ? group.tree.sleeping + group.tree.finishedQuick : [])
                return group.tree.visible(rows, collapsed: preferences.collapsedAgents(in: rows)).contains { $0.id == target }
            }
        case .finished(let target):
            return groups.contains { $0.entry.members.contains { $0.id == .init(hostID: target.hostID, projectID: target.projectID) }
                && preferences.expandedFolds.contains("quiet:" + quietKey($0)) }
                && renderFinished(.init(hostID: target.hostID, projectID: target.projectID)).contains { $0.target == target }
        case .quiet(let key): return groups.contains { $0.entry.orderKey == key || "\($0.entry.host.id)-\($0.entry.project.id)" == key }
        case .attention(let target): return scopedAttention.contains { $0.agent.id == target }
        case .dispatcher(let hostID): return scopedHosts.contains { $0.id == hostID && $0.dispatcher?.isVisible == true }
        case .offline(let target): return groups.contains { $0.entry.members.contains { $0.id == target && !$0.host.connection.canOperate } }
        case .cached(let target): return expandedOfflineHosts.contains(target.hostID) && renderHasAgent(target)
        }
    }

    private var presentationHosts: [CompanionHost] { scopedHosts.map(presentationHost) }

    private func presentationHost(_ host: CompanionHost) -> CompanionHost {
        guard renderHosts.count == 1 else { return host }
        var display = host
        display.name = "This desktop"
        return display
    }

    private func machineLabel(_ entry: CompanionProjectEntry, _ member: CompanionProjectMember) -> String {
        renderHosts.count == 1 ? member.project.name : entry.label(for: member)
    }

    /// The first scrolling content row: the native title slot cannot fit the full summary at XXXL.
    private var summary: Text {
        let counts = CompanionHomeSummary(hosts: scopedHosts, needsYou: scopedAttention.count)
        let connection = CompanionHomeSummary(hosts: renderHosts, needsYou: 0).connectionLabel
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
            CompanionHomeForEach(items, anchor: { .attention($0.agent.id) }) { item in
                NavigationLink(value: item.agent.id) {
                    CompanionAgentListRow(agent: item.agent, hostTag: multipleHosts ? item.hostName : nil, detail: item.detail)
                }
                .accessibilityIdentifier("agent-\(item.agent.id.hostID)-\(item.agent.id.agentID)")
                .companionHomeAnchor(.attention(item.agent.id))
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

    private var listedEntries: [CompanionProjectEntry] { scope.projects(renderEntries).filter { scope.selectedHostID != nil || $0.members.contains { isListed($0.host) } } }

    /// Each listed desktop's Dispatcher while it's on: a pinned row above the projects, as on the desktop's sidebar.
    @ViewBuilder private var dispatchers: some View {
        let shown = scopedHosts.filter { isListed($0) && $0.dispatcher?.isVisible == true }
        if !shown.isEmpty {
            Section {
                CompanionHomeForEach(shown, anchor: { .dispatcher($0.id) }) { host in
                    let activity = host.dispatcherAgent.flatMap { display?.dispatcherActivity[$0.id] }
                    CompanionDispatcherRow(store: store, host: host, hostTag: multipleHosts ? host.name : nil, capturedActivity: activity, capturedOpenAgent: display == nil ? nil : frozenActions?.openAgent)
                        .companionHomeAnchor(.dispatcher(host.id))
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
        if let display { return display.projectActivity[target] }
        if let contentValues { return contentValues.projectActivity[target] }
        let marked = renderState(target).map(\.lastActivity) ?? preferences.projectActivity[CompanionProjectOrdering.key(target)]
        let agents = renderHosts.first { $0.id == target.hostID }?.projects.first { $0.id == target.projectID }?.agents ?? []
        // Recorded catalog/turn times are stable between reports; per-tool chat timestamps churn.
        return ([marked] + agents.flatMap { [$0.lastActivity, $0.turnStartedAt] })
            .compactMap { $0 }.filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()
    }

    private var layout: CompanionHomeLayout {
        if let display { return display.layout }
        #if DEBUG
        CompanionHomeBuildProbe.record?(.layout)
        #endif
        return CompanionHomeLayout.build(listedEntries, sort: preferences.projectSort, customOrder: preferences.projectOrder,
                                  rule: preferences.idleRule, hold: heldScope == desktopSelection && heldSort == preferences.projectSort ? hold : nil, shared: { renderState($0.id) },
                                  projectActivity: projectActivity, agentActivity: store.lastActivity(of:))
    }

    @ViewBuilder private func projects(_ layout: CompanionHomeLayout) -> some View {
        let parentLines = CompanionAgentTree.parentLines(hosts: renderHosts)
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
        CompanionHomeForEach(layout.projects, anchor: { .project($0.entry.id) }) { group in projectSection(group, parentLines: parentLines) }
        if !layout.idle.isEmpty {
            Section {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { preferences.idleExpanded.toggle() }
                } label: {
                    CompanionFoldLabel(text: "\(layout.idle.count) idle project\(layout.idle.count == 1 ? "" : "s")", isOpen: preferences.idleExpanded)
                }
                .accessibilityIdentifier("idle-projects-fold")
                .companionHomeAnchor(.idle)
                .listRowBackground(CompanionCardBackground())
            } footer: {
                if preferences.idleExpanded { EmptyView() } else {
                    Text(idleFooter(layout.idle))
                }
            }
            if preferences.idleExpanded { CompanionHomeForEach(layout.idle, anchor: { .project($0.entry.id) }) { group in projectSection(group, parentLines: parentLines) } }
        }
    }

    private var projectSortMenu: some View {
        Menu {
            Picker("Sort projects", selection: $preferences.projectSort) {
                ForEach(CompanionProjectSort.allCases) { Text($0.label).tag($0) }
            }
            if preferences.projectSort == .custom {
                Button("Arrange projects…", systemImage: "line.3.horizontal") { arrangingEntries = orderedProjects; arranging = true }
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
            projectHeader(group)
                .companionHomeAnchor(.project(entry.id))
                .buttonStyle(.borderless)
                .navigationLinkIndicatorVisibility(.hidden)
                .listRowSeparator(.hidden)
                .listRowBackground(CompanionCardBackground())
            if entry.isLinked {
                CompanionHomeLinkedProjectRows(group: group, quiet: linkedQuiet(entry),
                    preferences: preferences, parentLines: parentLines, onDismissFinished: dismissFinished,
                    onClearFinished: clearFinished, canOpenFinished: { renderHasAgent($0) })
                CompanionHomeForEach(entry.members.filter { !$0.host.connection.canOperate }, anchor: { .offline($0.id) }) { member in
                    offlineMember(entry, member)
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
        }
    }

    private func projectHeader(_ group: CompanionProjectGroup) -> some View {
        #if DEBUG
        CompanionHomeBuildProbe.record?(.header)
        #endif
        let entry = group.entry
        #if DEBUG
        // Hosted coverage observes the same pure production value factory; native Menu
        // bodies are lazy. No additional work unless this explicit test observer is set.
        if hostedProjectMenu != nil { _ = sharedLinkedStateMenu(group) }
        #endif
        let projectID = "\(entry.host.id)-\(entry.project.id)"
        // Bound the Debug builder's generic value storage. Reuse one erased menu for
        // all three gesture targets and both accessibility action surfaces.
        let menu = CompanionHomeProjectHeaderMenu { AnyView(projectContextMenuItems(group)) }
        let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 6))
        return headerLayout {
            projectHeaderTitle(group, menu: menu)
            projectHeaderActions(group, menu: menu)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        .opacity(group.isIdle ? 0.7 : 1)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-\(projectID)")
    }

    private func projectHeaderTitle(_ group: CompanionProjectGroup, menu: CompanionHomeProjectHeaderMenu) -> AnyView {
        let entry = group.entry
        return AnyView(HStack(spacing: 6) {
            CompanionProjectBadge(project: entry.project)
                .overlay(alignment: .bottomTrailing) {
                    if let state = group.liveStatus {
                        Circle().fill(Color(state.dot.color(in: palette))).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
            projectLink(entry)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { menu }
                .accessibilityActions { menu }
                .accessibilityLabel("Open \(entry.project.name)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("open-project-\(entry.host.id)-\(entry.project.id)")
            if group.isPinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityLabel("Pinned")
            }
        })
    }

    private func projectHeaderActions(_ group: CompanionProjectGroup, menu: CompanionHomeProjectHeaderMenu) -> AnyView {
        let entry = group.entry
        let projectID = "\(entry.host.id)-\(entry.project.id)"
        return AnyView(HStack(spacing: 6) {
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
                .contextMenu { menu }
                .accessibilityActions { menu }
                .accessibilityIdentifier("project-new-agent-\(projectID)")
                .accessibilityLabel(entry.isLinked || !multipleHosts ? "New agent in \(entry.project.name)" : "New agent in \(entry.project.name) on \(entry.host.name)")
        })
    }

    private func observeConnectedHosts(_ hosts: [CompanionHost]) {
        let present = Set(hosts.map(\.id))
        observedConnectedAt = observedConnectedAt.filter { present.contains($0.key) }
        for host in hosts where host.connection.canOperate { observedConnectedAt[host.id] = Date() }
    }

    private func lastSeen(_ host: CompanionHost) -> Date? {
        // Presence is read-only context. Never infer desktop reachability from an agent's activity.
        let reported = renderHosts.flatMap { $0.dispatcherPresence?.remotes ?? [] }
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
        .companionHomeAnchor(.offline(member.id))
        .listRowBackground(CompanionCardBackground())
        if expanded {
            CompanionHomeForEach(cached, anchor: { .cached($0.id) }) { agent in
                CompanionAgentListRow(agent: agent)
                    .modifier(CompanionHomeRowInputs(store: store, snapshot: display, impliedHostID: member.host.id, actions: display == nil ? nil : frozenActions))
                    .environment(\.companionAgentSettings, nil)
                    .environment(\.companionAgentWake, nil)
                    .environment(\.companionTerminal, nil)
                    .disabled(true).allowsHitTesting(false)
                    .opacity(0.5)
                    .accessibilityLabel("\(agent.name), cached on \(machineLabel(entry, member)), desktop not connected")
                    .accessibilityIdentifier("cached-agent-\(agent.id.hostID)-\(agent.id.projectID)-\(agent.id.agentID)")
                    .companionHomeAnchor(.cached(agent.id))
                    .listRowBackground(CompanionCardBackground())
            }
        }
    }

    @ViewBuilder private func projectRows(tree: CompanionAgentTree, projectID: String, target: CompanionProjectTarget,
                                          parentLines: [CompanionTarget: String]) -> some View {
        let runs = renderFinished(target)
        CompanionAgentTreeRows(tree: tree, rows: tree.active, preferences: preferences, parentLines: parentLines)
        CompanionAgentTreeQuietFold(projectID: projectID, tree: tree, preferences: preferences,
                                   parentLines: parentLines, finishedRuns: runs,
                                   onDismissFinished: dismissFinished,
                                   onClearFinished: { clearFinished(target) },
                                   canOpenFinished: { renderHasAgent($0) })
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
        clearFinished([target])
    }

    private func clearFinished(_ targets: [CompanionProjectTarget]) {
        finishedActionError = nil
        Task {
            var firstError: String?
            for target in targets {
                await store.clearFinished(in: target)
                if firstError == nil { firstError = store.finishedError }
            }
            finishedActionError = firstError
        }
    }

    /// The idle window the folded projects use: their desktop's when it shares project state, else this phone's.
    private func idleFooter(_ idle: [CompanionProjectGroup]) -> String {
        let windows = Set(idle.map { group in
            renderState(group.id) != nil ? group.entry.host.idleDays : preferences.idleDays
        })
        guard windows.count == 1, let days = windows.first ?? nil else { return "No recent activity, or marked inactive." }
        return days > 0 ? "No activity for \(days) days, or marked inactive." : "Marked inactive."
    }

    /// Home shares Wake/Info with Project; linked state always follows the catalog's group contract.
    @ViewBuilder private func projectContextMenuItems(_ group: CompanionProjectGroup) -> some View {
        let entry = group.entry
        let catalogEntry = renderEntries.first { $0.members.contains { $0.id == entry.id } } ?? entry
        CompanionProjectMenuItems(store: store, preferences: preferences, entry: catalogEntry,
            canWake: entry.members.contains { renderCanWake($0) },
            capturedDisplay: display?.states[entry.id],
            onWake: { beginProjectAction(.wake, entry: entry) }, onInfo: { infoProject = entry.id })
        if let menu = sharedLinkedStateMenu(group) {
            menu
        } else if entry.isLinked {
            // Old hosts retain their per-copy state and days-idle rule.
            ForEach(entry.members) { member in
                let single = CompanionProjectEntry(host: member.host, project: member.project)
                let state = renderState(member.id)
                Menu(machineLabel(entry, member)) {
                    projectMenuItems(.init(entry: single,
                        isPinned: state?.pinned ?? preferences.pinnedProjects.contains(single.orderKey),
                        isIdle: state?.idle ?? preferences.idleRule.isIdle(single.orderKey,
                            running: member.host.connection.canOperate && member.project.agents.contains(where: CompanionHomeLayout.isAwake),
                            lastActivity: projectActivity(member.id), now: Date()), tree: group.tree), expectedLinkID: catalogEntry.linkID)
                }
                .disabled(state != nil && !member.host.connection.canOperate)
            }
        } else if catalogEntry.isLinked { projectMenuItems(group) }
        if entry.members.contains(where: { renderTerminal(.project($0.id)).isShown }) {
            Button("Terminal", systemImage: "terminal") {
                CompanionUIActions.record(.openProjectTerminal, on: .home)
                beginProjectAction(.terminal, entry: entry)
            }
            .disabled(!entry.members.contains { renderTerminal(.project($0.id)).isAvailable })
        }
    }

    private func sharedLinkedStateMenu(_ group: CompanionProjectGroup) -> CompanionLinkedProjectStateMenuItems? {
        let entry = group.entry
        let catalogEntry = renderEntries.first { $0.members.contains { $0.id == entry.id } } ?? entry
        guard renderLinked(catalogEntry) != nil else { return nil }
        return linkedStateMenu(entry: catalogEntry, isIdle: group.isIdle)
    }

    private func linkedStateMenu(entry: CompanionProjectEntry, isIdle: Bool) -> CompanionLinkedProjectStateMenuItems {
        let menu = CompanionLinkedProjectStateMenuItems(store: store, entry: entry, isIdle: isIdle, capturedDisplay: display?.linkedStates[entry.orderKey])
        #if DEBUG
        hostedProjectMenu?(menu)
        #endif
        return menu
    }

    private func beginProjectAction(_ action: CompanionProjectMachineAction, entry rendered: CompanionProjectEntry) {
        guard let entry = store.resolveProjectActionEntry(containing: rendered.id, expectedLinkID: rendered.linkID,
                                                         hostID: desktopSelection.hostID),
              entry.members.contains(where: { action.isAvailable($0, store: store, terminal: terminal) }) else { return }
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

    private func projectMenuItems(_ group: CompanionProjectGroup, expectedLinkID: String? = nil) -> some View {
        let key = group.entry.orderKey, project = group.id
        let shared = renderState(project)
        let isMarked = shared?.inactive ?? preferences.inactiveProjects.contains(key)
        func change(local: @escaping () -> Void, remote: @escaping () async -> Void) {
            guard let current = store.resolveProjectActionEntry(containing: project, expectedLinkID: expectedLinkID ?? group.entry.linkID),
                  store.linkedProjectState(current) == nil else { return }
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

/// On a push install captured display inputs once; subsequent parent updates do not rebuild the List.
/// Descendants receive value presentation inputs too, so Observation cannot bypass this boundary.
private struct CompanionHomeContent: View, Equatable {
    let home: CompanionHomeView
    let layout: CompanionHomeLayout
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.home.isPushed && rhs.home.isPushed && lhs.home.display != nil && rhs.home.display != nil
    }
    var body: some View { home.content(layout) }
}

/// A concrete boundary keeps the Home header's menu out of its inline generic row type.
private struct CompanionHomeProjectHeaderMenu: View {
    // Defer native menu construction into its own observation scope. Live history
    // gates must not register a subscription on the header/List builder itself.
    let content: @MainActor () -> AnyView
    var body: AnyView { content() }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    var capturedActivity: CompanionCapturedActivity? = nil
    /// Home passes the captured execution handle explicitly. The frozen branch has no
    /// open-agent Environment reader for Root's changing closure to invalidate directly.
    var capturedOpenAgent: (@MainActor (CompanionTarget) -> Void)? = nil
    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.row, when: countsHomeBuilds)
        #endif
        if let capturedOpenAgent {
            CompanionDispatcherRowContent(host: host, hostTag: hostTag,
                detail: companionDispatcherDetail(host: host, activity: capturedActivity?.date), openAgent: capturedOpenAgent).equatable()
        } else {
            CompanionLiveDispatcherRow(store: store, host: host, hostTag: hostTag, capturedActivity: capturedActivity)
        }
    }
}

/// Nil/default callers keep the existing live Environment action, including Dispatch.
private struct CompanionLiveDispatcherRow: View {
    @Bindable var store: CompanionStore
    let host: CompanionHost
    let hostTag: String?
    let capturedActivity: CompanionCapturedActivity?
    @Environment(\.companionOpenAgent) private var openAgent
    var body: some View {
        CompanionDispatcherRowContent(host: host, hostTag: hostTag,
            detail: companionDispatcherDetail(host: host, activity: activity), openAgent: openAgent).equatable()
    }

    private var activity: Date? {
        if let capturedActivity { return capturedActivity.date }
        return host.dispatcherAgent.flatMap { store.lastActivity(of: $0) }
    }
}

private func companionDispatcherDetail(host: CompanionHost, activity: @autoclosure () -> Date?) -> String? {
    guard let agent = host.dispatcherAgent else { return nil }
    if let note = host.dispatcher?.statusNote { return note }
    if let message = agent.detail?.message, !message.isEmpty { return message }
    return activity()?.formatted(.relative(presentation: .named))
}

private struct CompanionDispatcherRowContent: View, Equatable {
    let host: CompanionHost
    let hostTag: String?
    let detail: String?
    let openAgent: @MainActor (CompanionTarget) -> Void
    @Environment(\.companionPalette) private var palette
    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host.id == rhs.host.id && lhs.host.dispatcherAgent == rhs.host.dispatcherAgent
            && lhs.hostTag == rhs.hostTag && lhs.detail == rhs.detail
    }

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.dispatcherContent, when: countsHomeBuilds)
        #endif
        if let agent = host.dispatcherAgent {
            Button { openAgent(agent.id) } label: {
                CompanionAgentListRow(agent: agent, hostTag: hostTag, detail: detail)
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
