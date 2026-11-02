#if DEBUG
import SwiftUI
import FramebriarUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService(streamsUpdates: ProcessInfo.processInfo.arguments.contains("--companion-preview-stream"),
                                                                                   showsHelperRequests: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-requests"),
                                                                                   showsTerminalAgent: ProcessInfo.processInfo.arguments.contains("--companion-preview-terminal-agent"),
                                                                                   showsLongBlocks: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-blocks"),
                                                                                   showsLongReply: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-reply"),
                                                                                   showsDispatcher: ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher"),
                                                                                   showsMultipleDispatchers: ProcessInfo.processInfo.arguments.contains("--companion-preview-multiple-dispatchers"),
                                                                                   mcpEnabled: !ProcessInfo.processInfo.arguments.contains("--companion-preview-mcp-off"),
                                                                                   showsHelperIdentity: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-identity")))
    /// Fresh each launch, so pins and idle marks from an earlier run don't change what UI tests see.
    @State private var preferences: CompanionPreferences = {
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains("--companion-preview-keep-preferences") {
            UserDefaults.standard.removePersistentDomain(forName: "companion-preview")
        }
        let preferences = CompanionPreferences(defaults: UserDefaults(suiteName: "companion-preview") ?? .standard)
        if arguments.contains("--companion-preview-start-home") { preferences.startScreen = .home }
        return preferences
    }()
    /// `--companion-preview-feedback`: an enrolled in-memory feedback client, for the Send feedback menu items.
    @State private var feedback: CompanionFeedbackPresenter? = ProcessInfo.processInfo.arguments.contains("--companion-preview-feedback")
        ? CompanionFeedbackPresenter(model: FramebriarShakePreview.fixtureModel(enrolled: true).0) : nil
    @State private var showSettings = false
    var body: some View {
        CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: { showSettings = true }, isPreview: true)
            .companionFeedbackEntryPoints(feedback)
            .shakeToOpenFeedback(model: feedback?.model, enabled: true)
            .task { await feedback?.model?.setActive(true) }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        CompanionStartScreenPicker(preferences: preferences)
                        if ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher-controls") {
                            Section("Preview desktop reports") {
                                Button("Report Dispatcher off") { report(enabled: false) }
                                Button("Report Dispatcher on") { report(enabled: true) }
                                Button("Report flag off") { report(enabled: true, flagOn: false) }
                                Button("Disconnect desktop") { report(connection: .offline) }
                                Button("Reconnect desktop") { report(connection: .connected) }
                            }
                        }
                    }
                    .navigationTitle("Settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
            }
    }
    private func report(enabled: Bool? = nil, flagOn: Bool? = nil, connection: CompanionConnection? = nil) {
        var hosts = store.hosts
        guard let index = hosts.firstIndex(where: { $0.id == CompanionPreviewService.dispatcherTarget.hostID }) else { return }
        if let enabled { hosts[index].dispatcher?.enabled = enabled }
        if let flagOn { hosts[index].dispatcher?.flagOn = flagOn }
        if let connection { hosts[index].connection = connection }
        store.apply(.hosts(hosts))
    }
}
#endif
