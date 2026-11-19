import SwiftUI
import ClubhouseTransport

/// One project scope, with shared desktop chips, one action row, and one quiet disclosure.
struct CompanionProjectPage: View {
    @Bindable var store: CompanionStore
    var preferences: CompanionPreferences
    let project: CompanionProjectTarget
    var onNewAgent: (CompanionProjectTarget) -> Void
    @State private var hold: [CompanionTarget]?
    @State private var desktop: CompanionDesktopSelection
    @State private var showingInfo = false
    @State private var choosingMachine: CompanionProjectMachineAction?
    @State private var pendingChoice: (CompanionProjectMachineAction, CompanionProjectTarget)?
    @State private var wakingProject: CompanionProjectTarget?
    @State private var pendingWake: (target: CompanionTarget, message: String)?
    @State private var finishedActionError: String?
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionTerminal) private var terminal
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(store: CompanionStore, preferences: CompanionPreferences, project: CompanionProjectTarget,
         initialDesktopSelection: CompanionDesktopSelection = .all,
         onNewAgent: @escaping (CompanionProjectTarget) -> Void) {
        self.store = store
        self.preferences = preferences
        self.project = project
        self.onNewAgent = onNewAgent
        _desktop = State(initialValue: initialDesktopSelection)
    }

    var body: some View {
        let entry = store.projectEntry(containing: project)
        Group {
            if let entry { content(entry) }
            else {
                ContentUnavailableView("Project unavailable", systemImage: "folder",
                                       description: Text("This project is no longer in the desktop catalog."))
            }
        }
        .navigationTitle(entry?.project.name ?? "Project")
        .toolbar {
            if let entry {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        CompanionProjectMenuItems(store: store, preferences: preferences, entry: entry,
                                                  canWake: scopedMembers(entry).contains { CompanionProjectMachineAction.wake.isAvailable($0, store: store, terminal: terminal) },
                                                  onWake: { begin(.wake, entry: entry) }, onInfo: { showingInfo = true })
                        if entry.isLinked {
                            if store.linkedProjectState(entry) != nil {
                                CompanionLinkedProjectStateMenuItems(store: store, entry: entry, isIdle: linkedIsIdle(entry))
                            } else {
                                // Unmigrated hosts keep the existing per-copy state/fallback policy.
                                ForEach(entry.members) { member in
                                    Menu(entry.label(for: member)) {
                                        CompanionSingleProjectStateMenuItems(store: store, preferences: preferences,
                                            entry: .init(host: member.host, project: member.project), legacyLinkID: entry.linkID)
                                    }
                                }
                            }
                        }
                    } label: { Label("Project options", systemImage: "ellipsis") }
                    .companionToolbarSecondary()
                    .accessibilityIdentifier("project-page-options")
                }
            }
        }
        .sheet(isPresented: $showingInfo) { CompanionProjectInfoSheet(store: store, project: project) }
        .sheet(item: $choosingMachine, onDismiss: completeMachineChoice) { action in
            CompanionProjectMachineChooser(store: store, project: project, selection: desktop, action: action) { target in
                pendingChoice = (action, target)
                choosingMachine = nil
            }
        }
        .sheet(item: $wakingProject, onDismiss: completeWake) { project in
            CompanionWakeSheet(store: store, project: project) { pendingWake = ($0, $1) }
        }
        .onChange(of: desktop) { _, _ in hold = nil }
        .companionTelemetryScreen(.project)
    }

    private func linkedIsIdle(_ entry: CompanionProjectEntry) -> Bool {
        // Use Home's full-group idle policy even when this page filters to one desktop.
        !CompanionHomeLayout.build([entry], sort: preferences.projectSort, customOrder: preferences.projectOrder,
            rule: preferences.idleRule, shared: { store.sharedProjectState($0.id) },
            projectActivity: { store.lastActivity(for: $0) }, agentActivity: store.lastActivity(of:)).idle.isEmpty
    }

    private func scopedMembers(_ entry: CompanionProjectEntry) -> [CompanionProjectMember] {
        entry.members.filter { desktop.hostID == nil || $0.host.id == desktop.hostID }
    }

    private func content(_ entry: CompanionProjectEntry) -> some View {
        let members = scopedMembers(entry)
        // Retained exited runs are historical, and are rendered once in the shared quiet fold.
        let agents = members.filter { $0.host.connection.canOperate }.flatMap(\.project.agents)
            .filter { !CompanionFinishedRuns.hasFinished($0) }
        let tree = CompanionAgentTree.build(agents, sort: preferences.projectSort, held: hold, lastActivity: store.lastActivity(of:))
        let sections = CompanionProjectAgentSections(tree: tree)
        let parentLines = CompanionAgentTree.parentLines(hosts: store.hosts)
        let runs = members.flatMap { store.finished(in: $0.id) }.enumerated().sorted {
            $0.element.completedAt == $1.element.completedAt ? $0.offset < $1.offset : $0.element.completedAt > $1.element.completedAt
        }.map(\.element)
        return List {
            Section {
                actionRow(entry)
                // Keep the scope owner mounted even when its visible chips disappear. It must
                // reconcile a removed selection before this page filters the remaining agents.
                CompanionDesktopChips(members: entry.members, selection: $desktop)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if !sections.needsYou.isEmpty {
                Section {
                    CompanionAgentTreeRows(tree: tree, rows: sections.needsYou, preferences: preferences, parentLines: parentLines)
                } header: { Text("Needs you") }
            }
            Section {
                CompanionAgentTreeRows(tree: tree, rows: sections.agents, preferences: preferences, parentLines: parentLines)
                CompanionAgentTreeQuietFold(projectID: "\(entry.id.hostID)-\(entry.id.projectID)", tree: tree,
                                           preferences: preferences, parentLines: parentLines, finishedRuns: runs,
                                           onDismissFinished: dismissFinished,
                                           onClearFinished: { clearFinished(members.filter { !store.finished(in: $0.id).isEmpty }.map(\.id)) },
                                           canOpenFinished: { store.agent(for: $0) != nil })
                if tree.all.isEmpty && runs.isEmpty && members.contains(where: { $0.host.connection.canOperate }) {
                    Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                        .listRowBackground(CompanionCardBackground())
                }
                ForEach(members.filter { !$0.host.connection.canOperate }) { member in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(entry.label(for: member)) · \(projectMachineDetail(member.host.connection))")
                        Button("Retry") {
                            AnnexTelemetry.shared.recordAction(screen: .project, control: .retry)
                            Task { await store.reconnect(hostID: member.host.id) }
                        }
                    }
                    .listRowBackground(CompanionCardBackground())
                    .accessibilityIdentifier("project-offline-\(member.host.id)-\(member.project.id)")
                }
            } header: { Text("Agents") } footer: {
                if let error = finishedActionError ?? store.finishedError {
                    Text(error).foregroundStyle(Color(palette.warning)).accessibilityIdentifier("finished-error")
                }
                if let error = store.projectStateError { Text(error).foregroundStyle(Color(palette.warning)) }
            }
        }
        .companionListStyle()
        .companionAgentRows(store: store, impliedHostID: desktop.hostID ?? (entry.isLinked ? nil : entry.host.id))
        .onScrollPhaseChange { _, phase in
            if phase == .idle { hold = nil }
            else if hold == nil { hold = agents.map(\.id) }
        }
    }

    private func actionRow(_ entry: CompanionProjectEntry) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { actionButtons(entry) }
            } else { HStack(spacing: 10) { actionButtons(entry) } }
        }
        .buttonBorderShape(.capsule).controlSize(.large)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    @ViewBuilder private func actionButtons(_ entry: CompanionProjectEntry) -> some View {
        let members = scopedMembers(entry)
        Button {
            AnnexTelemetry.shared.recordAction(screen: .project, control: .newAgent)
            onNewAgent(entry.isLinked ? entry.id : members.first?.id ?? entry.id)
        } label: {
            Label("New agent", systemImage: "plus").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).companionProminentLabel()
        .disabled(!members.contains { $0.host.connection.canOperate && $0.host.canSpawn })
        .accessibilityIdentifier("project-new-agent")
        if members.contains(where: { terminal?.availability(.project($0.id)).isShown == true }) {
            Button {
                AnnexTelemetry.shared.recordAction(screen: .project, control: .openProjectTerminal)
                begin(.terminal, entry: entry)
            } label: {
                Label("Terminal", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!members.contains { CompanionProjectMachineAction.terminal.isAvailable($0, store: store, terminal: terminal) })
            .accessibilityIdentifier("project-terminal")
        }
    }

    private func begin(_ action: CompanionProjectMachineAction, entry rendered: CompanionProjectEntry) {
        guard let entry = store.resolveProjectActionEntry(containing: rendered.id, expectedLinkID: rendered.linkID),
              scopedMembers(entry).contains(where: { action.isAvailable($0, store: store, terminal: terminal) }) else { return }
        let members = scopedMembers(entry)
        if entry.isLinked && (desktop == .all || members.count > 1) { choosingMachine = action }
        else if let target = members.first?.id { perform(action, on: target) }
    }

    private func completeMachineChoice() {
        guard let (action, target) = pendingChoice else { return }
        pendingChoice = nil
        perform(action, on: target)
    }

    private func perform(_ action: CompanionProjectMachineAction, on target: CompanionProjectTarget) {
        guard let member = store.projectEntry(containing: target)?.members.first(where: { $0.id == target }),
              action.isAvailable(member, store: store, terminal: terminal) else { return }
        switch action {
        case .terminal: terminal?.open(.project(target))
        case .wake: wakingProject = target
        }
    }

    private func completeWake() {
        guard let wake = pendingWake else { return }
        pendingWake = nil
        // Open the conversation only after the Wake sheet is fully dismissed (the existing iOS focus fix).
        Task { await store.wake(wake.target, message: wake.message) }
    }

    private func dismissFinished(_ run: CompanionFinishedRun) {
        finishedActionError = nil
        Task {
            await store.dismissFinished(run.target)
            finishedActionError = store.finishedError
        }
    }

    private func clearFinished(_ projects: [CompanionProjectTarget]) {
        finishedActionError = nil
        Task {
            var firstError: String?
            for project in projects {
                await store.clearFinished(in: project)
                if firstError == nil { firstError = store.finishedError }
            }
            finishedActionError = firstError
        }
    }
}

