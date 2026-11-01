#if DEBUG
import SwiftUI
import FramebriarUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService(streamsUpdates: ProcessInfo.processInfo.arguments.contains("--companion-preview-stream"),
                                                                                   showsHelperRequests: ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-requests"),
                                                                                   showsTerminalAgent: ProcessInfo.processInfo.arguments.contains("--companion-preview-terminal-agent"),
                                                                                   showsLongBlocks: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-blocks"),
                                                                                   showsLongReply: ProcessInfo.processInfo.arguments.contains("--companion-preview-long-reply"),
                                                                                   showsDispatcher: ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher")))
    /// Fresh each launch, so pins and idle marks from an earlier run don't change what UI tests see.
    @State private var preferences: CompanionPreferences = {
        UserDefaults.standard.removePersistentDomain(forName: "companion-preview")
        return CompanionPreferences(defaults: UserDefaults(suiteName: "companion-preview") ?? .standard)
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
