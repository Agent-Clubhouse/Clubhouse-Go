import SwiftUI

struct PairingPlaceholderView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var discovery = BonjourDiscovery()
    @State private var selectedServer: DiscoveredServer?
    @State private var manualHost: String = ""
    @State private var manualPort: String = "0"
    @State private var showManualEntry = false
    @State private var isPairing = false
    @State private var errorMessage: String?

    /// When true, this is being used to add an additional instance (presented as sheet).
    var isAddingInstance = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(store.theme.accentColor)
                .padding(24)
                .glassEffect(.regular.tint(store.theme.accentColor.opacity(0.2)), in: Circle())

            VStack(spacing: 8) {
                Text(isAddingInstance ? "Add Instance" : "Connect to Clubhouse")
                    .font(.title2.weight(.semibold))

                if selectedServer == nil && !showManualEntry {
                    Text("Searching for Clubhouse servers on your network...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                } else {
                    Text("Enter the PIN shown in Clubhouse desktop app under Settings > Go")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            // Server selection
            if !showManualEntry {
                if discovery.servers.isEmpty && discovery.isSearching {
                    ProgressView()
                        .padding()
                } else {
                    VStack(spacing: 8) {
                        ForEach(discovery.servers) { server in
                            Button {
                                selectedServer = server
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(server.name)
                                        .font(.body)

                                    if server.protocolVersion == .v2 {
                                        ChipView(text: "v2", bg: .green.opacity(0.15), fg: .green)
                                    }

                                    Spacer()

                                    // Show if already connected
                                    if store.instances.contains(where: {
                                        $0.protocolConfig.host == server.host &&
                                        $0.protocolConfig.mainPort == server.port
                                    }) {
                                        Text("Connected")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else if selectedServer == server {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedServer == server
                                              ? store.theme.surface1Color.opacity(0.6)
                                              : store.theme.surface0Color.opacity(0.4))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 40)
                }

                Button {
                    showManualEntry = true
                    discovery.stopSearching()
                } label: {
                    Text("Enter address manually")
                        .font(.caption)
                        .foregroundStyle(store.theme.linkColor)
                }
            } else {
                VStack(spacing: 12) {
                    TextField("Host (e.g. 192.168.1.100)", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }
                .frame(maxWidth: 280)

                Button {
                    showManualEntry = false
                    selectedServer = nil
                    discovery.startSearching()
                } label: {
                    Text("Search for servers instead")
                        .font(.caption)
                        .foregroundStyle(store.theme.linkColor)
                }
            }

            // PIN entry
            if selectedServer != nil || showManualEntry {
                TextField("000000", text: $pin)
                    .keyboardType(.numberPad)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pin) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { pin = filtered }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await performPairing() }
                } label: {
                    if isPairing {
                        ProgressView()
                            .frame(maxWidth: 200)
                    } else {
                        Text("Connect")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: 200)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(store.theme.accentColor)
                .disabled(pin.count < 6 || isPairing || !hasValidServer)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.baseColor)
        .onAppear {
            discovery.startSearching()
        }
        .onDisappear {
            discovery.stopSearching()
        }
    }

    private var hasValidServer: Bool {
        if showManualEntry {
            return !manualHost.isEmpty && UInt16(manualPort) != nil && UInt16(manualPort) != 0
        }
        return selectedServer != nil
    }

    private func performPairing() async {
        isPairing = true
        errorMessage = nil
        AppLog.shared.info("PairingUI", "Pairing initiated, pin=\(pin.prefix(2))****")

        if showManualEntry {
            let host = manualHost
            let port = UInt16(manualPort) ?? 0
            AppLog.shared.info("PairingUI", "Manual entry: \(host):\(port) (v1)")
            let server = DiscoveredServer(
                id: "\(host):\(port)", name: host, host: host, port: port,
                protocolVersion: .v1, pairingPort: nil, fingerprint: nil
            )
            do {
                try await store.pair(server: server, pin: pin)
                AppLog.shared.info("PairingUI", "Manual pairing succeeded")
                discovery.stopSearching()
                if isAddingInstance { dismiss() }
            } catch {
                let msg = store.activeInstance?.lastError ?? "Connection failed"
                AppLog.shared.error("PairingUI", "Manual pairing failed: \(error) — showing: \(msg)")
                errorMessage = msg
            }
        } else if let server = selectedServer {
            AppLog.shared.info("PairingUI", "Discovered server: \(server.name) (\(server.host):\(server.port)) proto=\(server.protocolVersion == .v2 ? "v2" : "v1") pairingPort=\(server.pairingPort.map(String.init) ?? "nil")")
            do {
                try await store.pair(server: server, pin: pin)
                AppLog.shared.info("PairingUI", "Pairing succeeded")
                discovery.stopSearching()
                if isAddingInstance { dismiss() }
            } catch {
                let msg = (error as? APIError)?.userMessage ?? "Connection failed"
                AppLog.shared.error("PairingUI", "Pairing failed: \(error) — showing: \(msg)")
                errorMessage = msg
            }
        } else {
            AppLog.shared.error("PairingUI", "No server selected and not manual entry — nothing to pair")
        }

        isPairing = false
    }
}

#Preview {
    PairingPlaceholderView()
        .environment(AppStore())
}
