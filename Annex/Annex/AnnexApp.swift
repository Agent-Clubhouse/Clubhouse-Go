import SwiftUI

@main
struct ClubhouseGoApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            if !store.hasCompletedOnboarding {
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        store.completeOnboarding()
                    }
                }
                .environment(store)
                .tint(store.theme.accentColor)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
            } else if store.hasConnectedInstance {
                RootNavigationView()
                    .environment(store)
                    .tint(store.theme.accentColor)
                    .preferredColorScheme(store.theme.isDark ? .dark : .light)
            } else {
                PairingPlaceholderView()
                    .environment(store)
                    .tint(store.theme.accentColor)
                    .preferredColorScheme(store.theme.isDark ? .dark : .light)
            }
        }
    }

    init() {
        let store = _store
        Task {
            await store.wrappedValue.restoreAllSessions()
        }
    }
}
