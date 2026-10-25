import SwiftUI
import Framebriar
import FramebriarUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor @Observable final class CompanionRuntime {
    let telemetryExporter = AnnexOTLPExporter()
    let feedback: FeedbackModel?
    let service: CompanionLiveService
    let store: CompanionStore
    let registry: AnnexTransportRegistry
    let lifecycle: CompanionLifecycle
    let preferences: CompanionPreferences
    var restoreError: String?
    var isRestoring = false
    private(set) var sessionHosts: Set<String> = []
    private var started = false

    init(registry: AnnexTransportRegistry = AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: Bool = true) {
        self.feedback = persistsDrafts ? CompanionFeedback.makeModel() : nil
        self.registry = registry
        // Integration runs keep their sort, order and theme choices out of the real app's defaults.
        self.preferences = persistsDrafts ? CompanionPreferences() : CompanionPreferences(defaults: UserDefaults(suiteName: "companion-integration") ?? .standard)
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
    /// `name` is the desktop's, shown on this phone. The desktop is told this phone's own name.
    func pair(host: TrustedAnnexHost, pin: String, name: String?, remember: Bool) async throws {
        try await pair(host: host, pin: pin, names: CompanionPairingNames(deviceName: preferences.pairingAlias, desktopName: name), remember: remember)
    }
    private func pair(host: TrustedAnnexHost, pin: String, names: CompanionPairingNames, remember: Bool) async throws {
        let registration = try await registry.pair(host: host, pin: pin, alias: names.alias, label: names.desktopLabel,
                                                   persistence: remember ? .persistent : .sessionOnly)
        preferences.saveDeviceName()
        if remember { sessionHosts.remove(host.hostID) }
        else { sessionHosts.insert(host.hostID) }
        await service.register(registration)
    }
    /// Pairs from a scanned or opened QR invitation. Tries each advertised address in order and only pairs
    /// with one whose TLS certificate is the one in the code; the identity is checked during pairing.
    func pair(link: CompanionPairingLink, remember: Bool) async throws {
        let pin = try AnnexCertificatePin(sha256: link.certificate)
        var lastError: Error = CompanionServiceError.unavailable("Couldn't reach your desktop. Check that this phone is on the same network.")
        for address in link.hosts {
            do {
                let endpoint = try AnnexEndpoint(host: address, port: link.port)
                guard try await AnnexTrustProbe.inspect(endpoint: endpoint) == pin else {
                    lastError = CompanionServiceError.rejected("The desktop at \(address) isn't the one that showed this code.")
                    continue
                }
                let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: link.identity, verifiedCertificatePin: pin)
                try await pair(host: host, pin: link.pin, names: CompanionPairingNames(deviceName: preferences.pairingAlias, link: link), remember: remember)
                return
            } catch { lastError = error }
        }
        throw lastError
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
    /// A pairing invitation opened from the iPhone Camera (`clubhousego://pair?...`).
    @State private var openedLink: CompanionPairingLink?
    @State private var showSettings = false
    @State private var diagnostics = AnnexDiagnosticSettings.shared
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeFeedbackEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Only the integration worker supplies this explicit test invitation.
        // It selects an in-memory registry and never writes a saved pairing.
        let testMode = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil
        if !testMode { CompanionInstallReset.clearLeftoversIfFreshInstall() }
        _runtime = State(initialValue: CompanionRuntime(registry: testMode ? AnnexTransportRegistry() : AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: !testMode))
        #else
        // Before the runtime restores pairings or the feedback client reads its enrollment.
        CompanionInstallReset.clearLeftoversIfFreshInstall()
        _runtime = State(initialValue: CompanionRuntime())
        #endif
    }
    var body: some View {
        CompanionRootView(store: runtime.store, preferences: runtime.preferences, onPair: { showPairing = true }, onSettings: { showSettings = true })
            .sheet(isPresented: $showPairing, onDismiss: { openedLink = nil }) {
                CompanionPairingSheet(runtime: runtime, link: openedLink).companionTheme(runtime.preferences.sharedTheme(hosts: runtime.store.hosts))
            }
            .onOpenURL { url in
                guard let link = CompanionPairingLink(url: url) else { return }
                showSettings = false
                openedLink = link
                showPairing = true
            }
            .sheet(isPresented: $showSettings) {
                CompanionSettingsSheet(runtime: runtime, pair: { showSettings = false; showPairing = true })
                    .companionTheme(runtime.preferences.sharedTheme(hosts: runtime.store.hosts))
            }
            .shakeToOpenFeedback(model: runtime.feedback, enabled: shakeFeedbackEnabled,
                                 isPresenting: showPairing || showSettings || runtime.restoreError != nil || runtime.isRestoring)
            .shakeToExplainFeedbackEnrollment(model: runtime.feedback, enabled: $shakeFeedbackEnabled,
                                              isPresenting: showPairing || showSettings || runtime.restoreError != nil || runtime.isRestoring)
            .overlay(alignment: .top) {
                if runtime.isRestoring { ProgressView("Restoring desktops…").padding(.horizontal, 18).padding(.vertical, 12).glassEffect(.regular, in: .capsule).padding() }
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
            .task(id: "\(scenePhase)-\(diagnostics.revision)-\(diagnostics.mode)-\(diagnostics.remoteEnabled)-\(diagnostics.destination?.backendReference.uuidString ?? "none")") {
                guard let session = await runtime.telemetryExporter.beginSession() else { return }
                guard scenePhase == .active else { await runtime.telemetryExporter.endSession(session); return }
                while !Task.isCancelled {
                    await runtime.telemetryExporter.flush(configuration: diagnostics.destination,
                        enabled: diagnostics.remoteEnabled && diagnostics.mode != .off,
                        records: AnnexTelemetry.shared.snapshot().records, session: session)
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                }
                await runtime.telemetryExporter.endSession(session)
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
                    CompanionDeviceNameField(preferences: runtime.preferences)
                } header: { Text("This phone") } footer: {
                    Text(CompanionDeviceNameField.footer + " Desktops paired before a change keep the old name until you pair again.")
                }
                CompanionFeedbackSettings(model: runtime.feedback)
                Section("Advanced") {
                    NavigationLink("Connection diagnostics") { CompanionDiagnosticsView(exporter: runtime.telemetryExporter) }
                    Label("Direct connection", systemImage: "network")
                    Text("Connect over the same local network or a direct Tailscale address. Your agents keep running on your desktop when you leave the app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .onAppear { AnnexTelemetry.shared.record(.settings) }
            .navigationTitle("Settings")
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

