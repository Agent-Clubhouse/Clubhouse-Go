import SwiftUI

/// The desktop's New agent page: Durable (the default where the desktop supports it) or Quick.
/// Quick is task first: what the agent should do, with project, desktop and options as chips under it.
/// Older desktops can only start quick agents, so the sheet is "New quick agent" there.
struct CompanionSpawnSheet: View {
    enum Kind: Hashable { case durable, quick }
    @Bindable var store: CompanionStore
    let initialProject: CompanionProjectTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette
    @State private var project: CompanionProjectTarget?
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var showOptions = false
    @State private var confirmReviewedSpawn = false
    @State private var confirmReviewedCreate = false
    @State private var kind: Kind = .durable
    @State private var durable = DurableForm()
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if effectiveKind == .durable { durableForm } else { quickForm }
            }
            .companionBackground()
            .navigationTitle(supportsDurable ? "New agent" : "New quick agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.disabled(store.spawnInProgress || store.createInProgress)
                }
                if effectiveKind == .durable {
                    ToolbarItem(placement: .confirmationAction) { createButton }
                }
            }
            .interactiveDismissDisabled(store.spawnInProgress || store.createInProgress || !prompt.isEmpty)
            .confirmationDialog("Finish reviewing the previous request?", isPresented: $confirmReviewedSpawn, titleVisibility: .visible) {
                Button("Continue with a new task") {
                    store.acknowledgeReviewedSpawn()
                    prompt = ""
                }
            } message: { Text("The earlier agent may still be running. Continue only after checking the desktop's agent list; starting a new task does not cancel it.") }
            .confirmationDialog("Finish reviewing the previous request?", isPresented: $confirmReviewedCreate, titleVisibility: .visible) {
                Button("Create another agent") { store.acknowledgeReviewedCreate() }
            } message: { Text("The earlier agent may already be on your desktop. Continue only after checking its agent list.") }
            .onAppear {
                project = initialProject
                if store.uncertainSpawnRequest == nil { store.spawnError = nil }
                if store.uncertainCreateRequest == nil { store.createError = nil }
                kind = supportsDurable ? .durable : .quick
                promptFocused = kind == .quick
            }
            .task(id: durableProject) { await loadOptions() }
        }
        .presentationDetents([.large])
    }

    /// Durable or Quick, with the desktop's help text.
    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Kind", selection: $kind) {
                Text("Durable").tag(Kind.durable)
                Text("Quick").tag(Kind.quick)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("new-agent-kind")
            Text(kind == .durable ? "Keeps its name, settings and history. You start it and talk to it whenever you like."
                                  : "Runs one mission, reports back, and finishes.")
                .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
        }
    }

    private var quickForm: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if supportsDurable { kindPicker }
                    TextField("What should this agent accomplish?", text: $prompt, axis: .vertical)
                        .lineLimit(6...12).font(.title3).focused($promptFocused).accessibilityLabel("Agent task")
                        .padding(16)
                        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    chips
                    if showOptions {
                        VStack(spacing: 0) {
                            if let providers = selectedHost?.providers, !providers.isEmpty {
                                Picker("Provider", selection: $provider) {
                                    Text("Project default").tag("")
                                    ForEach(providers) { Text($0.name).tag($0.id) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                            } else {
                                TextField("Provider default", text: $provider).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityLabel("Provider, optional").padding(14)
                            }
                            Divider().padding(.leading, 14)
                            TextField("Model default", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("Model, optional").padding(14)
                        }
                        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Text("Leave these blank to use the project's configured provider and model.")
                            .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    }
                    if let host = selectedHost, !host.connection.canOperate {
                        Label("\(host.name) is \(host.connection.label.lowercased()). Reconnect before starting an agent.", systemImage: "wifi.exclamationmark")
                            .font(.subheadline).foregroundStyle(Color(palette.warning))
                    }
                    if let error = store.spawnError {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.error))
                    }
                    if let request = store.uncertainSpawnRequest { uncertain(request) }
                    startButton
                    Text("The agent runs in this project on your desktop. You can follow its progress and steer it from the conversation.")
                        .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            projectMenu
            Button { showOptions.toggle() } label: {
                chip(systemImage: "slider.horizontal.3", text: optionsLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Provider and model, \(optionsLabel)")
        }
    }

    private var projectMenu: some View {
            Menu {
                Picker("Run on", selection: $project) {
                    ForEach(store.hosts) { host in
                        Section(host.name) {
                            ForEach(host.projects) { item in
                                Text(item.name).tag(Optional(CompanionProjectTarget(hostID: host.id, projectID: item.id)))
                            }
                        }
                    }
                }
            } label: {
                chip(systemImage: "folder", text: selectedProjectName)
            }
            .accessibilityLabel("Run on \(selectedProjectName)")
    }

    private func chip(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color(palette.label))
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(Color(palette.fill), in: Capsule())
    }

    private var startButton: some View {
        Button {
            guard let project else { return }
            Task { if await store.spawn(project: project, prompt: prompt, provider: nonempty(provider), model: nonempty(model)) { dismiss() } }
        } label: {
            Group {
                if store.spawnInProgress { ProgressView().accessibilityLabel("Starting agent") }
                else { Text("Start agent") }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)
        .disabled(store.spawnInProgress || store.uncertainSpawnRequest != nil || selectedHost?.connection.canOperate != true || selectedHost?.canSpawn != true || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func uncertain(_ request: CompanionSpawnRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("We couldn't confirm the agent started", systemImage: "exclamationmark.triangle").font(.headline)
                .foregroundStyle(Color(palette.warning))
            Text("Your desktop may already have started it. Check before trying again, so you don't get two.").font(.subheadline)
            Text(request.prompt).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            HStack {
                Button("Check previous request") { Task { if await store.checkSpawnOutcome() { dismiss() } } }
                    .disabled(store.spawnInProgress)
                Button("View agents") { dismiss() }
                Button("I've checked the agents") { confirmReviewedSpawn = true }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.subheadline)
        }
        .padding(16)
        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Durable

    /// The New agent page's fields, from the project's create options.
    struct DurableForm {
        var options: CompanionCreateOptions?
        var loading = false
        var error: String?
        var name = ""
        var color = "indigo"
        var orchestrator = ""
        var model = "default"
        var persona = ""
        var useWorktree = true
        var mcpIDs: Set<String> = []

        mutating func reset(to options: CompanionCreateOptions) {
            self.options = options
            name = options.suggestedName.isEmpty ? CompanionAgentName.random() : options.suggestedName
            color = options.defaultColor
            orchestrator = options.defaultOrchestrator ?? options.options.orchestrators.first?.id ?? ""
            model = options.defaultModel
            persona = ""
            useWorktree = options.isGitRepo && options.defaultUseWorktree
            mcpIDs = Set(options.mcpDefaults)
        }
        var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
        /// With its own worktree the name becomes a folder and a branch, so it's checked as the desktop does.
        var nameProblem: String? {
            if trimmedName.isEmpty { return "Enter a name for the agent." }
            return useWorktree ? CompanionAgentName.problem(trimmedName) : nil
        }
    }

    private var supportsDurable: Bool { selectedHost?.canCreateDurable == true }
    private var effectiveKind: Kind { supportsDurable ? kind : .quick }
    /// The project to read create options for, while the durable form is offered.
    private var durableProject: CompanionProjectTarget? { supportsDurable ? project : nil }

    private func loadOptions() async {
        guard let project = durableProject else { durable = DurableForm(); return }
        durable.loading = true
        durable.error = nil
        defer { durable.loading = false }
        do {
            let options = try await store.createOptions(for: project)
            guard durableProject == project else { return }
            durable.reset(to: options)
        } catch {
            guard durableProject == project else { return }
            durable.options = nil
            durable.error = error.localizedDescription
        }
    }

    private var durableForm: some View {
        Form {
            Section { kindPicker }
            Section { LabeledContent("Project") { projectMenu } }
            // Problems show at the top, next to Create in the toolbar, rather than below a long form.
            if (selectedHost.map { !$0.connection.canOperate } ?? false) || store.createError != nil || store.uncertainCreateRequest != nil {
                Section {
                    if let host = selectedHost, !host.connection.canOperate {
                        Label("\(host.name) is \(host.connection.label.lowercased()). Reconnect before creating an agent.", systemImage: "wifi.exclamationmark")
                            .font(.subheadline).foregroundStyle(Color(palette.warning))
                    }
                    if let error = store.createError {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.error))
                            .accessibilityIdentifier("new-agent-error")
                    }
                    if store.uncertainCreateRequest != nil { uncertainCreate }
                }
            }
            if let options = durable.options {
                durableFields(options)
            } else if let error = durable.error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(palette.error))
                    Button("Try again") { Task { await loadOptions() } }
                }
            } else {
                Section { ProgressView("Loading the desktop's options…").frame(maxWidth: .infinity) }
            }
            Section {
                EmptyView()
            } footer: {
                Text("There's no mission for a durable agent. Once it's created, wake it with a message.")
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func durableFields(_ options: CompanionCreateOptions) -> some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(options.options.colors.first { $0.id == durable.color }?.rgb.map { Color($0) } ?? Color(palette.tint))
                    .frame(width: 22, height: 22).accessibilityHidden(true)
                TextField("Name", text: $durable.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("new-agent-name")
                Button("Randomize name", systemImage: "shuffle") { durable.name = CompanionAgentName.random() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .accessibilityIdentifier("new-agent-randomize")
            }
        } header: { Text("Name") } footer: {
            if let problem = durable.nameProblem {
                Text(problem).foregroundStyle(Color(palette.error)).accessibilityIdentifier("new-agent-name-error")
            } else {
                Text("Generated. Change it now or rename it later.")
            }
        }
        Section("Color") {
            CompanionColorSwatches(colors: options.options.colors, selection: $durable.color)
        }
        Section {
            Picker("Runs on", selection: $durable.orchestrator) {
                ForEach(options.options.orchestrators) { option in
                    Text(option.badge.map { "\(option.displayName) · \($0)" } ?? option.displayName).tag(option.id)
                }
            }
            .accessibilityIdentifier("new-agent-orchestrator")
            .onChange(of: durable.orchestrator) { _, id in
                if !options.options.models(for: id).contains(where: { $0.id == durable.model }) { durable.model = "default" }
            }
            Picker("Model", selection: $durable.model) {
                ForEach(options.options.models(for: durable.orchestrator)) { Text($0.label).tag($0.id) }
            }
            .accessibilityIdentifier("new-agent-model")
        } footer: {
            if let warning = options.options.orchestrator(durable.orchestrator)?.warning {
                Text(warning).foregroundStyle(Color(palette.warning))
            } else {
                Text("The model list follows the CLI.")
            }
        }
        Section {
            Picker("Persona", selection: $durable.persona) {
                Text("Project default").tag("")
                ForEach(options.options.personas) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("new-agent-persona")
        }
        if options.isGitRepo {
            Section {
                Toggle("Own worktree and branch", isOn: $durable.useWorktree)
                    .accessibilityIdentifier("new-agent-worktree")
            } footer: {
                Text(durable.useWorktree
                     ? "Branch \(durable.trimmedName)/standby from the current branch, checked out in .clubhouse/agents/\(durable.trimmedName)."
                     : "Works in the project folder, on whatever branch is checked out there.")
            }
        }
        Section {
            LabeledContent("Free Agent Mode", value: "Off")
                .accessibilityIdentifier("new-agent-free-agent-mode")
        } header: { Text("Permissions") } footer: {
            Text("The agent asks before it edits. Free Agent Mode can only be turned on at the desktop.")
        }
        if !options.mcpCatalog.isEmpty {
            Section {
                ForEach(options.mcpCatalog) { server in
                    Toggle(isOn: Binding(get: { durable.mcpIDs.contains(server.id) },
                                         set: { if $0 { durable.mcpIDs.insert(server.id) } else { durable.mcpIDs.remove(server.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            if let description = server.description { Text(description).font(.caption).foregroundStyle(Color(palette.secondaryLabel)) }
                        }
                    }
                }
            } header: { Text("MCP servers") } footer: {
                Text("Project defaults from the MCP catalog, \(durable.mcpIDs.count) of \(options.mcpCatalog.count).")
            }
        }
    }

    private var createButton: some View {
        Button {
            guard let project, let options = durable.options else { return }
            let request = CompanionCreateRequest(
                project: project, name: durable.trimmedName, color: durable.color,
                orchestrator: nonempty(durable.orchestrator), model: durable.model == "default" ? nil : durable.model,
                persona: nonempty(durable.persona), useWorktree: options.isGitRepo ? durable.useWorktree : nil,
                mcpIDs: options.mcpCatalog.isEmpty ? nil : options.mcpCatalog.map(\.id).filter(durable.mcpIDs.contains),
                clientCommandID: UUID().uuidString)
            Task { if await store.create(request) { dismiss() } }
        } label: {
            if store.createInProgress { ProgressView().accessibilityLabel("Creating agent") }
            else { Text("Create") }
        }
        .buttonStyle(.glassProminent)
        .disabled(store.createInProgress || store.uncertainCreateRequest != nil || selectedHost?.connection.canOperate != true
                  || durable.options == nil || durable.nameProblem != nil)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("new-agent-create")
    }

    private var uncertainCreate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("We couldn't confirm the agent was created", systemImage: "exclamationmark.triangle").font(.headline)
                .foregroundStyle(Color(palette.warning))
            Text("Your desktop may already have it. Check before trying again, so you don't get two.").font(.subheadline)
            HStack {
                Button("Check again") { Task { if await store.checkCreateOutcome() { dismiss() } } }
                    .disabled(store.createInProgress)
                Button("I've checked the agents") { confirmReviewedCreate = true }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.subheadline)
        }
    }

    private var selectedHost: CompanionHost? { store.hosts.first { $0.id == project?.hostID } }
    private var selectedProjectName: String {
        guard let host = selectedHost, let name = host.projects.first(where: { $0.id == project?.projectID })?.name else { return "Choose a project" }
        return store.hosts.count > 1 ? "\(name) · \(host.name)" : name
    }
    private var optionsLabel: String {
        let providerName = selectedHost?.providers.first { $0.id == provider }?.name ?? nonempty(provider)
        let parts = [providerName, nonempty(model)].compactMap { $0 }
        return parts.isEmpty ? "Default model" : parts.joined(separator: " · ")
    }
    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
