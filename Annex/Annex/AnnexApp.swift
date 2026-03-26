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
        } else if let serverArg = Self.parseTestServer(args) {
            // Connect directly to a test server (bypasses Bonjour + pairing)
            store.wrappedValue.completeOnboarding()
            Task {
                await store.wrappedValue.connectToTestServer(
                    host: serverArg.host,
                    mainPort: serverArg.mainPort,
                    pairingPort: serverArg.pairingPort,
                    pin: serverArg.pin
                )
            }
        } else {
            Task {
                await store.wrappedValue.restoreAllSessions()
            }
        }
    }

    /// Parse --test-server host:mainPort:pairingPort and optional --test-pin PIN
    private static func parseTestServer(_ args: [String]) -> (host: String, mainPort: UInt16, pairingPort: UInt16, pin: String)? {
        guard let idx = args.firstIndex(of: "--test-server"), idx + 1 < args.count else { return nil }
        let parts = args[idx + 1].split(separator: ":")
        guard parts.count >= 3,
              let mainPort = UInt16(parts[1]),
              let pairingPort = UInt16(parts[2]) else { return nil }
        let host = String(parts[0])
        let pin = args.firstIndex(of: "--test-pin").flatMap { i in
            i + 1 < args.count ? args[i + 1] : nil
        } ?? "000000"
        return (host: host, mainPort: mainPort, pairingPort: pairingPort, pin: pin)
    }
}
