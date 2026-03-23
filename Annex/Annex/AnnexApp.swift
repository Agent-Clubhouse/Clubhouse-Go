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
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--reset-onboarding") {
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            store.wrappedValue = AppStore()
        } else if args.contains("--ui-testing") {
            store.wrappedValue.loadMockData()
            store.wrappedValue.completeOnboarding()
        } else if let serverArg = Self.extractArg("--test-server", from: args) {
            let pin = Self.extractArg("--test-pin", from: args)
            let mockSnapshot = args.contains("--test-snapshot")
            store.wrappedValue.completeOnboarding()
            if mockSnapshot {
                // Load mock data synchronously for reliable UI testing.
                // HTTP pairing still runs in background to validate networking.
                store.wrappedValue.loadMockData()
            }
            Task {
                await store.wrappedValue.connectToTestServer(serverArg, pin: pin)
            }
        } else {
            Task {
                await store.wrappedValue.restoreAllSessions()
            }
        }
    }

    private static func extractArg(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
