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
    private var rediscovering: Set<String> = []
    private var nextRediscovery: [String: Date] = [:]

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
        self.store = CompanionStore(service: service, draftPersistence: persistsDrafts ? CompanionLocalDrafts() : nil,
                                    finishedPersistence: persistsDrafts ? CompanionLocalFinished() : nil)
    }
    func start() async {
        guard !started else { return }
        started = true; isRestoring = true
        store.start()
        service.onUnreachable = { [weak self] hostID in Task { await self?.rediscover(hostID: hostID) } }
        service.onRoutes = { [weak self] hostID, routes in
            guard let self else { return }
            Task { try? await self.registry.learnRoutes(hostID: hostID, routes.endpoints) }
        }
        service.prepareResume = { [weak self] in await self?.switchToAnsweringRoutes() ?? [] }
        defer { isRestoring = false }
        do {
            for registration in try await registry.restoreSaved() { await service.register(await answeringRoute(for: registration)) }
        } catch { restoreError = CompanionLiveService.readableError(error) }
    }
    /// The desktop at the first of its saved routes that answers with its pinned certificate, so opening
    /// the app away from home goes straight to Tailscale instead of waiting out the home address.
    private func answeringRoute(for registration: AnnexTransportRegistry.Registration) async -> AnnexTransportRegistry.Registration {
        let routes = await registry.routes(for: registration.host.hostID)
        guard routes.count > 1,
              let best = await AnnexRediscovery.firstAnswering(registration.host, routes: routes, probe: { try await AnnexTrustProbe.inspect(endpoint: $0) }),
              !best.sameAddress(as: registration.host.endpoint) else { return registration }
        return (try? await registry.relocate(hostID: registration.host.hostID, to: best)) ?? registration
    }
    /// Back in the foreground, maybe on another network: move each desktop to a route that answers.
    private func switchToAnsweringRoutes() async -> Set<String> {
        var moved: Set<String> = []
        for registration in await registry.all() {
            let best = await answeringRoute(for: registration)
            guard !best.host.endpoint.sameAddress(as: registration.host.endpoint) else { continue }
            await service.register(best)
            moved.insert(best.host.hostID)
        }
        return moved
    }
    /// `name` is the desktop's, shown on this phone. The desktop is told this phone's own name.
    func pair(host: TrustedAnnexHost, pin: String, name: String?, remember: Bool) async throws {
        try await pair(host: host, pin: pin, names: CompanionPairingNames(deviceName: preferences.pairingAlias, desktopName: name), remember: remember)
    }
    private func pair(host: TrustedAnnexHost, pin: String, names: CompanionPairingNames, routes: [AnnexEndpoint] = [], remember: Bool) async throws {
        let registration = try await registry.pair(host: host, pin: pin, alias: names.alias, label: names.desktopLabel, routes: routes,
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
        let routes = link.hosts.compactMap { try? AnnexEndpoint.advertised(host: $0, port: link.port) }
        guard let first = routes.first else { throw CompanionServiceError.unavailable("This pairing code has no address. Show a new code on your desktop.") }
        let candidate = try TrustedAnnexHost(endpoint: first, verifiedHostID: link.identity, verifiedCertificatePin: pin)
        // Every address in the code at once (home Wi-Fi, Tailscale): only one serving the code's certificate counts.
        guard let endpoint = await AnnexRediscovery.firstAnswering(candidate, routes: routes, timeout: .seconds(10), probe: {
            try await AnnexTrustProbe.inspect(endpoint: $0)
        }) else {
            throw CompanionServiceError.unavailable("Couldn't reach the desktop that showed this code. Check that this phone is on the same Wi-Fi, or on Tailscale.")
        }
        let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: link.identity, verifiedCertificatePin: pin)
        try await pair(host: host, pin: link.pin, names: CompanionPairingNames(deviceName: preferences.pairingAlias, link: link), routes: routes, remember: remember)
    }
    /// A paired desktop stopped answering at its saved address, e.g. the Mac was renamed on the network.
    /// Look for it nearby for a few seconds, at most once a minute; it moves only to an address that
    /// serves the certificate pinned at pairing.
    private func rediscover(hostID: String) async {
        guard !rediscovering.contains(hostID),
              let registration = await registry.all().first(where: { $0.host.hostID == hostID }) else { return }
        let host = registration.host
        rediscovering.insert(hostID)
        defer { rediscovering.remove(hostID) }
        // Known routes first (Tailscale away from home): fast, and works off the local network.
        let moved = await answeringRoute(for: registration)
        if !moved.host.endpoint.sameAddress(as: host.endpoint) { await service.register(moved); return }
        guard Date() >= nextRediscovery[hostID, default: .distantPast] else { return }
        defer { nextRediscovery[hostID] = Date().addingTimeInterval(60) }
        let discovery = AnnexDiscovery()
        discovery.start()
        defer { discovery.stop() }
        var tried: Set<AnnexEndpoint> = []
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            let fresh = discovery.discovered.filter { !tried.contains($0.endpoint) }
            tried.formUnion(fresh.map(\.endpoint))
            guard !fresh.isEmpty, let endpoint = await AnnexRediscovery.locate(host, in: fresh, probe: {
                try await AnnexTrustProbe.inspect(endpoint: $0)
            }) else { continue }
            // It may have come back on its own while we looked.
            guard store.hosts.first(where: { $0.id == hostID })?.connection.canOperate != true,
                  let registration = try? await registry.relocate(hostID: hostID, to: endpoint) else { return }
            await service.register(registration)
            return
        }
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
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var shakeAttachesScreenshot = true
    /// Set once someone moves past the welcome screen; deleting the app shows it again.
    @AppStorage("companion.welcomeDone") private var welcomeDone = false
    @State private var showDemo = false
    private var showsWelcome = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Only the integration worker supplies this explicit test invitation.
        // It selects an in-memory registry and never writes a saved pairing.
        let testMode = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil
        if !testMode { CompanionInstallReset.clearLeftoversIfFreshInstall() }
        showsWelcome = !testMode
        _runtime = State(initialValue: CompanionRuntime(registry: testMode ? AnnexTransportRegistry() : AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: !testMode))
        #else
        // Before the runtime restores pairings or the feedback client reads its enrollment.
        CompanionInstallReset.clearLeftoversIfFreshInstall()
        _runtime = State(initialValue: CompanionRuntime())
        #endif
    }
    var body: some View {
        ZStack {
            CompanionRootView(store: runtime.store, preferences: runtime.preferences, onPair: { showPairing = true }, onSettings: { showSettings = true })
            if showsWelcome && !welcomeDone && runtime.store.hosts.isEmpty && !runtime.isRestoring {
                CompanionWelcomeView(onPair: { welcomeDone = true; showPairing = true }, onDemo: { showDemo = true })
                    .companionTheme(runtime.preferences.sharedTheme(hosts: runtime.store.hosts))
                    .transition(.opacity)
            }
        }
            .fullScreenCover(isPresented: $showDemo) {
                CompanionDemoView(onPair: { showDemo = false; welcomeDone = true; showPairing = true }, onClose: { showDemo = false })
                    .companionTheme(runtime.preferences.sharedTheme(hosts: runtime.store.hosts))
            }
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
                                 isPresenting: showPairing || showSettings || runtime.restoreError != nil || runtime.isRestoring,
                                 captureScreen: shakeAttachesScreenshot)
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
                // Only when the person must act. Offline is temporary: reports stay queued and
                // retry on their own, and Settings shows the state.
                if let feedback = runtime.feedback, let status = feedback.status,
                   status.canSubmit && [.expired, .accessRequired].contains(status.access) {
                    Button("Feedback needs a new invitation. Reports stay on this device. Open Settings.") { showSettings = true }
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
                                    Button("Retry") { Task { await runtime.store.reconnect(hostID: host.id) } }
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
                    Picker("Fold idle projects after", selection: Bindable(runtime.preferences).idleDays) {
                        ForEach(CompanionIdleRule.dayChoices, id: \.self) { days in
                            Text(days == 0 ? "Never" : "\(days) days").tag(days)
                        }
                    }
                } header: { Text("Home") } footer: {
                    let shared = runtime.store.hosts.filter(\.sharesProjectState).map(\.name)
                    Text("Unpinned projects with no running agent and no activity for this long fold into one idle section. Kept on this phone."
                         + (shared.isEmpty ? "" : " \(shared.formatted(.list(type: .and))) \(shared.count == 1 ? "shares its" : "share their") pins and idle projects, and \(shared.count == 1 ? "uses its" : "use their") own setting."))
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

