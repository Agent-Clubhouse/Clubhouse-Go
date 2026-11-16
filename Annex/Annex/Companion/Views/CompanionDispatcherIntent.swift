import AppIntents
import SwiftUI
import UIKit
#if DEBUG
import Security
import ClubhouseTransport

/// Status-only evidence from this app process. No signing/configuration flag decides capability.
/// The probe uses a unique test-only item, never a pairing or credential service.
nonisolated struct CompanionLaunchKeychainDiagnostic: Codable, Sendable {
    let probeAdd: Int32
    let probeDelete: Int32?
    var restoreKind = "pending"
    var restoreStatus: Int32?

    static func probe() -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.Agent-Clubhouse.Go.tests.dispatcher-launch-capability",
            kSecAttrAccount as String: UUID().uuidString, kSecAttrSynchronizable as String: false]
        let add = SecItemAdd(query.merging([kSecValueData as String: Data([0]),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        // A rejected add created nothing. A successful probe must also prove cleanup succeeded.
        let delete: OSStatus? = add == errSecSuccess ? SecItemDelete(query as CFDictionary) : nil
        return .init(probeAdd: add, probeDelete: delete)
    }
    mutating func restored() { restoreKind = "success"; restoreStatus = nil }
    mutating func failed(_ error: any Error) {
        if let transportError = error as? AnnexTransportError, case .persistenceFailed(let status) = transportError {
            restoreKind = "persistenceFailed"; restoreStatus = status
        } else {
            restoreKind = "otherFailure"; restoreStatus = nil
        }
    }
    var json: String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }
}
#endif

/// SwiftUI retains scene ownership; these delegates only hand off the external action.
@MainActor final class CompanionLaunchAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated deinit {}
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        Self.sceneConfiguration(role: session.role)
    }
    static func sceneConfiguration(role: UISceneSession.Role) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: role)
        if role == .windowApplication { configuration.delegateClass = CompanionLaunchSceneDelegate.self }
        return configuration
    }
}

@MainActor final class CompanionLaunchSceneDelegate: NSObject, UIWindowSceneDelegate {
    nonisolated deinit {}
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        Self.captureColdShortcut(options.shortcutItem)
    }
    static func captureColdShortcut(_ item: UIApplicationShortcutItem?) {
        if let item { CompanionDispatcherLaunchInbox.shared.handleQuickAction(item.type) }
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
