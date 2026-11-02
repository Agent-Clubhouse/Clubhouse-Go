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
                                                                                   mcpEnabled: !ProcessInfo.processInfo.arguments.contains("--companion-preview-mcp-off"),
                                                                                   showsHelperIdentity: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-identity"),
                                                                                   showsHelperTree: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-tree")))
    /// Fresh each launch, so pins and idle marks from an earlier run don't change what UI tests see.
    @State private var preferences: CompanionPreferences = {
        let suite = ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-tree") ? "companion-preview-tree" : "companion-preview"
        if !ProcessInfo.processInfo.arguments.contains("--companion-preview-keep-preferences") {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return CompanionPreferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }()
    /// `--companion-preview-feedback`: an enrolled in-memory feedback client, for the Send feedback menu items.
    @State private var feedback: CompanionFeedbackPresenter? = ProcessInfo.processInfo.arguments.contains("--companion-preview-feedback")
        ? CompanionFeedbackPresenter(model: FramebriarShakePreview.fixtureModel(enrolled: true).0) : nil
    var body: some View {
        CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: {}, isPreview: true)
            .companionFeedbackEntryPoints(feedback)
            .shakeToOpenFeedback(model: feedback?.model, enabled: true)
            .task { await feedback?.model?.setActive(true) }
    }
}
#endif
