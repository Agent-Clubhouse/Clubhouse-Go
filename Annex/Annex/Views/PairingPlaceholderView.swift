import SwiftUI

struct PairingPlaceholderView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var discovery = BonjourDiscovery()
    @State private var selectedServer: DiscoveredServer?
    @State private var isPairing = false
    @State private var errorMessage: String?

    // Manual address entry (for Tailscale / non-mDNS networks)
    @State private var showManualEntry = false
    @State private var manualAddressInput: String = ""
    @State private var manualPairingPortInput: String = ""
    @State private var manualEntryError: String?

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

                if selectedServer == nil {
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

            // Manual entry takes over the body once activated
            if showManualEntry {
                manualEntrySection
            } else if discovery.permissionDenied {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text("Local Network Access Required")
                        .font(.subheadline.weight(.semibold))
                    Text("Go to Settings > Privacy & Security > Local Network and enable access for Clubhouse Go.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else if discovery.servers.isEmpty && discovery.searchTimedOut {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No Servers Found")
                        .font(.subheadline.weight(.semibold))
                    Text("Make sure Clubhouse desktop is running with Go enabled in Settings, and that your phone is on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Retry") {
                        discovery.stopSearching()
                        discovery.startSearching()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else if discovery.servers.isEmpty && discovery.isSearching {
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

            // "Enter address manually" — always available while discovering, hidden once manual form is open
            if !showManualEntry && selectedServer == nil && !discovery.permissionDenied {
                Button {
                    showManualEntry = true
                    discovery.stopSearching()
                } label: {
                    Text("Enter address manually")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }

            // PIN entry (for discovered servers; manual flow shows its own Connect button)
            if selectedServer != nil && !showManualEntry {
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
                .disabled(pin.count < 6 || isPairing || selectedServer == nil)
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

    // MARK: - Manual entry

    private var manualEntrySection: some View {
        VStack(spacing: 12) {
            Text("Enter the server address from Clubhouse desktop. Use IP or hostname, with optional :port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            TextField("e.g. 100.64.0.5 or my-host.tail.ts.net:8443", text: $manualAddressInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .padding(.horizontal, 40)

            DisclosureGroup("Advanced") {
                HStack {
                    Text("Pairing port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField(
                        String(ManualServerAddress.defaultPairingPort),
                        text: $manualPairingPortInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 100)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .padding(.horizontal, 40)

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

            if let manualEntryError {
                Text(manualEntryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Back") {
                    showManualEntry = false
                    manualEntryError = nil
                    errorMessage = nil
                    discovery.startSearching()
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await submitManualEntry() }
                } label: {
                    if isPairing {
                        ProgressView()
                            .frame(maxWidth: 120)
                    } else {
                        Text("Connect")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: 120)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(store.theme.accentColor)
                .disabled(pin.count < 6 || isPairing || manualAddressInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func submitManualEntry() async {
        manualEntryError = nil
        errorMessage = nil

        guard let parsed = ManualServerAddress.parse(manualAddressInput) else {
            manualEntryError = "Enter a valid host (e.g. 100.64.0.5 or my-host.local:8443)"
            return
        }

        let pairingPort: UInt16
        let trimmedPP = manualPairingPortInput.trimmingCharacters(in: .whitespaces)
        if trimmedPP.isEmpty {
            pairingPort = ManualServerAddress.defaultPairingPort
        } else if let p = UInt16(trimmedPP), p > 0 {
            pairingPort = p
        } else {
            manualEntryError = "Pairing port must be a number between 1 and 65535"
            return
        }

        let manualServer = DiscoveredServer(
            id: "manual:\(parsed.host):\(parsed.mainPort)",
            name: parsed.host,
            host: parsed.host,
            port: parsed.mainPort,
            pairingPort: pairingPort,
            fingerprint: ""
        )

        isPairing = true
        AppLog.shared.info("PairingUI", "Manual pair to \(parsed.host):\(parsed.mainPort) pairingPort=\(pairingPort)")
        do {
            try await store.pair(server: manualServer, pin: pin)
            AppLog.shared.info("PairingUI", "Manual pairing succeeded")
            if isAddingInstance { dismiss() }
        } catch {
            let msg = (error as? APIError)?.userMessage ?? "Connection failed"
            AppLog.shared.error("PairingUI", "Manual pairing failed: \(error) — showing: \(msg)")
            manualEntryError = msg
        }
        isPairing = false
    }

    private func performPairing() async {
        guard let server = selectedServer else { return }
        isPairing = true
        errorMessage = nil
        AppLog.shared.info("PairingUI", "Pairing initiated, pin=\(pin.prefix(2))****")

        AppLog.shared.info("PairingUI", "Discovered server: \(server.name) (\(server.host):\(server.port)) pairingPort=\(server.pairingPort)")
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

        isPairing = false
    }
}

#Preview {
    PairingPlaceholderView()
        .environment(AppStore())
}
