import SwiftUI
import ClubhouseTransport

struct CompanionAppUpdateCheckAction: View {
    @Environment(\.companionTelemetryScreen) private var screen
    @Bindable var store: CompanionStore
    let host: CompanionHost
    var body: some View {
        if host.canCheckAppUpdate, let update = host.appUpdate {
            if update.state == .none || update.state == .available {
                let checking = store.appUpdateChecksInFlight.contains(host.id)
                let alreadyChecking = store.isAlreadyCheckingAppUpdate(hostID: host.id)
                Button(alreadyChecking ? "Already checking" : checking ? "Checking…" : "Check for updates") {
                    CompanionUIActions.record(.checkForUpdates, on: screen)
                    Task { await store.checkAppUpdate(hostID: host.id) }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("app-update-check")
                .disabled(!host.connection.canOperate || checking || alreadyChecking)
            }
            if let error = store.appUpdateCheckErrors[host.id] {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("app-update-check-error")
            }
        }
    }
}

struct CompanionAppUpdateLink: View {
    @Bindable var store: CompanionStore
    let host: CompanionHost
    var settingsRow = false
    @Environment(\.companionHomeScrollAnchor) private var homeAnchor

    var body: some View {
        #if DEBUG
        let _ = homeAnchor.map { _ in CompanionHomeBuildProbe.record?(.appUpdate) }
        #endif
        if host.hasAppUpdateAffordance {
            NavigationLink {
                CompanionAppUpdateView(store: store, hostID: host.id)
            } label: {
                let title = host.appUpdate.map { CompanionAppUpdateText.indicator($0, desktop: host.name) } ?? "Desktop updates on \(host.name)"
                if settingsRow {
                    CompanionSettingsRowLabel(title, symbol: "arrow.down.circle", tone: .info)
                } else { Label(title, systemImage: "arrow.down.circle") }
            }
            .accessibilityIdentifier("app-update-\(host.id)")
        } else if host.canUpdateApp, let update = host.appUpdate {
            VStack(alignment: .leading, spacing: 4) {
                Text(CompanionAppUpdateText.status(update))
                    .accessibilityIdentifier("app-update-status")
                if update.state != .none {
                    Text("Running \(update.currentVersion)").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = update.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                CompanionAppUpdateCheckAction(store: store, host: host)
            }
        } else if host.canUpdateApp {
            Text(host.appUpdateError ?? "Desktop update status is not available yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CompanionAppUpdateView: View {
    @Bindable var store: CompanionStore
    let hostID: String
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    var body: some View {
        let notices = (store.decisionNotices[hostID] ?? []).filter { $0.target == nil }
        List {
            if !notices.isEmpty { CompanionDecisionNoticesView(store: store, notices: notices) }
            if let host, host.canUpdateApp {
                if let update = host.appUpdate {
                    Section {
                        Text(CompanionAppUpdateText.status(update)).font(.headline)
                            .accessibilityIdentifier("app-update-status")
                        Text("Running \(update.currentVersion) on \(host.name)").font(.subheadline).foregroundStyle(.secondary)
                        if update.state == .downloading {
                            ProgressView(value: update.downloadProgress, total: 100)
                                .accessibilityIdentifier("app-update-progress")
                        }
                        if update.state == .downloading || update.state == .available {
                            Text("Restart will be available when the download finishes.")
                        }
                        if update.state == .none {
                            if !host.canCheckAppUpdate { Text("Check for updates on the desktop.") }
                        }
                        CompanionAppUpdateCheckAction(store: store, host: host)
                        if let reason = update.reason { Text(reason) }
                        if let request = update.request {
                            Text(CompanionAppUpdateText.requestState(request))
                                .accessibilityIdentifier("app-update-request-state")
                            if let expires = request.expiresAt {
                                Text("Deadline: \(expires)").font(.caption).foregroundStyle(.secondary)
                            }

                            if request.state == .pendingApproval && host.appUpdateApproval == nil {
                                ProgressView("Waiting for the desktop's interruption review…")
                            }
                            if request.canCancel && host.appUpdateApproval == nil {
                                Button("Cancel update request", role: .destructive) {
                                    CompanionUIActions.record(.cancelUpdate, on: .desktopUpdate)
                                    Task { await store.cancelAppUpdate(hostID: hostID) }
                                }
                                .accessibilityIdentifier("app-update-cancel")
                                .disabled(!host.connection.canOperate || store.appUpdateInFlight.contains(hostID))
                            }
                        }
                        if update.canRequest, let version = update.availableVersion {
                            if host.canRequestAppUpdate {
                                Button("Restart to update to \(version)") {
                                    CompanionUIActions.record(.restartForUpdate, on: .desktopUpdate)
                                    Task { await store.requestAppUpdate(hostID: hostID) }
                                }
                                .buttonStyle(.borderedProminent).companionProminentLabel().controlSize(.large)
                                .accessibilityIdentifier("app-update-request")
                                .disabled(!host.connection.canOperate || store.appUpdateInFlight.contains(hostID))
                            } else {
                                Text("Requesting a restart needs the Dispatcher on and available. You can also use the desktop update banner.")
                                if let dispatcher = host.dispatcher, !dispatcher.enabled {
                                    if let blocker = dispatcher.turnOnBlocker { Text(blocker) }
                                    else {
                                        Button("Turn on Dispatcher") {
                                            CompanionUIActions.record(.toggleDispatcher, on: .desktopUpdate)
                                            Task { await store.setDispatcher(enabled: true, hostID: hostID) }
                                        }
                                        .accessibilityIdentifier("app-update-enable-dispatcher")
                                        .disabled(!host.connection.canOperate || store.dispatcherSwitching.contains(hostID))
                                    }
                                }
                                if let error = store.dispatcherErrors[hostID] { Text(error).foregroundStyle(.red) }
                            }
                        }
                        if let outcome = host.appUpdateOutcome { Text(outcome) }
                    }
                    if let approval = host.appUpdateApproval {
                        Section("Restart to update to \(approval.update?.version ?? update.availableVersion ?? update.currentVersion)") {
                            CompanionGrantRequestActions(request: approval, store: store, showsOpenChat: false)
                        }
                    }
                    Section("Before restarting") {
                        Text(CompanionAppUpdateText.restart)
                        Text("Queued turns and messages still being delivered count as work. Headless runs end and do not resume. Terminal idle detection uses recent output, not a guarantee of task completion.")
                        Text(CompanionAppUpdateText.platform)
                        Text(CompanionAppUpdateText.pairing)
                        Text("Requesting shows your restart choices here. It does not check for or download updates, enable the Dispatcher, or run a paid prompt.")
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
        .companionTelemetryScreen(.desktopUpdate)
        .navigationTitle("Desktop update")
    }
}
