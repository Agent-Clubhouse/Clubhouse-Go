import Foundation
import Observation

/// Per-device choices that never leave the phone: project order and the last desktop opened.
@MainActor @Observable final class CompanionPreferences {
    private enum Key {
        static let projectSort = "companion.projectSort"
        static let projectOrder = "companion.projectOrder"
        static let lastHost = "companion.lastHostID"
    }
    @ObservationIgnored private let defaults: UserDefaults

    var projectSort: CompanionProjectSort { didSet { defaults.set(projectSort.rawValue, forKey: Key.projectSort) } }
    var projectOrder: [String] { didSet { defaults.set(projectOrder, forKey: Key.projectOrder) } }
    /// The desktop you last opened an agent on. Screens that span desktops take its theme.
    var lastHostID: String? { didSet { defaults.set(lastHostID, forKey: Key.lastHost) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectSort = defaults.string(forKey: Key.projectSort).flatMap(CompanionProjectSort.init(rawValue:)) ?? .recent
        projectOrder = defaults.stringArray(forKey: Key.projectOrder) ?? []
        lastHostID = defaults.string(forKey: Key.lastHost)
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
