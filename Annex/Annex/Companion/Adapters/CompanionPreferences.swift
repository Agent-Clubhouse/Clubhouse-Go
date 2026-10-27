import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Per-device choices: project order, pins and idle projects, the last desktop opened, and this phone's name.
/// Only the name leaves the phone, as the alias a desktop shows for it.
@MainActor @Observable final class CompanionPreferences {
    private enum Key {
        static let projectSort = "companion.projectSort"
        static let projectOrder = "companion.projectOrder"
        static let lastHost = "companion.lastHostID"
        static let deviceName = "companion.deviceName"
        static let pinnedProjects = "companion.pinnedProjects"
        static let inactiveProjects = "companion.inactiveProjects"
        static let projectActivity = "companion.projectActivity"
        static let idleDays = "companion.idleDays"
        static let idleExpanded = "companion.idleExpanded"
    }
    @ObservationIgnored private let defaults: UserDefaults
    /// The system's name for this phone (overridable in tests). Without the user-assigned-device-name entitlement iOS reports only "iPhone".
    let systemDeviceName: String

    var projectSort: CompanionProjectSort { didSet { defaults.set(projectSort.rawValue, forKey: Key.projectSort) } }
    var projectOrder: [String] { didSet { defaults.set(projectOrder, forKey: Key.projectOrder) } }
    /// The desktop you last opened an agent on. Screens that span desktops take its theme.
    var lastHostID: String? { didSet { defaults.set(lastHostID, forKey: Key.lastHost) } }
    /// What desktops call this phone, as typed. Starts as the system name and is saved once edited.
    var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.deviceName) } }
    /// Projects pinned to the top of Home, by `CompanionProjectEntry.orderKey`.
    var pinnedProjects: [String] { didSet { defaults.set(pinnedProjects, forKey: Key.pinnedProjects) } }
    /// Projects marked inactive here. They stay in the idle section until marked active.
    var inactiveProjects: [String] { didSet { defaults.set(inactiveProjects, forKey: Key.inactiveProjects) } }
    /// When a project was last marked active here, which counts as activity for the idle rule.
    var projectActivity: [String: Date] {
        didSet { defaults.set(projectActivity.mapValues(\.timeIntervalSince1970), forKey: Key.projectActivity) }
    }
    /// Days without activity before an unpinned project folds into "N idle projects"; 0 is never.
    var idleDays: Int { didSet { defaults.set(idleDays, forKey: Key.idleDays) } }
    /// Whether the "N idle projects" section is open.
    var idleExpanded: Bool { didSet { defaults.set(idleExpanded, forKey: Key.idleExpanded) } }

    init(defaults: UserDefaults = .standard, systemDeviceName: String? = nil) {
        self.defaults = defaults
        self.systemDeviceName = systemDeviceName ?? Self.currentDeviceName()
        deviceName = defaults.string(forKey: Key.deviceName) ?? self.systemDeviceName
        projectSort = defaults.string(forKey: Key.projectSort).flatMap(CompanionProjectSort.init(rawValue:)) ?? .recent
        projectOrder = defaults.stringArray(forKey: Key.projectOrder) ?? []
        lastHostID = defaults.string(forKey: Key.lastHost)
        pinnedProjects = defaults.stringArray(forKey: Key.pinnedProjects) ?? []
        inactiveProjects = defaults.stringArray(forKey: Key.inactiveProjects) ?? []
        projectActivity = ((defaults.dictionary(forKey: Key.projectActivity) as? [String: Double]) ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
        idleDays = (defaults.object(forKey: Key.idleDays) as? Int) ?? CompanionIdleRule.defaultDays
        idleExpanded = defaults.bool(forKey: Key.idleExpanded)
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

    var idleRule: CompanionIdleRule { .init(days: idleDays, pinned: Set(pinnedProjects), inactive: Set(inactiveProjects)) }

    func isPinned(_ key: String) -> Bool { pinnedProjects.contains(key) }

    func togglePinned(_ key: String) {
        if isPinned(key) { pinnedProjects.removeAll { $0 == key } } else { pinnedProjects.append(key) }
    }

    /// Folds a project into the idle section now, until it is marked active. Pinned projects can't be (unpin first).
    func markInactive(_ key: String) {
        guard !isPinned(key), !inactiveProjects.contains(key) else { return }
        inactiveProjects.append(key)
    }

    /// Brings a project out of the idle section: clears a mark, and counts as activity now.
    func markActive(_ key: String, at date: Date = Date()) {
        inactiveProjects.removeAll { $0 == key }
        projectActivity[key] = date
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
