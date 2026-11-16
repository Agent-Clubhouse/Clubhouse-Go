import SwiftUI
import Framebriar
import FramebriarUI
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

@MainActor @Observable final class CompanionRuntime {
    nonisolated deinit {
        // Keep owned subtrees alive until a real main-actor task, avoiding the iOS 26.0
        // isolated-deinit task-local runtime bug during UIKit's deferred root destruction.
        Task { @MainActor [feedback, appTelemetry, feedbackPresenter, store, service, lifecycle] in
            feedbackPresenter.stop()
            store.shutdown()
            appTelemetry?.stop()
            await lifecycle.settle()
            await service.shutdown()
            withExtendedLifetime((feedback, appTelemetry, feedbackPresenter, store, lifecycle)) {}
        }
    }

    let telemetryExporter = AnnexOTLPExporter()
    let feedback: FeedbackModel?
    /// Enrollment-gated Framebriar telemetry; nil in test mode or when feedback isn't configured.
    let appTelemetry: CompanionTelemetry?
    let feedbackPresenter: CompanionFeedbackPresenter
    let service: CompanionLiveService
    let store: CompanionStore
    let registry: AnnexTransportRegistry
    let lifecycle: CompanionLifecycle
    let preferences: CompanionPreferences
    var restoreError: String?
    var isRestoring = false
    private(set) var sessionHosts: Set<String> = []
    private(set) var restoredHostIDs: Set<String>?
    private var started = false
    private var rediscovering: Set<String> = []
    private var nextRediscovery: [String: Date] = [:]
    private var syncingNetworkRegistrations = false

