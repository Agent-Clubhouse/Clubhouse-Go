#if DEBUG
import SwiftUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService())
    var body: some View {
        CompanionRootView(store: store, onPair: {}, onSettings: {}, isPreview: true)
    }
}
#endif
