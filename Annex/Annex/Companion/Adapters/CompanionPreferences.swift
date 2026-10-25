import Foundation
import Observation

/// Per-device choices that never leave the phone: project order, theme overrides and the last desktop opened.
@MainActor @Observable final class CompanionPreferences {
    private enum Key {
        static let projectSort = "companion.projectSort"
        static let projectOrder = "companion.projectOrder"
        static let themeOverrides = "companion.themeOverrides"
        static let lastHost = "companion.lastHostID"
    }
    @ObservationIgnored private let defaults: UserDefaults

    var projectSort: CompanionProjectSort { didSet { defaults.set(projectSort.rawValue, forKey: Key.projectSort) } }
    var projectOrder: [String] { didSet { defaults.set(projectOrder, forKey: Key.projectOrder) } }
    /// Host id to theme id, for desktops that don't report their theme or when you'd rather pick one.
    var themeOverrides: [String: String] { didSet { defaults.set(themeOverrides, forKey: Key.themeOverrides) } }
    /// The desktop you last opened an agent on. Screens that span desktops take its theme.
    var lastHostID: String? { didSet { defaults.set(lastHostID, forKey: Key.lastHost) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectSort = defaults.string(forKey: Key.projectSort).flatMap(CompanionProjectSort.init(rawValue:)) ?? .recent
        projectOrder = defaults.stringArray(forKey: Key.projectOrder) ?? []
        themeOverrides = defaults.dictionary(forKey: Key.themeOverrides) as? [String: String] ?? [:]
        lastHostID = defaults.string(forKey: Key.lastHost)
    }

    /// Records a new order from a drag, keeping projects that aren't shown right now (offline desktops) in place.
    func setProjectOrder(_ visible: [String]) {
        let hidden = projectOrder.filter { !visible.contains($0) }
        projectOrder = visible + hidden
    }

    func theme(forHost hostID: String?, hosts: [CompanionHost]) -> CompanionDesktopTheme {
        CompanionThemeCatalog.theme(forHost: hostID, hosts: hosts, overrides: themeOverrides)
    }

    /// The theme for screens that cover every desktop.
    func sharedTheme(hosts: [CompanionHost]) -> CompanionDesktopTheme {
        let host = hosts.first { $0.id == lastHostID }?.id ?? hosts.first?.id
        return theme(forHost: host, hosts: hosts)
    }
}