/// Shared Wake/Info and single-project actions for the Project toolbar and Home long-press menu.
/// Both owners use CompanionLinkedProjectStateMenuItems for authoritative linked group changes.
struct CompanionProjectMenuItems: View {
    @Bindable var store: CompanionStore
    let preferences: CompanionPreferences
    let entry: CompanionProjectEntry
    var canWake: Bool
    var capturedDisplay: CompanionProjectMenuDisplay? = nil
    var onWake: () -> Void
    var onInfo: () -> Void

    @Environment(\.companionTelemetryScreen) private var screen

    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.projectMenu, when: countsHomeBuilds)
        #endif
        Button("Wake with a message", systemImage: "sun.max") {
            CompanionUIActions.record(.wakeAgent, on: screen)
            onWake()
        }
            .disabled(!canWake).accessibilityIdentifier("project-wake")
        if !entry.isLinked { CompanionSingleProjectStateMenuItems(store: store, preferences: preferences, entry: entry, capturedDisplay: capturedDisplay) }
        Button("Project info", systemImage: "info.circle") {
            CompanionUIActions.record(.openProjectInfo, on: screen)
            onInfo()
        }
    }
}

/// The same authoritative linked-state actions in Home and the Project toolbar.
/// Entry must be the full catalog group, including when the visible page is desktop-scoped.
struct CompanionLinkedProjectStateMenuItems: View {
    @Bindable var store: CompanionStore
    let entry: CompanionProjectEntry
    let isIdle: Bool
    var capturedDisplay: CompanionProjectMenuDisplay? = nil

