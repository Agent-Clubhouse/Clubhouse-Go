import AppIntents
import SwiftUI
import UIKit

/// SwiftUI retains scene ownership; these delegates only hand off the external action.
@MainActor final class CompanionLaunchAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = CompanionLaunchSceneDelegate.self }
        return configuration
    }
}

@MainActor final class CompanionLaunchSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { CompanionDispatcherLaunchInbox.shared.handleQuickAction(item.type) }
    }
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        CompanionDispatcherLaunchInbox.shared.handleQuickAction(shortcutItem.type)
    }
}

struct MessageDispatcherIntent: AppIntent {
    static var title: LocalizedStringResource = "Message Dispatcher"
    static var description = IntentDescription("Open your Dispatcher and focus its message composer. Choose a Dispatcher in the app when several are paired.")
    static var supportedModes: IntentModes { .foreground }
    @MainActor func perform() async throws -> some IntentResult {
        CompanionDispatcherLaunchInbox.shared.submit(.appIntent)
        return .result()
    }
}

struct CompanionDispatcherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MessageDispatcherIntent(),
                    phrases: ["Message Dispatcher in \(.applicationName)", "Open Dispatcher in \(.applicationName)"],
                    shortTitle: "Message Dispatcher", systemImageName: "bubble.left.and.text.bubble.right")
    }
}
