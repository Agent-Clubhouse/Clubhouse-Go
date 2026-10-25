#if DEBUG
import SwiftUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService())
    var body: some View {
        CompanionRootView(store: store, preferences: CompanionPreferences(defaults: UserDefaults(suiteName: "companion-preview") ?? .standard),
                          onPair: {}, onSettings: {}, isPreview: true)
    }
}
#endif
