import Foundation
import Security

/// iOS keeps an app's Keychain items after the app is deleted, so a reinstall would quietly restore old
/// desktop pairings and feedback enrollment. Deleting the app does clear its UserDefaults, so empty
/// defaults with no install marker mean a fresh install, and the leftovers are cleared before anything
/// reads them. An upgrade already has defaults, so it only gets the marker and keeps its pairings.
enum CompanionInstallReset {
    static let markerKey = "companion.installMarker.v1"
    /// Desktop pairings, Framebriar enrollment, and the legacy UI's credentials.
    static let keychainServices = ["com.agentclubhouse.go.pairings.v1", "ClubhouseGo.Framebriar",
                                   "com.Agent-Clubhouse.Go", "com.Agent-Clubhouse.Annex"]

    /// Returns true when this launch was a fresh install and leftovers were cleared.
    @discardableResult
    static func clearLeftoversIfFreshInstall(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier,
                                             delete: (String) -> Void = deleteGenericPasswords) -> Bool {
        guard !defaults.bool(forKey: markerKey) else { return false }
        let fresh = domain.map { defaults.persistentDomain(forName: $0)?.isEmpty ?? true } ?? true
        if fresh { keychainServices.forEach(delete) }
        defaults.set(true, forKey: markerKey)
        return fresh
    }

    static func deleteGenericPasswords(service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
