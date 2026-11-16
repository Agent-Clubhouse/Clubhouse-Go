import SwiftUI
import ClubhouseTransport

struct CompanionPlanLimitsLink: View {
    @Bindable var store: CompanionStore
    var settingsRows = false
    var body: some View {
        if !store.hosts.isEmpty {
            if settingsRows { row } else { Section { row } }
        }
    }
    private var row: some View {
        NavigationLink { CompanionPlanLimitsView(store: store) } label: {
            if settingsRows {
                CompanionSettingsRowLabel("Plan limits", symbol: "chart.bar", tone: .success)
            } else { Label("Plan limits", systemImage: "chart.bar") }
        }.accessibilityIdentifier("settings-plan-limits")
    }
}

struct CompanionPlanLimitsView: View {
    @Bindable var store: CompanionStore
    @State private var screen = CompanionPlanLimitsScreen()
    @Environment(\.scenePhase) private var scenePhase
    private var groups: [CompanionPlanLimitsGroup] { CompanionPlanLimitsGroup.groups(store.hosts) }
    private var refreshKey: String {
        "\(scenePhase == .active)|" + store.hosts.map { "\($0.id):\($0.connection):\($0.helperRouting?.quota == true):\($0.helperRoutingRevision ?? "")" }.joined(separator: "|")
    }
    var body: some View {
        List {
            if groups.isEmpty {
                Text("No desktops paired.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    CompanionPlanLimitsMachine(group: group, reading: screen.readings[group.id])
                } header: {
                    if groups.count > 1 { Text(group.host.name) }
                }
            }
        }
        .navigationTitle("Plan limits")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) {
            guard scenePhase == .active else { return }
            await withTaskGroup(of: Void.self) { tasks in
                for group in groups where group.canRead {
                    tasks.addTask { @MainActor in
                        await screen.poll(hostID: group.id) { try await store.helperRouting(hostID: $0) }
                    }
                }
            }
        }
        .refreshable {
            guard scenePhase == .active else { return }
            CompanionUIActions.record(.refresh, on: .planLimits)
            await screen.refresh(hosts: store.hosts) { try await store.helperRouting(hostID: $0) }
        }
    }

}

/// The Settings page and the agent sheet share unknown, offline and stale-reading presentation.
private struct CompanionPlanLimitsMachine: View {
    let group: CompanionPlanLimitsGroup
    let reading: CompanionHelperPresetsScreen?
    var providerID: String? = nil

    private func providerIDs(in page: CompanionHelperRouting) -> [String] {
        providerID.map { [$0] } ?? group.providerIDs(in: page)
    }
    @ViewBuilder var body: some View {
        if let unavailable = group.unavailableText {
            Text(unavailable).foregroundStyle(.secondary).accessibilityIdentifier("plan-limits-unavailable-\(group.id)")
            if case .failed(let message) = group.host.connection { Text(message).font(.subheadline) }
        } else {
            if let error = reading?.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("plan-limits-error-\(group.id)")
            }
            if let page = reading?.settings {
                if providerIDs(in: page).isEmpty { Text("No connected providers reported by this desktop.").foregroundStyle(.secondary) }
                ForEach(providerIDs(in: page), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        // The desktop catalog supplies displayName/shortName; routing-only IDs have no label in v1.
                        Text(group.host.providers.first { $0.id == id }?.name ?? id).font(.headline)
                        if let quota = page.providers[id]?.quota {
                            if reading?.error == nil || quota.asOf != nil {
                                if reading?.error != nil { Text("Last reading · refresh failed").font(.caption).foregroundStyle(.secondary) }
                                CompanionQuotaView(quota: quota, labels: page.labels, serverTime: page.serverTime, receivedAt: reading?.receivedAt, showsProgress: true, showsReadingDate: reading?.error != nil)
                            } else { Text("No dated reading available.").foregroundStyle(.secondary) }
                        } else {
                            Text(page.label("quota", "unknown"))
                            Text(page.label("unknown", "not_read")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("plan-limits-\(group.id)-\(id)")
                }
            } else if reading?.error == nil { ProgressView("Checking plan limits…") }
        }
    }
}

/// Only the current agent's provider on its desktop. The endpoint returns a desktop page;
/// filtering is explicit and never turns a missing provider into another account's reading.
struct CompanionAgentPlanLimitsSection: View {
    @Bindable var store: CompanionStore
    let scope: CompanionAgentPlanLimitsScope
    @State private var screen = CompanionPlanLimitsScreen()
    @Environment(\.scenePhase) private var scenePhase

    private var group: CompanionPlanLimitsGroup? { scope.group(in: store.hosts) }
    private var refreshKey: String {
        "\(scenePhase == .active)|\(scope.hostID)|\(scope.providerID ?? "")|\(String(describing: group?.host.connection))|\(group?.canRead == true)|\(group?.host.helperRoutingRevision ?? "")"
    }

    var body: some View {
        Section {
            if let group {
                if let providerID = scope.providerID {
                    CompanionPlanLimitsMachine(group: group, reading: screen.readings[group.id], providerID: providerID)
                } else {
                    Text("This agent’s provider is unknown.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("companion-context-provider-unknown")
                    if let unavailable = group.unavailableText { Text(unavailable).foregroundStyle(.secondary) }
                }
            } else {
                Text("Desktop unavailable. Reported values may be out of date.").foregroundStyle(.secondary)
                    .accessibilityIdentifier("companion-context-desktop-unavailable")
            }
        } header: {
            Text(group.map { "Agent plan · \($0.host.name)" } ?? "Agent plan")
        }
        .task(id: refreshKey) {
            guard scenePhase == .active, let host = scope.readableHosts(in: store.hosts).first else { return }
            await screen.poll(hostID: host.id) { try await store.helperRouting(hostID: $0) }
        }
    }
}