    init(registry: AnnexTransportRegistry = AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: Bool = true) {
        #if DEBUG
        assert(!UIApplication.shared.supportsMultipleScenes, "CompanionRuntime requires a single app scene")
        let feedback = CompanionSceneTestSupport.makeFeedback?() ?? (persistsDrafts ? CompanionFeedback.makeModel() : nil)
        #else
        let feedback = persistsDrafts ? CompanionFeedback.makeModel() : nil
        #endif
        self.feedback = feedback?.model
        self.appTelemetry = feedback?.telemetry
        appTelemetry?.start()
        self.feedbackPresenter = CompanionFeedbackPresenter(model: self.feedback)
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
        #if DEBUG
        CompanionSceneTestSupport.didCreateRuntime?(self)
        #endif
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
        service.onNetwork = { [weak self] hostID, snapshot in
            guard let self else { return }
            do {
                try await self.registry.reconcileNetwork(snapshot, from: hostID)
                await self.registry.introduceNetworkMembers()
                await self.syncNetworkRegistrations()
            } catch { self.restoreError = CompanionLiveService.readableError(error) }
        }
        service.onNetworkRefusal = { [weak self] hostID in
            guard let self else { return }
            do {
                try await self.registry.networkPeerNotPaired(hostID: hostID)
                await self.syncNetworkRegistrations()
            } catch { self.restoreError = CompanionLiveService.readableError(error) }
        }
        service.prepareResume = { [weak self] in await self?.switchToAnsweringRoutes() ?? [] }
        defer { isRestoring = false }
        do {
            #if DEBUG
            let restored: [AnnexTransportRegistry.Registration]
            if let restore = CompanionSceneTestSupport.restoreRegistrations { restored = try await restore() }
            else { restored = try await registry.restoreSaved() }
            #else
            let restored = try await registry.restoreSaved()
            #endif
            restoredHostIDs = Set(restored.map { $0.host.hostID })
            for registration in restored { await service.register(await answeringRoute(for: registration)) }
        } catch { restoreError = CompanionLiveService.readableError(error) }
    }
    private func syncNetworkRegistrations() async {
        guard !syncingNetworkRegistrations else { return }
        syncingNetworkRegistrations = true
        defer { syncingNetworkRegistrations = false }
        // Re-read after every pass: another membership callback or re-pair may
        // replace a registration while service.register is suspended.
        while true {
            let registrations = await registry.all()
            let current = Set(registrations.map { $0.host.hostID })
            let removed = service.registeredHostIDs.subtracting(current)
            let changed = registrations.filter { !service.hasRegistration($0) }
            guard !removed.isEmpty || !changed.isEmpty else { return }
            for id in removed {
                service.remove(hostID: id)
                restoredHostIDs?.remove(id)
                sessionHosts.remove(id)
                if store.selection?.hostID == id { store.selection = nil }
            }
            for registration in changed {
                restoredHostIDs?.insert(registration.host.hostID)
                // Rebinding the sender cancels its old event/refresh task. The
                // replacement must connect outside that cancelled caller task.
                await Task { [service] in await service.register(registration) }.value
            }
        }
    }
    /// The desktop at the first of its saved routes that answers with its pinned certificate, so opening
    /// the app away from home goes straight to Tailscale instead of waiting out the home address.
    private func answeringRoute(for registration: AnnexTransportRegistry.Registration) async -> AnnexTransportRegistry.Registration {
        let routes = await registry.routes(for: registration.host.hostID)
        guard !Task.isCancelled, routes.count > 1,
              let best = await AnnexRediscovery.firstAnswering(registration.host, routes: routes, probe: { try await AnnexTrustProbe.inspect(endpoint: $0) }),
              !Task.isCancelled, !best.sameAddress(as: registration.host.endpoint) else { return registration }
        return (try? await registry.relocate(hostID: registration.host.hostID, to: best)) ?? registration
    }
    /// Back in the foreground, maybe on another network: move each desktop to a route that answers.
    // The optional resolver is call-scoped for deterministic route-race tests; production
    // uses the existing pinned route probe and never stores an injected callback.
    func switchToAnsweringRoutes(resolveRoute: ((AnnexTransportRegistry.Registration) async -> AnnexTransportRegistry.Registration)? = nil) async -> Set<String> {
        var moved: Set<String> = []
        for registration in await registry.all() {
            guard !Task.isCancelled else { return moved }
            let best = if let resolveRoute { await resolveRoute(registration) } else { await answeringRoute(for: registration) }
            guard !Task.isCancelled else { return moved }
            let current = await registry.all().first { $0.host.hostID == best.host.hostID }
            guard !Task.isCancelled else { return moved }
            // Route resolution suspends: a newer pairing/relocation may now own this host.
            guard current?.transportID == best.transportID else { continue }
            // A cancelled earlier relocation may have committed its new route only in the registry.
            // The exact transport identity changes with that route; presence alone is insufficient.
            guard !service.hasRegistration(best) else { continue }
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
        restoredHostIDs?.insert(host.hostID)
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
        restoredHostIDs?.remove(hostID)
        service.remove(hostID: hostID)
        if store.selection?.hostID == hostID { store.selection = nil }
    }
    func endSession(hostID: String) async throws {
        try await registry.revokeSessionAndRemove(hostID: hostID)
        sessionHosts.remove(hostID)
        restoredHostIDs?.remove(hostID)
        service.remove(hostID: hostID)
        if store.selection?.hostID == hostID { store.selection = nil }
    }
}

struct CompanionAppRoot: View {
    let runtimeLifetime: CompanionStateLifetime<CompanionRuntime>
    private var runtime: CompanionRuntime { runtimeLifetime.value }
    @State private var showPairing = false
    /// A pairing invitation opened from the iPhone Camera (`clubhousego://pair?...`).
    @State private var openedLink: CompanionPairingLink?
    @State private var settingsCapture: CompanionFeedbackSettingsCapture?
    @State private var diagnostics = AnnexDiagnosticSettings.shared
    @AppStorage(CompanionFeedback.shakePreferenceKey) private var shakeFeedbackEnabled = true
    @AppStorage(CompanionFeedback.shakeScreenshotPreferenceKey) private var shakeAttachesScreenshot = true
    /// Set once someone moves past the welcome screen; deleting the app shows it again.
    @AppStorage("companion.welcomeDone") private var welcomeDone = false
    @State private var showDemo = false
    private var showsWelcome = true
    @Environment(\.scenePhase) private var scenePhase

    private func openSettings() {
        $settingsCapture.releasingFeedbackScreenshot.wrappedValue = CompanionFeedbackSettingsCapture(window: CompanionFeedbackPresenter.keyWindow())
    }

