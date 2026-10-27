#if DEBUG
import SwiftUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService(streamsUpdates: ProcessInfo.processInfo.arguments.contains("--companion-preview-stream")))
    /// Fresh each launch, so pins and idle marks from an earlier run don't change what UI tests see.
    @State private var preferences: CompanionPreferences = {
        UserDefaults.standard.removePersistentDomain(forName: "companion-preview")
        return CompanionPreferences(defaults: UserDefaults(suiteName: "companion-preview") ?? .standard)
    }()
    var body: some View {
        CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: {}, isPreview: true)
    }
}
#endif