    func setPinned(_ pinned: Bool) async {
        guard let current = store.resolveProjectActionEntry(containing: entry.id, expectedLinkID: entry.linkID),
              store.canChangeLinkedProjectState(current) else { return }
        await store.setLinkedProject(current, pinned: pinned)
    }

    func setInactive(_ inactive: Bool) async {
        guard let current = store.resolveProjectActionEntry(containing: entry.id, expectedLinkID: entry.linkID),
              store.canChangeLinkedProjectState(current) else { return }
        await store.setLinkedProject(current, inactive: inactive)
    }

    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.projectMenu, when: countsHomeBuilds)
        #endif
        let state = if let capturedDisplay { capturedDisplay.state } else { store.linkedProjectState(entry) }
        if let shared = state {
            Button(shared.pinned ? "Unpin project" : "Pin project", systemImage: shared.pinned ? "pin.slash" : "pin") {
                Task { await setPinned(!shared.pinned) }
            }
            .disabled(!(capturedDisplay?.canChange ?? store.canChangeLinkedProjectState(entry)))
            if isIdle || shared.inactive {
                Button("Mark active", systemImage: "sun.max") {
                    Task { await setInactive(false) }
                }
                .disabled(!(capturedDisplay?.canChange ?? store.canChangeLinkedProjectState(entry)))
            } else if !shared.pinned {
                Button("Mark inactive", systemImage: "moon.zzz") {
                    Task { await setInactive(true) }
                }
                .disabled(!(capturedDisplay?.canChange ?? store.canChangeLinkedProjectState(entry)))
            }
            let hint = if let capturedDisplay { capturedDisplay.connectionHint } else { store.linkedProjectStateConnectionHint(entry) }
            if let hint { Text(hint) }
        }
    }
}

