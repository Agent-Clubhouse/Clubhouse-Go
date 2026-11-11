import SwiftUI
import ClubhouseTransport

struct CompanionAppUpdateLink: View {
    @Bindable var store: CompanionStore
    let host: CompanionHost
    var body: some View {
        if host.canUpdateApp {
            NavigationLink {
                CompanionAppUpdateView(store: store, hostID: host.id)
            } label: {
                Label(host.appUpdate.map { CompanionAppUpdateText.indicator($0, desktop: host.name) } ?? "Desktop updates on \(host.name)",
                      systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("app-update-\(host.id)")
        }
    }
}

struct CompanionAppUpdateView: View {
    @Bindable var store: CompanionStore
    let hostID: String
    @State private var confirmingRequest = false
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    var body: some View {
        let notices = (store.decisionNotices[hostID] ?? []).filter { $0.target == nil }
        List {
            if !notices.isEmpty { CompanionDecisionNoticesView(store: store, notices: notices) }
            if let host, host.canUpdateApp {
                if let update = host.appUpdate {
                    Section {
                        Text(CompanionAppUpdateText.indicator(update, desktop: host.name)).font(.headline)
                        if update.state == .downloading { ProgressView(value: update.downloadProgress, total: 100) }
                        if let reason = update.reason { Text(reason) }
                        if let request = update.request {
                            Text(CompanionAppUpdateText.requestState(request))
                                .accessibilityIdentifier("app-update-request-state")
                            if let expires = request.expiresAt {
                                Text("Deadline: \(expires)").font(.caption).foregroundStyle(.secondary)
                            }
                            if request.canCancel {
                                Button("Cancel update request", role: .destructive) {
                                    Task { await store.cancelAppUpdate(hostID: hostID) }
                                }
                                .accessibilityIdentifier("app-update-cancel")
                                .disabled(!host.connection.canOperate || store.appUpdateInFlight.contains(hostID))
                            }
                        }
                        if update.canRequest {
                            Button("Request update") { confirmingRequest = true }
                                .accessibilityIdentifier("app-update-request")
                                .disabled(!host.connection.canOperate || store.appUpdateInFlight.contains(hostID))
                        }
                        if let outcome = host.appUpdateOutcome { Text(outcome) }
                    }
                    Section("Before restarting") {
                        Text(CompanionAppUpdateText.restart)
                        Text("Queued turns and messages still being delivered count as work. Headless runs end and do not resume. Terminal idle detection uses recent output, not a guarantee of task completion.")
                        Text(CompanionAppUpdateText.platform)
                        Text(CompanionAppUpdateText.pairing)
                        Text("Requesting only asks for approval in Needs you. It does not check for or download updates, enable the Dispatcher, or run a paid prompt.")
                    }
                }
                if let error = store.appUpdateErrors[hostID] ?? host.appUpdateError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("app-update-error")
                }
                if !host.connection.canOperate { Text(host.connection.detail) }
            } else {
                Text("This desktop does not offer updates from your phone.")
            }
        }
        .navigationTitle("Desktop update")
        .alert("Request update on \(host?.name ?? "desktop")?", isPresented: $confirmingRequest) {
            Button("Request update") { Task { await store.requestAppUpdate(hostID: hostID) } }
                .disabled(host?.connection.canOperate != true || store.appUpdateInFlight.contains(hostID))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only creates an approval in Needs you. \(CompanionAppUpdateText.restart)")
        }
    }
}
