import SwiftUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

struct CompanionPairingSheet: View {
    let runtime: CompanionRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var port = ""
    @State private var name = ""
    @State private var identity = ""
    @State private var certificate = ""
    @State private var pin = ""
    @State private var verified = false
    @State private var remember = false
    @State private var isPairing = false
    @State private var error: String?
    @State private var discovery = AnnexDiscovery()
    @State private var nearby: [AnnexDiscoveredHost] = []
    @State private var discoveryError: Int?
    @State private var isInspecting = false
    @FocusState private var focused: Field?
    private enum Field { case address, pin }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "desktopcomputer.and.arrow.down").font(.largeTitle).foregroundStyle(Color.accentColor)
                        Text("Bring your desktop along").font(.title2.weight(.semibold))
                        Text("Open Clubhouse on your desktop, then go to Settings → Annex / Go to find its address, identity, and pairing PIN.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section("Nearby desktops") {
                    if nearby.isEmpty {
                        Label(discoveryError == nil ? "Looking for desktops on your network…" : "Nearby discovery is unavailable", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if discoveryError != nil {
                            Text("Allow Local Network access in iOS Settings, or enter a direct address below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(nearby) { host in
                        Button {
                            address = host.endpoint.host
                            port = String(host.endpoint.port)
                            name = host.name
                            identity = host.identityFingerprintHint ?? ""
                            certificate = ""
                            verified = false
                            Task { await inspect() }
                        } label: {
                            HStack {
                                Label(host.name, systemImage: "desktopcomputer")
                                Spacer()
                                if address == host.endpoint.host { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("Desktop address") {
                    TextField("Host or Tailscale address", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused, equals: .address)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Display name (optional)", text: $name)
                    Button {
                        Task { await inspect() }
                    } label: {
                        if isInspecting { ProgressView("Reading desktop certificate…") }
                        else { Label("Inspect desktop", systemImage: "checkmark.shield") }
                    }.disabled(address.isEmpty || UInt16(port) == nil || isInspecting)
                }
                Section {
                    TextField("Desktop identity fingerprint", text: $identity, axis: .vertical)
                        .font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("TLS certificate fingerprint (SHA-256)", text: $certificate, axis: .vertical)
                        .font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("These fingerprints match my desktop", isOn: $verified)
                } header: { Text("Verify your desktop") } footer: {
                    Text("Compare both fingerprints with the values shown on the desktop. A network name alone does not prove its identity.")
                }
                Section {
                    SecureField("Pairing PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focused, equals: .pin)
                    Toggle("Remember this desktop", isOn: $remember)
                } header: { Text("Connect") } footer: {
                    Text("Pairing lets this device control Clubhouse agents on your desktop. " + (remember ? "Remembering saves access in this device's Keychain and keeps this device paired on desktop." : "This device keeps access in memory until the app closes. End the pairing in Desktops & settings to revoke desktop session trust; otherwise it remains until desktop disconnect or Annex stops."))
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            }
            .disabled(isPairing)
            .navigationTitle("Pair a desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isPairing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await pair() } } label: {
                        if isPairing { ProgressView().accessibilityLabel("Pairing desktop") }
                        else { Text(remember ? "Pair & remember" : "Pair") }
                    }.disabled(!verified || address.isEmpty || port.isEmpty || identity.isEmpty || certificate.isEmpty || pin.isEmpty || isPairing)
                }
            }
            .interactiveDismissDisabled(isPairing)
            .onChange(of: address) { _, _ in verified = false }
            .onChange(of: port) { _, _ in verified = false }
            .onChange(of: identity) { _, _ in verified = false }
            .onChange(of: certificate) { _, _ in verified = false }
            .task {
                discovery.start()
                for await state in discovery.states() {
                    if Task.isCancelled { break }
                    nearby = state.hosts
                    discoveryError = state.errorCode
                }
            }
            .onDisappear { discovery.stop() }
        }
    }
    private func inspect() async {
        guard let port = UInt16(port) else { error = "Enter the port shown on your desktop."; return }
        let inspectedAddress = address
        isInspecting = true; error = nil; verified = false
        defer { isInspecting = false }
        do {
            let endpoint = try AnnexEndpoint(host: inspectedAddress, port: port)
            let candidate = try await AnnexTrustProbe.inspect(endpoint: endpoint)
            guard address == inspectedAddress, self.port == String(port) else { return }
            certificate = candidate.sha256
            focused = .pin
        } catch { self.error = CompanionLiveService.readableError(error) }
    }

    private func pair() async {
        guard verified, let port = UInt16(port) else { error = "Enter the port shown on your desktop."; return }
        isPairing = true; error = nil
        defer { isPairing = false }
        do {
            let route: AnnexEndpoint.Route = address.contains(".ts.net") ? .tailscale : .manual
            let endpoint = try AnnexEndpoint(host: address, port: port, route: route)
            let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: identity.trimmingCharacters(in: .whitespacesAndNewlines),
                                           verifiedCertificatePin: AnnexCertificatePin(sha256: certificate.trimmingCharacters(in: .whitespacesAndNewlines)))
            try await runtime.pair(host: host, pin: pin, name: name.isEmpty ? address : name, remember: remember)
            pin = ""; dismiss()
        } catch { self.error = CompanionLiveService.readableError(error) }
    }
}