struct CompanionSingleProjectStateMenuItems: View {
    @Bindable var store: CompanionStore
    let preferences: CompanionPreferences
    let entry: CompanionProjectEntry
    var legacyLinkID: String? = nil
    var capturedDisplay: CompanionProjectMenuDisplay? = nil

    @Environment(\.companionTelemetryScreen) private var screen

    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.projectMenu, when: countsHomeBuilds)
        #endif
        let state = if let capturedDisplay { capturedDisplay.state } else { store.sharedProjectState(entry.id) }
        let lastActivity = if let capturedDisplay { capturedDisplay.lastActivity } else { store.lastActivity(for: entry.id) }
        let key = entry.orderKey
        let pinned = state?.pinned ?? preferences.pinnedProjects.contains(key)
        let marked = state?.inactive ?? preferences.inactiveProjects.contains(key)
        let running = entry.project.agents.contains(where: CompanionHomeLayout.isAwake)
        let activity = [lastActivity, state?.lastActivity ?? preferences.projectActivity[key]].compactMap { $0 }.max()
        let idle = !pinned && (state.map { $0.idle && !running } ?? preferences.idleRule.isIdle(key, running: running, lastActivity: activity, now: Date()))
        Group {
            Button(pinned ? "Unpin from Home" : "Pin to top of Home", systemImage: pinned ? "pin.slash" : "pin") {
                CompanionUIActions.record(pinned ? .unpinProject : .pinProject, on: screen)
                change(local: {
                    if preferences.pinnedProjects.contains(key) != !pinned { preferences.togglePinned(key) }
                }, remote: { await store.setProject(entry.id, pinned: !pinned) })
            }
            if idle || marked {
                Button("Mark active", systemImage: "sun.max") {
                    CompanionUIActions.record(.markProjectActive, on: screen)
                    change(local: { preferences.markActive(key) }, remote: { await store.setProject(entry.id, inactive: false) })
                }
            } else if !pinned {
                Button("Mark inactive", systemImage: "moon.zzz") {
                    CompanionUIActions.record(.markProjectInactive, on: screen)
                    change(local: { preferences.markInactive(key) }, remote: { await store.setProject(entry.id, inactive: true) })
                }
            }
        }
        .disabled(state != nil && !entry.host.connection.canOperate)
    }

    func change(local: () -> Void, remote: @escaping () async -> Void) {
        guard let current = store.projectEntry(containing: entry.id) else { return }
        if current.isLinked {
            // Only the explicitly rendered old-host group may use per-copy state. Recheck
            // authority and identity at the action, so a stale menu cannot bypass migration.
            guard let legacyLinkID, current.linkID == legacyLinkID,
                  store.linkedProjectState(current) == nil else { return }
        }
        if store.sharedProjectState(entry.id) == nil { local() }
        else { Task { await remote() } }
    }
}

enum CompanionProjectMachineAction: String, Identifiable {
    case terminal, wake
    var id: Self { self }
    var title: String { self == .terminal ? "Terminal" : "Wake with a message" }

    func isAvailable(_ member: CompanionProjectMember, store: CompanionStore, terminal: CompanionTerminalAction?) -> Bool {
        guard member.host.connection.canOperate else { return false }
        switch self {
        case .terminal: return terminal?.availability(.project(member.id)).isAvailable == true
        case .wake: return !store.sleepingAgents(in: member.id).isEmpty
        }
    }
}

