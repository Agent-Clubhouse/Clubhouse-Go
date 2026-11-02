import SwiftUI
import ClubhouseTransport

/// Shared by Settings and the preview's Settings sheet. One page per desktop: presets are app-wide.
struct CompanionHelperPresetLinks: View {
    @Bindable var store: CompanionStore
    var body: some View {
        let hosts = store.hosts.filter { $0.helperRouting?.supportsPresets == true }
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
    @State private var screen = CompanionHelperPresetsScreen()
    @Environment(\.scenePhase) private var scenePhase
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    private var refreshKey: String { "\(host?.helperRoutingRevision ?? "")|\(host?.connection.canOperate == true)" }
    private var canEdit: Bool { host?.canEditHelperPresets == true && host?.connection.canOperate == true && !screen.saving }

    var body: some View {
        Form {
            if let error = screen.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("helper-presets-error") } }
            if host?.helperRouting == nil {
                ContentUnavailableView("Helper presets unavailable", systemImage: "slider.horizontal.3")
            } else if let page = screen.settings {
                Section {
                    Text("Choose the model and effort each difficulty uses on this desktop.").font(.subheadline)
                    if host?.connection.canOperate != true { Text("Connect to the desktop to change presets.").foregroundStyle(.secondary) }
                }
                ForEach(page.providers.keys.sorted(), id: \.self) { id in
                    if let provider = page.providers[id], !provider.cells.isEmpty {
                        providerSection(id, provider: provider, page: page)
                    }
                }
                if page.providers.values.contains(where: { $0.cells.values.contains { $0.custom != nil } }) {
                    Section {
                        Button("Reset all presets") { reset(.init()) }.disabled(!canEdit)
                            .accessibilityIdentifier("helper-presets-reset-all")
                    }
                }
            } else if screen.error == nil {
                ProgressView("Loading presets…")
            }
        }
        .navigationTitle("Helper presets")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) {
            if screen.settings == nil || screen.settings?.revision != host?.helperRoutingRevision { await load() }
        }
        .onChange(of: host?.connection.canOperate) { _, connected in if connected == true { Task { await load() } } }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    @ViewBuilder private func providerSection(_ id: String, provider: CompanionHelperRouting.Provider, page: CompanionHelperRouting) -> some View {
        Section {
            ForEach(host?.helperRouting?.difficulties ?? [], id: \.self) { difficulty in
                if let cell = provider.cells[difficulty] {
                    NavigationLink {
                        CompanionHelperPresetEditor(store: store, screen: screen, hostID: hostID, providerID: id, difficulty: difficulty)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(difficulty.capitalized).font(.headline)
                            Text(cell.effective?.summary ?? "None").font(.subheadline)
                            Text(cell.custom == nil ? "Built-in" : "Custom").font(.caption).foregroundStyle(.secondary)
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
        } header: { Text(host?.providers.first { $0.id == id }?.name ?? id) }
    }
    private func load() async {
        guard host?.helperRouting != nil else { return }
        await screen.load { try await store.helperRouting(hostID: hostID) }
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
        return host?.connection.canOperate == true && host?.canEditHelperPresets == true && cell?.editable == true && !screen.saving
    }
    var body: some View {
        Form {
            if let error = screen.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("helper-presets-error") } }
            if let cell, let page = screen.settings {
                Section("Current preset") {
                    LabeledContent("Effective", value: cell.effective?.summary ?? "None")
                    if let custom = cell.custom { LabeledContent("Saved custom", value: custom.summary).accessibilityIdentifier("helper-preset-saved") }
                    Text(page.label("cell", cell.state))
                    if let fallback = cell.fallback, fallback != "none" { Text(page.label("fallback", fallback)) }
                }
                Section {
                    Picker("Model", selection: Binding(get: { model }, set: { model = $0; effort = nil })) {
                        ForEach(provider?.models ?? []) { model in Text(model.label).tag(model.id) }
                    }
                    .accessibilityIdentifier("helper-preset-model")
                    Picker("Effort", selection: $effort) {
                        Text("CLI default").tag(String?.none)
                        ForEach(offered?.efforts ?? [], id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("helper-preset-effort")
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
