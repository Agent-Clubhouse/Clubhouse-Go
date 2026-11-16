#if DEBUG
import SwiftUI
import FramebriarUI
import ClubhouseTransport

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService(streamsUpdates: ProcessInfo.processInfo.arguments.contains("--companion-preview-stream"),
                                                                                   showsHelperRequests: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-requests"),
                                                                                   showsTerminalAgent: ProcessInfo.processInfo.arguments.contains("--companion-preview-terminal-agent"),
                                                                                   showsLongBlocks: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-blocks"),
                                                                                   showsLongReply: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-reply"),
                                                                                   showsDispatcher: ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher"),
                                                                                   showsMultipleDispatchers: ProcessInfo.processInfo.arguments.contains("--companion-preview-multiple-dispatchers"),
                                                                                   showsHelperIdentity: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-identity"),
                                                                                   showsHelperTree: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-tree"),
                                                                                   showsQuestions: ProcessInfo.processInfo.arguments.contains("--companion-preview-questions"),
                                                                                   showsContextWindow: ProcessInfo.processInfo.arguments.contains("--companion-preview-context-window"),
                                                                                   showsReadingScenario: ProcessInfo.processInfo.arguments.contains("--companion-preview-reading"),
                                                                                   showsEmptyConversation: ProcessInfo.processInfo.arguments.contains("--companion-preview-empty-chat"),
                                                                                   showsKeyboardInteractions: ProcessInfo.processInfo.arguments.contains("--companion-preview-keyboard-interactions"),
                                                                                   showsHelperPresets: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-presets"),
                                                                                   showsAutoQuota: ProcessInfo.processInfo.arguments.contains("--companion-preview-auto-quota")))
    /// Fresh each launch, so pins and idle marks from an earlier run don't change what UI tests see.
    @State private var preferences: CompanionPreferences = {
        let suite = ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-tree") ? "companion-preview-tree" : "companion-preview"
        if !ProcessInfo.processInfo.arguments.contains("--companion-preview-keep-preferences") {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-start-agents") {
            defaults.set("agents", forKey: "companion.lastTab")
        }
        let preferences = CompanionPreferences(defaults: defaults)
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-search-recents") {
            for (project, agent) in [("clubhouse", "juniper"), ("website", "maple"), ("clubhouse", "cedar")] {
                preferences.recordOpenedAgent(.init(hostID: "preview-studio", projectID: project, agentID: agent))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-start-dispatch") { preferences.lastTab = .dispatcher }
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-start-home") { preferences.lastTab = .home }
        return preferences
    }()
    /// `--companion-preview-feedback`: an enrolled in-memory feedback client, for the Send feedback menu items.
    @State private var feedback: CompanionFeedbackPresenter? = ProcessInfo.processInfo.arguments.contains("--companion-preview-feedback")
        ? CompanionFeedbackPresenter(model: FramebriarShakePreview.fixtureModel(enrolled: true).0) : nil
    @State private var settingsCapture: CompanionFeedbackSettingsCapture?
    @State private var desktopToForget: CompanionHost?
    var body: some View {
        if CompanionConversationHeaderFixture.isEnabled {
            CompanionConversationHeaderFixture()
        } else if CompanionRecoveryFixture.isEnabled {
            CompanionRecoveryFixture().preferredColorScheme(Self.forcedColorScheme)
        } else {
            // `--companion-preview-dark` / `-light`: that appearance for this launch only. Changing the simulator's
            // appearance from a UI test doesn't reliably reach the app on every runtime.
            normalPreview.preferredColorScheme(Self.forcedColorScheme)
        }
    }

    private static var forcedColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--companion-preview-dark") { return .dark }
        if arguments.contains("--companion-preview-light") { return .light }
        return nil
    }

    private var normalPreview: some View {
        CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: {
            $settingsCapture.releasingFeedbackScreenshot.wrappedValue = CompanionFeedbackSettingsCapture(window: CompanionFeedbackPresenter.keyWindow())
        },
                          isPreview: !ProcessInfo.processInfo.arguments.contains("--companion-preview-hide-banner"))
            .task {
                await CompanionWakeFocusDiagnostics.prepare()
                CompanionUnicodeFocusFixture.seed(store)
            }
            .sheet(item: $settingsCapture.releasingFeedbackScreenshot) { capture in
                NavigationStack {
                    Form {
                        if store.hosts.contains(where: \.canUpdateApp) {
                            Section("Your desktops") {
                                ForEach(store.hosts.filter(\.canUpdateApp)) { host in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label(host.name, systemImage: "desktopcomputer").font(.headline)
                                        CompanionAppUpdateLink(store: store, host: host)
                                        DisclosureGroup("Connection details") {
                                            CompanionDesktopConnectionActions(host: host,
                                                retry: { Task { await store.reconnect(hostID: host.id) } },
                                                forget: { desktopToForget = host })
                                        }
                                    }
                                }
                            }
                        }
                        CompanionPlanLimitsLink(store: store)
                        CompanionHelperPresetLinks(store: store)
                        if let feedback { CompanionFeedbackSettings(model: feedback.model, initialCapture: capture) }
                        if ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher-controls") {
                            Section("Preview desktop reports") {
                                Button("Report Dispatcher off") { report(enabled: false) }
                                Button("Report Dispatcher on") { report(enabled: true) }
                                Button("Disconnect desktop") { report(connection: .offline) }
                                Button("Reconnect desktop") { report(connection: .connected) }
                            }
                        }
                        if ProcessInfo.processInfo.arguments.contains("--companion-preview-linked-projects") {
                            Section("Preview desktop reports") {
                                Button("Report projects unlinked") { reportProjectLinks(linked: false) }
                                Button("Report projects linked") { reportProjectLinks(linked: true) }
                            }
                        }
                        if ProcessInfo.processInfo.arguments.contains("--companion-preview-home-summary-controls") {
                            Section("Preview Home counts") {
                                Button("Report two requests and no working agents") { reportHomeCounts() }
                                Button("Report Studio offline") { report(connection: .offline) }
                            }
                        }
                        CompanionBuildInfoSection()
                    }
                    .navigationTitle("Settings")
                    .confirmationDialog("Forget \(desktopToForget?.name ?? "desktop")?",
                        isPresented: Binding(get: { desktopToForget != nil }, set: { if !$0 { desktopToForget = nil } }),
                        titleVisibility: .visible) {
                        Button("Forget desktop", role: .destructive) {
                            store.apply(.hosts(store.hosts.filter { $0.id != desktopToForget?.id }))
                            desktopToForget = nil
                        }
                    } message: { Text("This removes access from this device. Running agents are unaffected.") }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { $settingsCapture.releasingFeedbackScreenshot.wrappedValue = nil } } }
                }
            }
            .companionFeedbackEntryPoints(feedback)
            .companionFeedbackShake(feedback, enabled: true)
            .task { await feedback?.model?.setActive(true) }
    }
    private func report(enabled: Bool? = nil, connection: CompanionConnection? = nil) {
        var hosts = store.hosts
        guard let index = hosts.firstIndex(where: { $0.id == CompanionPreviewService.dispatcherTarget.hostID }) else { return }
        if let enabled { hosts[index].dispatcher?.enabled = enabled }
        if let connection { hosts[index].connection = connection }
        store.apply(.hosts(hosts))
    }
    private func reportProjectLinks(linked: Bool) {
        var hosts = store.hosts
        for index in hosts.indices {
            hosts[index].projectLinks = linked ? CompanionPreviewService.previewProjectLinks : .init(projectLinks: [])
        }
        store.apply(.hosts(hosts))
    }

    private func reportHomeCounts() {
        var hosts = store.hosts
        for host in hosts.indices {
            for project in hosts[host].projects.indices {
                for agent in hosts[host].projects[project].agents.indices {
                    if hosts[host].projects[project].agents[agent].status == .working {
                        hosts[host].projects[project].agents[agent].status = .approval
                    }
                }
            }
        }
        store.apply(.hosts(hosts))
    }
}
#endif
