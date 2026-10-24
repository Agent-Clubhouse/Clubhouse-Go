import SwiftUI
import Framebriar
import FramebriarUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor @Observable final class CompanionRuntime {
    let feedback: FeedbackModel?
    let service: CompanionLiveService
    let store: CompanionStore
    let registry: AnnexTransportRegistry
    let lifecycle: CompanionLifecycle
    var restoreError: String?
    var isRestoring = false
    private(set) var sessionHosts: Set<String> = []
    private var started = false

    init(registry: AnnexTransportRegistry = AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: Bool = true) {
        self.feedback = persistsDrafts ? CompanionFeedback.makeModel() : nil
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
        if remember { sessionHosts.remove(host.hostID) }
        else { sessionHosts.insert(host.hostID) }
        await service.register(registration)
    }
    func forget(hostID: String) async throws {
        try await registry.remove(hostID: hostID)
        sessionHosts.remove(hostID)
        service.remove(hostID: hostID)
        if store.selection?.hostID == hostID { store.selection = nil }
    }
    func endSession(hostID: String) async throws {
        try await registry.revokeSessionAndRemove(hostID: hostID)
        sessionHosts.remove(hostID)
        service.remove(hostID: hostID)
        if store.selection?.hostID == hostID { store.selection = nil }
    }
}

struct CompanionAppRoot: View {
    @State private var runtime: CompanionRuntime
    @State private var showPairing = false
    @State private var showSettings = false
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeFeedbackEnabled = true
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
            .shakeToOpenFeedback(model: runtime.feedback, enabled: shakeFeedbackEnabled,
                                 isPresenting: showPairing || showSettings || runtime.restoreError != nil || runtime.isRestoring)
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
            .task(id: scenePhase) {
                guard let feedback = runtime.feedback else { return }
                await feedback.setActive(scenePhase == .active)
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await feedback.tick()
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let feedback = runtime.feedback, let status = feedback.status,
                   status.canSubmit && [.expired, .accessRequired, .offline].contains(status.access) {
                    Button("Feedback access: \(status.access.rawValue). Reports stay on this device. Open Settings.") { showSettings = true }
                        .font(.caption).padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
                }
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
            if ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_MANUAL_TEST"] == "1" { showPairing = true; return }
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
    @State private var hostToEnd: CompanionHost?
    @State private var removingHostID: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Diagnostics") {
                    NavigationLink("Connection diagnostics") { CompanionDiagnosticsView() }
                }
                CompanionFeedbackSettings(model: runtime.feedback)
                Section("Your desktops") {
                    ForEach(runtime.store.hosts) { host in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(host.name, systemImage: "desktopcomputer").font(.headline)
                            Text(host.endpoint).font(.subheadline).foregroundStyle(.secondary)
                            Text(host.connection.label).font(.caption)
                            Text(runtime.sessionHosts.contains(host.id) ? "Session-only pairing" : "Remembered desktop").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Connection details") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Verified desktop identity").font(.caption).foregroundStyle(.secondary)
                                    Text(host.id).font(.caption.monospaced()).textSelection(.enabled)
                                    // Explicit styles keep each action independent inside this List row.
                                    // Automatic row activation can otherwise invoke sibling buttons too.
                                    Button("Reconnect") { Task { await runtime.store.reconnect(hostID: host.id) } }
                                        .buttonStyle(.borderless)
                                    if runtime.sessionHosts.contains(host.id), host.canRevokeSession {
                                        Button("End session pairing", role: .destructive) { hostToEnd = host }
                                            .buttonStyle(.borderless)
                                            .disabled(!host.connection.canOperate)
                                    }
                                    Button("Forget on this device", role: .destructive) { hostToForget = host }
                                        .buttonStyle(.borderless)
                                }.padding(.vertical, 8)
                            }.font(.subheadline)
                        }.padding(.vertical, 6).disabled(removingHostID == host.id)
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
            .onAppear { AnnexTelemetry.shared.record(.settings) }
            .navigationTitle("Desktops & settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget \(hostToForget?.name ?? "desktop")?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }), titleVisibility: .visible) {
                if let host = hostToForget {
                    Button("Forget desktop", role: .destructive) {
                        Task {
                            removingHostID = host.id
                            defer { removingHostID = nil }
                            do { try await runtime.forget(hostID: host.id) }
                            catch { self.error = CompanionLiveService.readableError(error) }
                            hostToForget = nil
                        }
                    }
                }
            } message: { Text("This removes access from this device. Desktop trust remains until you disconnect this device in desktop settings or stop Annex for a session-only pairing. Running agents are unaffected.") }
            .confirmationDialog("End this session pairing?", isPresented: Binding(get: { hostToEnd != nil }, set: { if !$0 { hostToEnd = nil } }), titleVisibility: .visible) {
                if let host = hostToEnd {
                    Button("End session pairing", role: .destructive) {
                        Task {
                            removingHostID = host.id
                            defer { removingHostID = nil }
                            do { try await runtime.endSession(hostID: host.id) }
                            catch { self.error = CompanionLiveService.readableError(error) }
                            hostToEnd = nil
                        }
                    }
                }
            } message: { Text("This asks the desktop to revoke this device's session access, then removes it here. Your agents keep running.") }
        }
    }
}
