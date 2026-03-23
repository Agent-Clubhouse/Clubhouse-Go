import SwiftUI

@main
struct ClubhouseGoApp: App {
    @State private var store = AppStore()

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

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
            } else if !store.instances.isEmpty {
                // Show main app if we have instances (even if some are disconnected)
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
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--reset-onboarding") {
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            store.wrappedValue = AppStore()
        } else if args.contains("--ui-testing") {
            store.wrappedValue.loadMockData()
            store.wrappedValue.completeOnboarding()
        } else {
            Task {
                await store.wrappedValue.restoreAllSessions()
            }
        }
    }
}
