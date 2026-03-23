import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Instances", systemImage: "desktopcomputer")
                        Spacer()
                        Text("\(store.connectedInstances.count) connected")
                            .foregroundStyle(store.theme.accentColor)
                    }
                    HStack {
                        Label("Agents", systemImage: "cpu")
                        Spacer()
                        Text("\(store.runningAgentCount) running")
                            .foregroundStyle(store.theme.accentColor)
                        Text("/ \(store.totalAgentCount)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Theme", systemImage: "paintpalette")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(store.theme.accentColor).frame(width: 10, height: 10)
                            Circle().fill(store.theme.baseColor).frame(width: 10, height: 10)
                            Circle().fill(store.theme.surface0Color).frame(width: 10, height: 10)
                        }
                        Text("Synced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Overview")
                }

                Section {
                    ForEach(store.instances) { instance in
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instance.serverName.isEmpty ? "Server" : instance.serverName)
                                    .font(.body)
                                Text("\(instance.protocolConfig.host):\(instance.protocolConfig.mainPort)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            connectionBadge(instance.connectionState)
                        }
                    }
                } header: {
                    Text("Connected Instances")
                }

                if let error = store.activeInstance?.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section("Debug") {
                    NavigationLink {
                        LogViewerView()
                    } label: {
                        HStack {
                            Label("Logs", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Text("\(AppLog.shared.entries.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        store.disconnectAll()
                        dismiss()
                    } label: {
                        Label("Disconnect All", systemImage: "wifi.slash")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        store.resetApp()
                        dismiss()
                    } label: {
                        Label("Reset App", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Clears all data and returns to the welcome screen.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(store.theme.baseColor)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func connectionBadge(_ state: ConnectionState) -> some View {
        switch state {
        case .connected:
            Text("Connected")
                .font(.caption)
                .foregroundStyle(.green)
        case .reconnecting(let attempt):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Retry \(attempt)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            Text("Disconnected")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return Text("").sheet(isPresented: .constant(true)) {
        SettingsView()
            .environment(store)
    }
}
