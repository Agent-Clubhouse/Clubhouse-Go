import SwiftUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

struct CompanionPairingSheet: View {
    let runtime: CompanionRuntime
    /// A scanned or opened QR invitation. When set, the sheet confirms it instead of showing manual pairing.
    @State private var invitation: CompanionPairingLink?
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var port = ""
    @State private var name = ""
    @State private var identity = ""
    @State private var certificate = ""
    @State private var pin = ""
    @State private var verified = false
    @State private var remember = true
    @State private var isPairing = false
    @State private var error: String?
    @State private var discovery = AnnexDiscovery()
    @State private var nearby: [AnnexDiscoveredHost] = []
    @State private var discoveryError: Int?
    @State private var isInspecting = false
    @FocusState private var focused: Field?
    private enum Field { case address, pin }

    init(runtime: CompanionRuntime, link: CompanionPairingLink? = nil) {
        self.runtime = runtime
        _invitation = State(initialValue: link)
    }

    var body: some View {
        NavigationStack {
            if let invitation {
                CompanionInvitationView(runtime: runtime, link: invitation,
                                        onScanAgain: { self.invitation = nil; scanning = true }, onPaired: { dismiss() })
            } else {
                manualPairing
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            CompanionQRScannerView(onFound: { link in invitation = link; scanning = false }, onCancel: { scanning = false })
        }
    }

    /// Nearby or typed address, then fingerprints and the PIN.
    private var manualPairing: some View {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "desktopcomputer.and.arrow.down").font(.largeTitle).foregroundStyle(Color.accentColor)
                        Text("Bring your desktop along").font(.title2.weight(.semibold))
                        Text("Open Clubhouse on your desktop, then go to Settings → Annex to find its address, identity, and pairing PIN.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section {
                    Button { scanning = true } label: {
                        Label("Scan the pairing code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                } footer: {
                    Text("Clubhouse shows the code in Settings → Annex. You can also scan it with the iPhone Camera. Or pair manually below.")
                }
                .listRowBackground(Color.clear)
                Section("Nearby desktops") {
                    if nearby.isEmpty {
                        Label(discoveryError == nil ? "Looking for desktops on your network…" : "Nearby discovery is unavailable", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if discoveryError != nil {
                            Text("Discovery may be blocked by Local Network access or by this network. Check iOS Settings, or enter the desktop address and port below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if discoveryError != nil {
                        Button("Scan again") { discovery.stop(); discovery.start() }
                    }
                    Text("Nearby names are unverified. Tailscale peers and networks that block multicast may need manual entry.").font(.caption).foregroundStyle(.secondary)
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
                    TextField("IP address, hostname, or host:port", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focused, equals: .address)
                    TextField("Port (unless included above)", text: $port).keyboardType(.numberPad)
                    TextField("Display name (optional)", text: $name)
                    Button {
                        Task { await inspect() }
                    } label: {
                        if isInspecting { ProgressView("Reading desktop certificate…") }
                        else { Label("Inspect desktop", systemImage: "checkmark.shield") }
                    }.disabled((try? AnnexEndpoint.manual(address: address, port: port)) == nil || isInspecting)
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
            .scrollDismissesKeyboard(.interactively)
            .disabled(isPairing)
            .navigationTitle("Pair a desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isPairing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await pair() } } label: {
                        if isPairing { ProgressView().accessibilityLabel("Pairing desktop") }
                        else { Text(remember ? "Pair & remember" : "Pair") }
                    }.disabled(!verified || (try? AnnexEndpoint.manual(address: address, port: port)) == nil || identity.isEmpty || certificate.isEmpty || pin.isEmpty || isPairing)
                }
            }
            .interactiveDismissDisabled(isPairing)
            .onChange(of: address) { _, _ in verified = false }
            .onChange(of: port) { _, _ in verified = false }
            .onChange(of: identity) { _, _ in verified = false }
            .onChange(of: certificate) { _, _ in verified = false }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_MANUAL_TEST"] == "1",
                   let json = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"],
                   let bytes = json.data(using: .utf8),
                   let fixture = try? JSONDecoder().decode(ManualFixture.self, from: bytes) {
                    // Explicit simulator fixture only: never restore real sessions,
                    // browse the LAN, auto-verify, or print the fixture PIN.
                    address = "\(fixture.host):\(fixture.port)"; identity = fixture.hostID
                    name = fixture.name ?? "Integration desktop"; pin = fixture.pin
                    return
                }
                #endif
                discovery.start()
                for await state in discovery.states() {
                    if Task.isCancelled { break }
                    nearby = state.hosts
                    discoveryError = state.errorCode
                }
            }
            .onDisappear { discovery.stop() }
    }
    #if DEBUG
    private struct ManualFixture: Decodable { let host: String; let port: UInt16; let hostID: String; let name: String?; let pin: String }
    #endif
    private func inspect() async {
        let diagnostic = AnnexTelemetry.shared.begin(.manualAddress)
        defer { diagnostic.end() }
        let inspectedAddress = address
        let inspectedPort = port
        isInspecting = true; error = nil; verified = false
        defer { isInspecting = false }
        do {
            let endpoint = try AnnexEndpoint.manual(address: inspectedAddress, port: inspectedPort)
            let candidate = try await AnnexTrustProbe.inspect(endpoint: endpoint)
            guard address == inspectedAddress, self.port == inspectedPort else { return }
            let digits = Array(candidate.sha256.uppercased())
            certificate = stride(from: 0, to: digits.count, by: 2).map { String(digits[$0..<$0 + 2]) }.joined(separator: ":")
            focused = nil
        } catch { diagnostic.fail(error); self.error = CompanionLiveService.readableError(error) }
    }

    private func pair() async {
        guard verified else { return }
        isPairing = true; error = nil
        defer { isPairing = false }
        do {
            let endpoint = try AnnexEndpoint.manual(address: address, port: port)
            let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: identity.trimmingCharacters(in: .whitespacesAndNewlines),
                                           verifiedCertificatePin: AnnexCertificatePin(sha256: certificate.trimmingCharacters(in: .whitespacesAndNewlines)))
            try await runtime.pair(host: host, pin: pin, name: name.isEmpty ? address : name, remember: remember)
            pin = ""; dismiss()
        } catch { self.error = CompanionLiveService.readableError(error) }
    }
}
