import SwiftUI
import ClubhouseTransport

/// Shared by Settings and the preview's Settings sheet. One page per desktop: presets are app-wide.
struct CompanionHelperPresetLinks: View {
    @Bindable var store: CompanionStore
    var body: some View {
        let hosts = store.hosts.filter {
            guard let feature = $0.helperRouting, feature.version == 1 else { return false }
            return feature.supportsPresets || feature.modes.contains("auto") || feature.quota
        }
        if !hosts.isEmpty {
            Section("Helpers") {
                ForEach(hosts) { host in
                    NavigationLink {
                        CompanionHelperPresetsView(store: store, hostID: host.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Helper presets")
                            if store.hosts.count > 1 { Text(host.name).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("helper-presets-\(host.id)")
                }
            }
        }
    }
}

struct CompanionHelperPresetsView: View {
    @Bindable var store: CompanionStore
    let hostID: String
    var projectID: String? = nil
    var agentID: String? = nil
    @State private var screen = CompanionHelperPresetsScreen()
    @Environment(\.scenePhase) private var scenePhase
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    private var title: String {
        if let agentID, let agent = host?.allAgents.first(where: { $0.id.agentID == agentID }) { return agent.name + " helpers" }
        if let projectID, let project = host?.projects.first(where: { $0.id == projectID }) { return project.name + " helpers" }
        return "Helper presets"
    }
    private var refreshKey: String { "\(host?.helperRoutingRevision ?? "")|\(host?.connection.canOperate == true)|\(screen.saving)" }
    private var canEdit: Bool { projectID == nil && agentID == nil && host?.canEditHelperPresets == true && host?.helperRouting?.canEditPresets == true && host?.connection.canOperate == true && !screen.saving }

    var body: some View {
        Form {
            if let error = screen.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("helper-presets-error") } }
            if host?.helperRouting == nil {
                ContentUnavailableView("Helper presets unavailable", systemImage: "slider.horizontal.3")
            } else if let page = screen.settings {
                if host?.helperRouting?.modes.contains("auto") == true, let auto = page.auto {
                    CompanionHelperAutoSection(store: store, screen: screen, hostID: hostID, projectID: projectID, agentID: agentID, policy: auto)
                }
                scopeLinks
                if host?.helperRouting?.quota == true {
                    Section("Plan limits") {
                        ForEach(page.providers.keys.sorted(), id: \.self) { id in
                            if let provider = page.providers[id], let quota = provider.quota {
                                DisclosureGroup {
                                    CompanionQuotaView(quota: quota, labels: page.labels, serverTime: page.serverTime, receivedAt: screen.receivedAt)
                                    if host?.helperRouting?.modes.contains("auto") == true, !provider.autoEligible, let reason = provider.reason {
                                        Text(page.label("skipped", reason)).font(.subheadline)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(providerName(id))
                                        Text(page.label("quota", quota.state)).font(.subheadline).foregroundStyle(.secondary)
                                        if let reason = quota.unknownReason { Text(page.label("unknown", reason)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .accessibilityIdentifier("helper-quota-\(id)")
                            }
                        }
                    }
                }
                if projectID == nil && agentID == nil && host?.helperRouting?.supportsPresets == true {
                    Section {
                        Text("Choose the model and effort each Auto level uses on this desktop.").font(.subheadline)
                        if host?.connection.canOperate != true { Text("Connect to the desktop to change presets.").foregroundStyle(.secondary) }
                    }
                    ForEach((host?.helperRouting?.presetProviders ?? page.providers.keys.sorted()), id: \.self) { id in
                        if let provider = page.providers[id], provider.autoEligible, !provider.cells.isEmpty {
                            providerSection(id, provider: provider, page: page)
                        }
                    }
                    if page.providers.values.contains(where: { $0.cells.values.contains { $0.custom != nil } }) {
                        Section {
                            Button("Reset all presets") { reset(.init()) }.disabled(!canEdit)
                                .accessibilityIdentifier("helper-presets-reset-all")
                        }
                    }
                }
            } else if screen.error == nil {
                ProgressView("Loading presets…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) {
            if !screen.saving && (screen.settings == nil || screen.settings?.revision != host?.helperRoutingRevision) { await load() }
        }
        .task(id: "\(screen.refreshID)|\(scenePhase == .active)|\(host?.connection.canOperate == true)|\(host?.helperRouting?.quota == true)") {
            guard scenePhase == .active, host?.connection.canOperate == true, host?.helperRouting?.quota == true,
                  let delay = screen.settings?.nextRefreshDelay else { return }
            do {
                let deadline = max(ContinuousClock.now.advanced(by: .seconds(5)), screen.receivedAt.advanced(by: .seconds(delay)))
                try await ContinuousClock().sleep(until: deadline)
                try Task.checkCancellation()
                await load()
            } catch { }
        }
        .onChange(of: host?.connection.canOperate) { _, connected in if connected == true { Task { await load() } } }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    @ViewBuilder private func providerSection(_ id: String, provider: CompanionHelperRouting.Provider, page: CompanionHelperRouting) -> some View {
        Section {
            ForEach(host?.helperRouting?.presetLevels ?? [], id: \.self) { difficulty in
                if let cell = provider.cells[difficulty] {
                    NavigationLink {
                        CompanionHelperPresetEditor(store: store, screen: screen, hostID: hostID, providerID: id, difficulty: difficulty)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(difficulty.capitalized).font(.headline)
                            Text(cell.effective?.summary ?? "None").font(.subheadline)
                            Text(cell.choiceSource).font(.caption).foregroundStyle(.secondary)
                            if cell.custom != nil, let inherited = cell.inheritanceSummary { Text(inherited).font(.caption).foregroundStyle(.secondary) }
                            Text(page.label("cell", cell.state)).font(.caption).foregroundStyle(.secondary)
                            if let fallback = cell.fallback, fallback != "none" { Text(page.label("fallback", fallback)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("helper-preset-\(id)-\(difficulty)")
                }
            }
            if provider.cells.values.contains(where: { $0.custom != nil }) {
                Button("Reset provider presets") { reset(.init(provider: id)) }.disabled(!canEdit)
            }
        } header: { Text(providerName(id)) } footer: {
            if let capability = host?.helperRouting {
                Text(page.autoCandidateText(id, capability: capability))
                    .accessibilityIdentifier("helper-preset-only-\(id)")
            }
        }
    }
    private func providerName(_ id: String) -> String { host?.providers.first { $0.id == id }?.name ?? id }
    @ViewBuilder private var scopeLinks: some View {
        if agentID == nil, host?.helperRouting?.modes.contains("auto") == true {
            if let projectID, let project = host?.projects.first(where: { $0.id == projectID }), host?.helperRouting?.scopes.contains("agent") == true {
                Section("Agents in " + project.name) {
                    ForEach(project.agents.filter { !$0.isQuick }) { agent in
                        NavigationLink(agent.name) { CompanionHelperPresetsView(store: store, hostID: hostID, agentID: agent.id.agentID) }
                            .accessibilityIdentifier("helper-auto-agent-\(agent.id.agentID)")
                    }
                }
            } else if projectID == nil && host?.helperRouting?.scopes.contains("project") == true {
                Section("Projects") {
                    ForEach(host?.projects ?? []) { project in
                        NavigationLink(project.name) { CompanionHelperPresetsView(store: store, hostID: hostID, projectID: project.id) }
                            .accessibilityIdentifier("helper-auto-project-\(project.id)")
                    }
                }
            }
        }
    }
    private func load() async {
        guard host?.helperRouting != nil else { return }
        await screen.load { try await store.helperRouting(hostID: hostID, projectID: projectID, agentID: agentID) }
    }
    private func reset(_ reset: AnnexHelperRoutingUpdate.Reset) {
        Task { await screen.save { revision in try await store.updateHelperRouting(.init(revision: revision, reset: reset), hostID: hostID) } }
    }
}

private struct CompanionHelperPresetEditor: View {
    @Bindable var store: CompanionStore
    @Bindable var screen: CompanionHelperPresetsScreen
    let hostID: String
    let providerID: String
    let difficulty: String
    @State private var model = ""
    @State private var effort: String?
    private var provider: CompanionHelperRouting.Provider? { screen.settings?.providers[providerID] }
    private var cell: CompanionHelperRouting.Cell? { provider?.cells[difficulty] }
    private var offered: CompanionHelperRouting.Model? { provider?.models.first { $0.id == model } }
    private var canEdit: Bool {
        let host = store.hosts.first { $0.id == hostID }
        return host?.connection.canOperate == true && host?.canEditHelperPresets == true && host?.helperRouting?.canEditPresets == true && cell?.editable == true && !screen.saving
    }
    var body: some View {
        Form {
            if let error = screen.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("helper-presets-error") } }
            if let cell, let page = screen.settings {
                Section("Current preset") {
                    LabeledContent("Effective", value: cell.effective?.summary ?? "None")
                    if let inherited = cell.inheritanceSummary {
                        Text(inherited).accessibilityIdentifier("helper-preset-inheritance")
                    }
                    if let custom = cell.custom { LabeledContent("Saved custom", value: custom.summary).accessibilityIdentifier("helper-preset-saved") }
                    Text(page.label("cell", cell.state))
                    if let fallback = cell.fallback, fallback != "none" { Text(page.label("fallback", fallback)) }
                }
                Section {
                    Picker("Model", selection: Binding(get: { model }, set: { model = $0; effort = nil })) {
                        ForEach(provider?.models ?? []) { model in Text(model.label).tag(model.id) }
                    }
                    .accessibilityIdentifier("helper-preset-model")
                    if let offered, offered.efforts.isEmpty {
                        Text("This model has no effort levels.")
                            .accessibilityIdentifier("helper-preset-no-effort")
                    } else {
                        Picker("Effort", selection: $effort) {
                            Text("CLI default").tag(String?.none)
                            ForEach(offered?.efforts ?? [], id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .accessibilityIdentifier("helper-preset-effort")
                    }
                    Button(screen.saving ? "Saving…" : "Save preset") {
                        Task {
                            await screen.save { revision in
                                try await store.updateHelperRouting(.init(revision: revision, cells: [.init(provider: providerID, difficulty: difficulty, model: model, effort: effort)]), hostID: hostID)
                            }
                        }
                    }
                    .disabled(offered == nil)
                    .accessibilityIdentifier("helper-preset-save")
                }
                .disabled(!canEdit)
                if cell.custom != nil {
                    Section {
                        Button("Reset preset") {
                            Task { await screen.save { revision in try await store.updateHelperRouting(.init(revision: revision, reset: .init(provider: providerID, difficulty: difficulty)), hostID: hostID) } }
                        }
                        .disabled(!canEdit).accessibilityIdentifier("helper-preset-reset")
                    }
                }
            }
        }
        .navigationTitle(difficulty.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: screen.settings, initial: true) { _, _ in
            let saved = cell?.custom ?? cell?.effective
            model = provider?.models.first { $0.id == saved?.model }?.id ?? provider?.models.first?.id ?? ""
            effort = provider?.models.first { $0.id == model }?.efforts.contains(saved?.effort ?? "") == true ? saved?.effort : nil
        }
    }
}

private struct CompanionHelperLabelsKey: EnvironmentKey {
    static let defaultValue: [String: CompanionHelperRouting.Labels] = [:]
}
extension EnvironmentValues {
    var companionHelperLabels: [String: CompanionHelperRouting.Labels] {
        get { self[CompanionHelperLabelsKey.self] }
        set { self[CompanionHelperLabelsKey.self] = newValue }
    }
}
