#if DEBUG
import SwiftUI

/// Isolated experiment. No product control adopts this style until its runtime/AX result is reviewed.
private struct CompanionNativeActionSpikeStyle: PrimitiveButtonStyle {
    let onAction: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            onAction()
            configuration.trigger()
        } label: { configuration.label }
        .buttonStyle(.automatic)
    }
}

/// Compare untouched native controls with a public action hook; no gestures, UIKit introspection or telemetry data.
struct CompanionNativeActionSpike: View {
    @State private var menuOpens = 0
    @State private var linkOpens = 0
    @State private var items = 0
    var body: some View {
        NavigationStack {
            List {
                Section("Native baseline") {
                    menu(id: "native-menu")
                    link(id: "native-link")
                }
                Section("Instrumented candidate") {
                    menu(id: "candidate-menu")
                        .buttonStyle(CompanionNativeActionSpikeStyle { menuOpens += 1 })
                    link(id: "candidate-link")
                        .buttonStyle(CompanionNativeActionSpikeStyle { linkOpens += 1 })
                    Button("Disabled") { items += 100 }
                        .buttonStyle(CompanionNativeActionSpikeStyle { linkOpens += 100 })
                        .disabled(true).accessibilityIdentifier("candidate-disabled")
                }
                Section("Observed callbacks") {
                    Text("Menu: \(menuOpens) · Link: \(linkOpens) · Item: \(items)")
                        .accessibilityIdentifier("native-hook-counts")
                }
            }
            .navigationTitle("Native hook spike")
        }
    }
    private func menu(id: String) -> some View {
        Menu {
            Button("Choose item") { items += 1 }
        } label: { Label("More", systemImage: "ellipsis") }
        .accessibilityIdentifier(id)
    }
    private func link(id: String) -> some View {
        NavigationLink {
            Text("Destination").navigationTitle("Details")
        } label: { Label("Details", systemImage: "info.circle") }
        .accessibilityIdentifier(id)
    }
}
#endif
