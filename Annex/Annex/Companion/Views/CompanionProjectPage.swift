import SwiftUI

/// One project, opened from its header on Home: New agent and Wake with a message, the quick agents that
/// finished and wait to be read, the project's agents, and its Changes. The desktop's project start page
/// (Clubhouse `ProjectStartPage.tsx`) with the Changes view beside it (`ProjectChanges.tsx`).
struct CompanionProjectPage: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    var onNewAgent: (CompanionProjectTarget) -> Void
    @State private var waking = false
    /// The agent and message from Wake with a message, held until the sheet has gone. Opening the chat while the
    /// sheet is still dismissing left its timeline blank on iOS 26.5 until it was scrolled.
    @State private var pendingWake: (target: CompanionTarget, message: String)?
    @State private var changes: CompanionChanges?
    @State private var changesError: String?
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionTerminal) private var terminal

    private var host: CompanionHost? { store.hosts.first { $0.id == project.hostID } }
    private var details: CompanionProject? { host?.projects.first { $0.id == project.projectID } }
    private var canOperate: Bool { host?.connection.canOperate == true }

    var body: some View {
        List {
            if let details {
                actions
                finished
                agents(details)
                changesSection
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder",
                                       description: Text("This project is no longer on its desktop, or the desktop is offline."))
                    .listRowBackground(Color.clear)
            }
        }
        .companionListStyle()
        .navigationTitle(details?.name ?? "Project")
        .toolbar {
            if let host, store.hosts.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { CompanionHostTag(name: host.name) }
            }
        }
        .sheet(isPresented: $waking, onDismiss: {
            guard let wake = pendingWake else { return }
            pendingWake = nil
            Task { await store.wake(wake.target, message: wake.message) }
        }) {
            CompanionWakeSheet(store: store, project: project) { pendingWake = ($0, $1) }
        }
        .task(id: canOperate) { if canOperate { await loadChanges() } }
    }

    // MARK: Sections

    private var actions: some View {
        let sleeping = store.sleepingAgents(in: project)
        return Section {
            HStack(spacing: 10) {
                Button { onNewAgent(project) } label: {
                    Label("New agent", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).companionProminentLabel()
                .disabled(!canOperate || host?.canSpawn != true)
                .accessibilityIdentifier("project-new-agent")
                Button { waking = true } label: {
                    Label("Wake with a message", systemImage: "sun.max").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canOperate || sleeping.isEmpty)
                .accessibilityIdentifier("project-wake")
                .accessibilityHint(sleeping.isEmpty ? "No agent here is asleep." : "Choose a sleeping agent and what it should do.")
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .lineLimit(1).minimumScaleFactor(0.8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            terminalButton
        }
    }

    /// A shell at the project root, as the desktop's Terminal tab opens with the project selected.
    @ViewBuilder private var terminalButton: some View {
        if let terminal, case let availability = terminal.availability(.project(project)), availability.isShown {
            Button { terminal.open(.project(project)) } label: {
                Label("Terminal", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!availability.isAvailable)
            .accessibilityIdentifier("project-terminal")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    /// The desktop's list: hidden when empty, newest first, each row dismissable, and Clear all.
    @ViewBuilder private var finished: some View {
        let runs = store.finished(in: project)
        if !runs.isEmpty {
            Section {
                ForEach(runs) { run in finishedRow(run) }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Finished, waiting on you").font(.headline).foregroundStyle(Color(palette.label))
                    Text("\(runs.count)").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    Spacer()
                    Button("Clear all") { Task { await store.clearFinished(in: project) } }
                        .font(.subheadline)
                        .accessibilityIdentifier("finished-clear-all")
                }
                .textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = store.finishedError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(palette.warning))
                            .accessibilityIdentifier("finished-error")
                    }
                    Text(store.sharesFinished(project) ? "Swipe a run to dismiss it. This list is shared with your desktop."
                                                       : "Swipe a run to dismiss it. This list is kept on your phone.")
                }
            }
        }
    }

    @ViewBuilder private func finishedRow(_ run: CompanionFinishedRun) -> some View {
        let label = TimelineView(.periodic(from: .now, by: 60)) { context in CompanionFinishedRow(run: run, now: context.date) }
        Group {
            // A run the desktop has forgotten has no chat left to open.
            if store.agent(for: run.target) != nil {
                NavigationLink(value: run.target) { label }
            } else {
                label
            }
        }
        .listRowBackground(CompanionCardBackground())
        .accessibilityIdentifier("finished-\(run.target.agentID)")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Dismiss", systemImage: "xmark", role: .destructive) { dismiss(run) }
        }
        .contextMenu {
            Button("Dismiss", systemImage: "xmark") { dismiss(run) }
        }
        .accessibilityAction(named: "Dismiss") { dismiss(run) }
    }

    private func dismiss(_ run: CompanionFinishedRun) {
        Task { await store.dismissFinished(run.target) }
    }

    /// Every agent except quick agents that exited: those are in Finished until dismissed.
    @ViewBuilder private func agents(_ details: CompanionProject) -> some View {
        let agents = details.agents.filter { !CompanionFinishedRuns.hasFinished($0) }
        Section {
            if agents.isEmpty {
                Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                    .listRowBackground(CompanionCardBackground())
            }
            ForEach(agents) { agent in
                NavigationLink(value: agent.id) { CompanionAgentListRow(agent: agent) }
                    .accessibilityIdentifier("agent-\(agent.id.hostID)-\(agent.id.agentID)")
                    .listRowBackground(CompanionCardBackground())
            }
        } header: {
            Text("Agents").font(.headline).foregroundStyle(Color(palette.label)).textCase(nil)
        }
    }

    private var changesSection: some View {
        Section {
            NavigationLink {
                CompanionChangesView(store: store, project: project, initial: changes)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Changes")
                        Text(changesSummary).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(2)
                    }
                } icon: { Image(systemName: "plusminus") }
            }
            .disabled(!canOperate)
            .accessibilityIdentifier("project-changes")
            .listRowBackground(CompanionCardBackground())
        } footer: {
            Text("The project folder's uncommitted files. Read-only: commit and push on your desktop.")
        }
    }

    private var changesSummary: String {
        guard canOperate else { return "Reconnect to see this project's changes." }
        if let changesError { return changesError }
        guard let changes else { return "Reading…" }
        guard changes.isRepository else { return "Not a git repository" }
        let files = changes.files.isEmpty ? "No uncommitted changes" : "\(changes.files.count) changed file\(changes.files.count == 1 ? "" : "s")"
        return changes.branch.isEmpty ? files : "\(changes.branch) · \(files)"
    }

    private func loadChanges() async {
        do { changes = try await store.changes(for: project); changesError = nil }
        catch { changesError = error.localizedDescription }
    }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wake") {
                        guard let target = selection else { return }
                        onWake(target, message)
                        dismiss()
                    }
                    .disabled(!canWake)
                    .accessibilityIdentifier("wake-send")
                }
            }
            .interactiveDismissDisabled(!message.isEmpty)
            .onAppear {
                if selection == nil { selection = sleeping.first?.id }
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}
