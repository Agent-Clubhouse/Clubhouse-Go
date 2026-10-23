#if DEBUG
import SwiftUI

struct CompanionPreviewRoot: View {
    @State private var store = CompanionStore(service: CompanionPreviewService())
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        CompanionRootView(store: store, onPair: {}, onSettings: {})
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(dynamicTypeSize.isAccessibilitySize ? "Preview" : "UI PREVIEW · NO DESKTOP CONNECTED")
                    .font(.caption2.weight(.semibold)).tracking(1)
                    .accessibilityLabel("UI preview. No desktop connected.")
                    .frame(maxWidth: .infinity).padding(6)
                    .foregroundStyle(.secondary).background(.bar)
            }
    }
}
#endif
