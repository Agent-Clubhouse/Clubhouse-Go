import SwiftUI
import ClubhouseTransport

struct CompanionDispatcherComposerFocus: Equatable {
    let id: UUID
    let target: CompanionTarget
}
struct CompanionDispatcherFocusAction {
    var request: CompanionDispatcherComposerFocus?
    var handled: @MainActor (UUID) -> Void = { _ in }
}
extension EnvironmentValues {
    @Entry var companionDispatcherFocus = CompanionDispatcherFocusAction()
    @Entry var companionDispatcherLaunchDiagnostics: String? = nil
}

/// The same chooser serves Home Screen actions and foreground App Intents.
struct CompanionDispatcherLaunchSheet: View {
    let desktops: [CompanionDispatcherDesktop]
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionDispatcherLaunchDiagnostics) private var diagnostics
    var body: some View {
        NavigationStack {
            List { content }
                .navigationTitle("Message Dispatcher")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { cancelButton } }
        }
    }
    @ViewBuilder private var content: some View {
        if desktops.isEmpty {
            ContentUnavailableView("No Dispatcher available", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Pair a desktop and enable its Dispatcher in Clubhouse, then try again."))
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("dispatcher-launch-unavailable")
                .accessibilityValue(diagnostics ?? "")
        } else {
            Section("Choose a Dispatcher") {
                ForEach(desktops) { desktop in choice(desktop) }
            }
        }
    }
    private func choice(_ desktop: CompanionDispatcherDesktop) -> some View {
        Button { choose(desktop.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(desktop.displayName).font(.headline)
                Text(desktop.name).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityLabel(desktop.accessibilityLabel)
        .accessibilityIdentifier("dispatcher-launch-choose-" + desktop.id)
    }
    private var cancelButton: some View {
        Button("Cancel", systemImage: "xmark") {
            CompanionUIActions.record(.cancel, on: .dispatcher)
            dismiss()
        }
    }
}