struct CompanionProjectMachineChooser: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    let selection: CompanionDesktopSelection
    let action: CompanionProjectMachineAction
    var screen: AnnexUIAction.Screen = .project
    var onChoose: (CompanionProjectTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionTerminal) private var terminal
    @Environment(\.companionPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                if let entry = store.projectEntry(containing: project) {
                    Section(action.title) {
                        ForEach(entry.members.filter { selection.hostID == nil || $0.host.id == selection.hostID }) { member in
                            Button {
                                AnnexTelemetry.shared.recordAction(screen: screen, control: .selectDesktop)
                                guard let current = store.resolveProjectActionEntry(containing: member.id, expectedLinkID: entry.linkID),
                                      let fresh = current.members.first(where: { $0.id == member.id }),
                                      action.isAvailable(fresh, store: store, terminal: terminal) else { return }
                                onChoose(member.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.label(for: member))
                                    Text(detail(member)).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                                }
                            }
                            .disabled(!action.isAvailable(member, store: store, terminal: terminal))
                            .accessibilityIdentifier("project-machine-choice-\(member.host.id)-\(member.project.id)")
                            .listRowBackground(CompanionCardBackground())
                        }
                    }
                }
            }
            .companionListStyle()
            .navigationTitle("Choose a desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        AnnexTelemetry.shared.recordAction(screen: screen, control: .cancel)
                        dismiss()
                    }.companionToolbarClose()
                }
            }
        }
        .accessibilityIdentifier("project-machine-chooser")
    }

    private func detail(_ member: CompanionProjectMember) -> String {
        if !member.host.connection.canOperate { return projectMachineDetail(member.host.connection) }
        if action == .wake, store.sleepingAgents(in: member.id).isEmpty { return "No sleeping agents" }
        if action == .terminal {
            switch terminal?.availability(.project(member.id)) {
            case .unavailable(let reason): return reason
            case .hidden, nil: return "Terminal unavailable"
            default: break
            }
        }
        return member.host.connection.label
    }
}

private func projectMachineDetail(_ connection: CompanionConnection) -> String {
    let blocked: Bool
    if case .failed = connection { blocked = true } else { blocked = false }
    return connection.presentation(linkBlocked: blocked).detail
}

/// A finished run: its mission, when it finished, and how it ended.
struct CompanionFinishedRow: View {
    let run: CompanionFinishedRun
    let now: Date
    @Environment(\.companionPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(run.title).lineLimit(2)
                Spacer(minLength: 4)
                Text(CompanionFinishedRun.ago(run.completedAt, now: now))
                    .font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            Text(run.detail).font(.subheadline)
                .foregroundStyle(Color(run.failed ? palette.error : palette.secondaryLabel))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The desktop composer's "Wake a sleeping agent": choose one, say what it should do, and its chat opens.
struct CompanionWakeSheet: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    /// Called with the chosen agent and the message as the sheet closes; the page wakes it once the sheet has gone.
    var onWake: (CompanionTarget, String) -> Void
    @State private var selection: CompanionTarget?
    @State private var message = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var sleeping: [CompanionAgent] { store.sleepingAgents(in: project) }
    private var chosen: CompanionAgent? { sleeping.first { $0.id == selection } }
    private var canWake: Bool {
        chosen != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.hosts.first { $0.id == project.hostID }?.connection.canOperate == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Agent", selection: $selection) {
                        ForEach(sleeping) { agent in Text(agent.name).tag(Optional(agent.id)) }
                    }
                    .accessibilityIdentifier("wake-agent-picker")
                }
                Section {
                    TextField("What should \(chosen?.name ?? "it") do?", text: $message, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focused)
                        .accessibilityIdentifier("wake-message")
                } footer: {
                    Text("It wakes and starts with this message. Its chat opens so you can follow along.")
                }
            }
            .companionBackground()
            .scrollContentBackground(.hidden)
            .navigationTitle("Wake with a message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        AnnexTelemetry.shared.recordAction(screen: .wakeAgent, control: .cancel)
                        dismiss()
                    }.companionToolbarClose()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wake", systemImage: "checkmark") {
                        guard let target = selection else { return }
                        AnnexTelemetry.shared.recordAction(screen: .wakeAgent, control: .wakeAgent)
                        onWake(target, message)
                        dismiss()
                    }
                    .labelStyle(.iconOnly).buttonStyle(.glassProminent).companionProminentLabel()
                    .disabled(!canWake)
                    .accessibilityIdentifier("wake-send")
                }
            }
            .interactiveDismissDisabled(!message.isEmpty)
            .onAppear {
                if selection == nil { selection = sleeping.first?.id }
                #if DEBUG
                CompanionWakeFocusDiagnostics.begin()
                #endif
                focused = true
                #if DEBUG
                CompanionWakeFocusDiagnostics.snapshot(.focusRequested(focused))
                #endif
            }
            #if DEBUG
            .onChange(of: focused) { _, value in
                CompanionWakeFocusDiagnostics.snapshot(.focusChanged(value))
            }
            .onDisappear { CompanionWakeFocusDiagnostics.end() }
            #endif
        }
        .presentationDetents([.medium, .large])
    }
}