    init(runtimeLifetime: CompanionStateLifetime<CompanionRuntime>) {
        self.runtimeLifetime = runtimeLifetime
        #if DEBUG
        let testMode = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil || (ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") || ProcessInfo.processInfo.arguments.contains("--companion-root-ui-testing"))
        showsWelcome = !testMode
        #endif
    }
    var body: some View {
        ZStack {
            CompanionRootView(store: runtime.store, preferences: runtime.preferences,
                              onPair: { [showPairing = $showPairing] in showPairing.wrappedValue = true },
                              onSettings: { [settingsCapture = $settingsCapture.releasingFeedbackScreenshot] in
                                  settingsCapture.wrappedValue = CompanionFeedbackSettingsCapture(window: CompanionFeedbackPresenter.keyWindow())
                              }, pairedHostIDs: runtime.restoredHostIDs)
                .companionFeedbackEntryPoints(runtime.feedbackPresenter)
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
                $settingsCapture.releasingFeedbackScreenshot.wrappedValue = nil
                openedLink = link
                showPairing = true
            }
            .sheet(item: $settingsCapture.releasingFeedbackScreenshot) { capture in
                CompanionSettingsSheet(runtime: runtime, initialCapture: capture, pair: { $settingsCapture.releasingFeedbackScreenshot.wrappedValue = nil; showPairing = true })
                    .companionTheme(runtime.preferences.sharedTheme(hosts: runtime.store.hosts))
            }
            .companionFeedbackShake(runtime.feedbackPresenter, enabled: shakeFeedbackEnabled,
                                    suppressed: showPairing || runtime.restoreError != nil || runtime.isRestoring,
                                    captureScreen: shakeAttachesScreenshot)
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
            .onChange(of: runtime.feedback?.status?.queued) { previous, current in
                guard let feedback = runtime.feedback else { return }
                Task {
                    await CompanionFeedback.deliverNewlyQueued(model: feedback, previous: previous, current: current,
                                                              isBackground: scenePhase == .background)
                }
            }
            // Inactive is a transient foreground interruption (including screenshot previews).
            // Keep the pump alive through it; pause only on background, like the transport.
            .task(id: scenePhase == .background) {
                guard let feedback = runtime.feedback else { return }
                // Synchronous lifecycle checkpointing belongs to CompanionTelemetry, before SDK flush.
                await feedback.setActive(scenePhase != .background)
                guard scenePhase != .background else { return }
                #if DEBUG
                CompanionSceneTestSupport.feedbackPumpChanged?(true)
                defer { CompanionSceneTestSupport.feedbackPumpChanged?(false) }
                #endif
                while !Task.isCancelled {
                    await feedback.tick()
                    runtime.appTelemetry?.tick()
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Only when the person must act. Offline is temporary: reports stay queued and
                // retry on their own, and Settings shows the state.
                if let feedback = runtime.feedback, let status = feedback.status,
                   status.canSubmit && [.expired, .accessRequired].contains(status.access) {
                    Button("Feedback needs a new invitation. Reports stay on this device. Open Settings.") {
                        CompanionUIActions.record(.openSettings, on: .feedbackPrompt)
                        openSettings()
                    }
                        .font(.caption).padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            // A recreated root must apply its current phase to the surviving runtime,
            // including an initial active phase after the old root suspended it.
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    #if DEBUG
                    AnnexTelemetry.shared.record(.foreground, event: .scenePhaseObserved)
                    #endif
                    runtime.lifecycle.update(.active)
                case .background:
                    #if DEBUG
                    AnnexTelemetry.shared.record(.background, event: .scenePhaseObserved)
                    #endif
                    runtime.lifecycle.update(.background)
                default: runtime.lifecycle.update(.inactive)
                }
            }
    }

    #if DEBUG
    private func bootstrapIntegrationIfRequested() async {
        guard let json = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"],
              let data = json.data(using: .utf8) else { return }
        if ProcessInfo.processInfo.environment["CLUBHOUSE_E2E_CONNECTION_TRACE"] == "1",
           !CompanionSceneTestSupport.liveConnectionTraceInstalled {
            // Closed diagnostic vocabulary only. XCTest captures stdout in its result bundle: no host, path,
            // invitation, certificate, identity or arbitrary error string is ever written here.
            AnnexTelemetry.shared.setEnabled(true)
            CompanionSceneTestSupport.liveConnectionTraceInstalled = true
            let trace = CompanionLiveConnectionTrace()
            AnnexTelemetry.shared.observeRecords { trace.append($0) }
        }
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
    var initialCapture: CompanionFeedbackSettingsCapture? = nil
    var pair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hostToForget: CompanionHost?
    @State private var hostToEnd: CompanionHost?
    @State private var removingHostID: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                CompanionSettingsSections(store: runtime.store, preferences: runtime.preferences,
                    feedback: runtime.feedback, initialCapture: initialCapture, exporter: runtime.telemetryExporter,
                    sessionHosts: runtime.sessionHosts, removingHostID: removingHostID, operationError: error, pair: pair,
                    forget: { hostToForget = $0 }, endSession: { hostToEnd = $0 })
                if let error { Section { Text(error).foregroundStyle(.red) } }
                CompanionBuildInfoSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        CompanionUIActions.record(.close, on: .settings)
                        dismiss()
                    }.companionToolbarClose()
                        .accessibilityIdentifier("settings-close")
                }
            }
            .companionTelemetryScreen(.settings)
        }
        .confirmationDialog("Forget \(hostToForget?.name ?? "desktop")?", isPresented: Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } }), titleVisibility: .visible) {
            if let host = hostToForget {
                Button("Forget desktop", role: .destructive) {
                    CompanionUIActions.record(.confirm, on: .desktopSettings)
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
                    CompanionUIActions.record(.confirm, on: .desktopSettings)
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


struct CompanionDesktopConnectionActions: View {
    let host: CompanionHost
    var isSessionOnly = false
    var retry: () -> Void
    var forget: () -> Void
    var endSession: () -> Void = {}
    var body: some View {
        Section("Connection details") {
            Text("Verified desktop identity").font(.caption).foregroundStyle(.secondary)
            Text(host.id).font(.caption.monospaced()).textSelection(.enabled)
            if let notice = host.snapshotTruncationNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("snapshot-truncation-\(host.id)")
            }
        }
        Section {
            Button {
                CompanionUIActions.record(.retry, on: .desktopSettings)
                retry()
            } label: {
                CompanionSettingsRowLabel("Retry", symbol: "arrow.clockwise", tone: .accent)
            }.accessibilityIdentifier("desktop-connection-retry")
            if isSessionOnly, host.canRevokeSession {
                Button(role: .destructive) {
                    CompanionUIActions.record(.revokeSession, on: .desktopSettings)
                    endSession()
                } label: {
                    CompanionSettingsRowLabel("End session pairing", symbol: "link.badge.plus", tone: .error)
                }.foregroundStyle(.red).disabled(!host.connection.canOperate)
            }
        }
        Section {
            Button(role: .destructive) {
                CompanionUIActions.record(.forgetDesktop, on: .desktopSettings)
                forget()
            } label: {
                CompanionSettingsRowLabel("Forget on this device", symbol: "trash", tone: .error)
            }.accessibilityIdentifier("desktop-connection-forget")
        }
    }
}

struct CompanionBuildInfoSection: View {
    private let version = CompanionBuildInfo.version()
    private let sha = CompanionBuildInfo.buildSHA()

    var body: some View {
        let text = CompanionBuildInfo.settingsVersion(version: version.version, build: version.build, sha: sha)
        Section {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .listRowBackground(Color.clear)
                .textSelection(.enabled)
                .contextMenu {
                    if let sha {
                        Button("Copy build SHA", systemImage: "doc.on.doc") { UIPasteboard.general.string = sha }
                    } else {
                        Button("Copy version", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                    }
                }
                .accessibilityIdentifier("settings-build-version")
                .accessibilityLabel("App \(text)")
                .accessibilityHint(sha == nil ? "Long-press to copy the version." : "Long-press to copy the full build commit.")
        }
    }
}
