import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Per-device choices: project order, the last desktop opened, and this phone's name.
/// Only the name leaves the phone, as the alias a desktop shows for it.
@MainActor @Observable final class CompanionPreferences {
    private enum Key {
        static let projectSort = "companion.projectSort"
        static let projectOrder = "companion.projectOrder"
        static let lastHost = "companion.lastHostID"
        static let deviceName = "companion.deviceName"
    }
    @ObservationIgnored private let defaults: UserDefaults
    /// The system's name for this phone. Without the user-assigned-device-name entitlement iOS reports only "iPhone".
    let systemDeviceName: String

    var projectSort: CompanionProjectSort { didSet { defaults.set(projectSort.rawValue, forKey: Key.projectSort) } }
    var projectOrder: [String] { didSet { defaults.set(projectOrder, forKey: Key.projectOrder) } }
    /// The desktop you last opened an agent on. Screens that span desktops take its theme.
    var lastHostID: String? { didSet { defaults.set(lastHostID, forKey: Key.lastHost) } }
    /// What desktops call this phone, as typed. Starts as the system name and is saved once edited.
    var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.deviceName) } }

    init(defaults: UserDefaults = .standard, systemDeviceName: String = CompanionPreferences.currentDeviceName()) {
        self.defaults = defaults
        self.systemDeviceName = systemDeviceName
        deviceName = defaults.string(forKey: Key.deviceName) ?? systemDeviceName
        projectSort = defaults.string(forKey: Key.projectSort).flatMap(CompanionProjectSort.init(rawValue:)) ?? .recent
        projectOrder = defaults.stringArray(forKey: Key.projectOrder) ?? []
        lastHostID = defaults.string(forKey: Key.lastHost)
    }

    /// The name sent as `alias` when pairing: trimmed, never empty, and within the desktop's 128-character limit.
    var pairingAlias: String {
        let typed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = systemDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((typed.isEmpty ? (fallback.isEmpty ? "iPhone" : fallback) : typed).prefix(128))
    }

    /// Keeps the name that was used to pair, so a desktop and this phone agree on it.
    func saveDeviceName() { deviceName = pairingAlias }

    static func currentDeviceName() -> String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// Records a new order from a drag, keeping projects that aren't shown right now (offline desktops) in place.
    func setProjectOrder(_ visible: [String]) {
        let hidden = projectOrder.filter { !visible.contains($0) }
        projectOrder = visible + hidden
    }

    /// The colors a desktop sent, or the Clubhouse default until it has.
    func theme(forHost hostID: String?, hosts: [CompanionHost]) -> CompanionDesktopTheme {
        hosts.first { $0.id == hostID }?.theme ?? .clubhouse
    }

    /// The theme for screens that cover every desktop.
    func sharedTheme(hosts: [CompanionHost]) -> CompanionDesktopTheme {
        let host = hosts.first { $0.id == lastHostID }?.id ?? hosts.first?.id
        return theme(forHost: host, hosts: hosts)
    }
}
