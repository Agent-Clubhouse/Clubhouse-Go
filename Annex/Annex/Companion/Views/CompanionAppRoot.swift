import SwiftUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor @Observable final class CompanionRuntime {
    let service: CompanionLiveService
    let store: CompanionStore
    let registry: AnnexTransportRegistry
    let lifecycle: CompanionLifecycle
    var restoreError: String?
    var isRestoring = false
    private var started = false

    init(registry: AnnexTransportRegistry = AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: Bool = true) {
        self.registry = registry
        let service = CompanionLiveService()
        self.service = service
        self.lifecycle = CompanionLifecycle { active in
            if active { await service.resume() }
            else { await service.suspend() }
        }
        self.store = CompanionStore(service: service, draftPersistence: persistsDrafts ? CompanionLocalDrafts() : nil)
    }
    func start() async {
        guard !started else { return }
        started = true; isRestoring = true
        store.start()
        defer { isRestoring = false }
        do {
            for registration in try await registry.restoreSaved() { await service.register(registration) }
        } catch { restoreError = CompanionLiveService.readableError(error) }
    }
    func pair(host: TrustedAnnexHost, pin: String, name: String, remember: Bool) async throws {
        let registration = try await registry.pair(host: host, pin: pin, alias: name,
                                                   persistence: remember ? .persistent : .sessionOnly)
        await service.register(registration)
    }
    func forget(hostID: String) async throws {
        try await registry.remove(hostID: hostID)
        service.remove(hostID: hostID)
        if store.selection?.hostID == hostID { store.selection = nil }
    }
}

struct CompanionAppRoot: View {
    @State private var runtime: CompanionRuntime
    @State private var showPairing = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Only the integration worker supplies this explicit test invitation.
        // It selects an in-memory registry and never writes a saved pairing.
        let testMode = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil
        _runtime = State(initialValue: CompanionRuntime(registry: testMode ? AnnexTransportRegistry() : AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: !testMode))
        #else
        _runtime = State(initialValue: CompanionRuntime())
        #endif
    }
    var body: some View {
        CompanionRootView(store: runtime.store, onPair: { showPairing = true }, onSettings: { showSettings = true })
            .sheet(isPresented: $showPairing) { CompanionPairingSheet(runtime: runtime) }
            .sheet(isPresented: $showSettings) { CompanionSettingsSheet(runtime: runtime, pair: { showSettings = false; showPairing = true }) }
            .overlay(alignment: .top) {
                if runtime.isRestoring { ProgressView("Restoring desktops…").padding().background(.regularMaterial, in: Capsule()).padding() }
            }
            .alert("Could not restore desktops", isPresented: Binding(get: { runtime.restoreError != nil }, set: { if !$0 { runtime.restoreError = nil } })) {
                Button("OK") { runtime.restoreError = nil }
            } message: { Text(runtime.restoreError ?? "") }
            .task {
                await runtime.start()
                #if DEBUG
                await bootstrapIntegrationIfRequested()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: runtime.lifecycle.update(.active)
                case .background: runtime.lifecycle.update(.background)
                default: runtime.lifecycle.update(.inactive)
                }
            }
    }

    #if DEBUG
    private func bootstrapIntegrationIfRequested() async {
        guard let json = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"],
              let data = json.data(using: .utf8) else { return }
        struct TestInvitation: Decodable { var host: String; var port: UInt16; var hostID: String; var certificatePin: String; var pin: String; var name: String? }
        do {
            let config = try JSONDecoder().decode(TestInvitation.self, from: data)
            let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: config.host, port: config.port), verifiedHostID: config.hostID,
                                            verifiedCertificatePin: AnnexCertificatePin(sha256: config.certificatePin))
            try await runtime.pair(host: host, pin: config.pin, name: config.name ?? "Integration desktop", remember: false)
        } catch { runtime.restoreError = CompanionLiveService.readableError(error) }
    }
    #endif
}

struct CompanionSettingsSheet: View {
    @Bindable var runtime: CompanionRuntime
    var pair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hostToForget: CompanionHost?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Your desktops") {
                    ForEach(runtime.store.hosts) { host in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(host.name, systemImage: "desktopcomputer").font(.headline)
                            Text(host.endpoint).font(.subheadline).foregroundStyle(.secondary)
                            Text(host.connection.label).font(.caption)
                            DisclosureGroup("Connection details") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Verified desktop identity").font(.caption).foregroundStyle(.secondary)
                                    Text(host.id).font(.caption.monospaced()).textSelection(.enabled)
                                    Button("Reconnect") { Task { await runtime.store.reconnect(hostID: host.id) } }
                                    Button("Forget desktop", role: .destructive) { hostToForget = host }
                                }.padding(.vertical, 8)
                            }.font(.subheadline)
                        }.padding(.vertical, 6)
                    }
                    Button("Pair another desktop", systemImage: "plus", action: pair)
                }
                Section {
                    Label("Direct connection", systemImage: "network")
                    Text("Connect over the same local network or a direct Tailscale address. Your agents keep running on your desktop when you leave the app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Desktops & settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget \(hostToForget?.name ?? "desktop")?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }), titleVisibility: .visible) {
                if let host = hostToForget {
                    Button("Forget desktop", role: .destructive) {
                        Task {
                            do { try await runtime.forget(hostID: host.id) }
                            catch { self.error = CompanionLiveService.readableError(error) }
                            hostToForget = nil
                        }
                    }
                }
            } message: { Text("This removes its saved access from this device. Running desktop agents are unaffected.") }
        }
    }
}
