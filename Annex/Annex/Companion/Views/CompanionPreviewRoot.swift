#if DEBUG
import SwiftUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService())
    var body: some View {
        CompanionRootView(store: store, onPair: {}, onSettings: {})
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("UI PREVIEW · NO DESKTOP CONNECTED")
                    .font(.caption2.weight(.semibold)).tracking(1)
                    .frame(maxWidth: .infinity).padding(6)
                    .foregroundStyle(.secondary).background(.bar)
            }
    }
}
#endif
