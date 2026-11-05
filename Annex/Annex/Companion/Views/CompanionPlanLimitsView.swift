import SwiftUI
import ClubhouseTransport

struct CompanionPlanLimitsLink: View {
    @Bindable var store: CompanionStore
    var body: some View {
        if !store.hosts.isEmpty {
            Section {
                NavigationLink { CompanionPlanLimitsView(store: store) } label: {
                    Label("Plan limits", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("settings-plan-limits")
            }
        }
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
                    machine(group)
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
            await screen.refresh(hosts: store.hosts) { try await store.helperRouting(hostID: $0) }
        }
    }
    @ViewBuilder private func machine(_ group: CompanionPlanLimitsGroup) -> some View {
        if let unavailable = group.unavailableText {
            Text(unavailable).foregroundStyle(.secondary).accessibilityIdentifier("plan-limits-unavailable-\(group.id)")
            if case .failed(let message) = group.host.connection { Text(message).font(.subheadline) }
        } else {
            let reading = screen.readings[group.id]
            if let error = reading?.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("plan-limits-error-\(group.id)")
            }
            if let page = reading?.settings {
                if group.providerIDs(in: page).isEmpty { Text("No connected providers reported by this desktop.").foregroundStyle(.secondary) }
                ForEach(group.providerIDs(in: page), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.host.providers.first { $0.id == id }?.name ?? id).font(.headline)
                        if let quota = page.providers[id]?.quota {
                            if reading?.error == nil || quota.asOf != nil {
                                if reading?.error != nil { Text("Last reading · refresh failed").font(.caption).foregroundStyle(.secondary) }
                                CompanionQuotaView(quota: quota, labels: page.labels, serverTime: page.serverTime, receivedAt: reading?.receivedAt, showsProgress: true)
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
