import Foundation

enum CompanionTab: Hashable { case dispatcher, home, needsYou, agents, search }

enum CompanionStartScreen: String, CaseIterable, Sendable {
    case dispatcher, home
    var label: String { self == .dispatcher ? "Dispatcher" : "Home" }
}

/// Only desktop-reported on state is cached. No transcript or command permissions live in preferences.
struct CompanionDispatcherDesktop: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var target: CompanionTarget?

    init?(host: CompanionHost) {
        guard let dispatcher = host.dispatcher, dispatcher.enabled, dispatcher.flagOn else { return nil }
        id = host.id
        name = host.name
        target = dispatcher.liveAgent?.id
    }
}

/// Navigation belongs to the session. The preference is consumed at initialization, never on foregrounding.
/// An unknown first launch can resolve once on its first desktop report, until any user interaction.
struct CompanionNavigation {
    private(set) var tab: CompanionTab = .home
    var paths: [CompanionTab: [CompanionRoute]] = [:]
    private(set) var dispatcherDesktops: [CompanionDispatcherDesktop]
    private(set) var dispatcherHostID: String?
    private let startScreen: CompanionStartScreen
    private var awaitingFirstReport: Bool
    private var observedHostIDs: Set<String> = []
    private var pendingDispatcherLink: CompanionTarget?

    init(startScreen: CompanionStartScreen, cached: [CompanionDispatcherDesktop]? = nil, lastHostID: String? = nil) {
        self.startScreen = startScreen
        dispatcherDesktops = cached ?? []
        dispatcherHostID = cached?.first { $0.id == lastHostID }?.id ?? cached?.first?.id ?? lastHostID
        awaitingFirstReport = cached == nil
        if startScreen == .dispatcher, !dispatcherDesktops.isEmpty { tab = .dispatcher }
    }

    var tabs: [CompanionTab] { (dispatcherDesktops.isEmpty ? [] : [.dispatcher]) + [.home, .needsYou, .agents, .search] }
    var dispatcherTarget: CompanionTarget? { dispatcherDesktops.first { $0.id == dispatcherHostID }?.target }
    var visibleAgent: CompanionTarget? { paths[tab]?.last?.agent ?? (tab == .dispatcher && (paths[tab] ?? []).isEmpty ? dispatcherTarget : nil) }
    mutating func interact() { awaitingFirstReport = false }

    mutating func select(_ tab: CompanionTab) {
        interact()
        pendingDispatcherLink = nil
        self.tab = tabs.contains(tab) ? tab : .home
    }

    mutating func chooseDispatcher(hostID: String) {
        guard dispatcherDesktops.contains(where: { $0.id == hostID }) else { return }
        interact()
        dispatcherHostID = hostID
        paths[.dispatcher] = []
    }

    mutating func update(hosts: [CompanionHost]) {
        let previousDispatcherHostID = dispatcherHostID
        let ids = Set(hosts.map(\.id))
        let removed = observedHostIDs.subtracting(ids)
        dispatcherDesktops.removeAll { removed.contains($0.id) }
        observedHostIDs = ids
        for host in hosts {
            // A host with no capabilities yet is unknown, not off. Reconnects keep its last report.
            guard host.dispatcher != nil || host.connection.canOperate else { continue }
            let previous = dispatcherDesktops.first { $0.id == host.id }
            dispatcherDesktops.removeAll { $0.id == host.id }
            if var desktop = CompanionDispatcherDesktop(host: host) {
                // During a reconnect the flags can arrive before the agent catalog.
                if desktop.target == nil { desktop.target = previous?.target }
                dispatcherDesktops.append(desktop)
            }
        }
        dispatcherDesktops.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !dispatcherDesktops.contains(where: { $0.id == dispatcherHostID }) { dispatcherHostID = dispatcherDesktops.first?.id }
        if awaitingFirstReport, hosts.contains(where: { $0.dispatcher != nil || $0.connection.canOperate }) {
            awaitingFirstReport = false
            if startScreen == .dispatcher, !dispatcherDesktops.isEmpty { tab = .dispatcher }
        }
        // Selection changes in the same value update as visibility, before SwiftUI removes the Tab.
        if tab == .dispatcher, previousDispatcherHostID != nil, !dispatcherDesktops.contains(where: { $0.id == previousDispatcherHostID }) { tab = .home }
        if let target = pendingDispatcherLink, hosts.contains(where: { $0.id == target.hostID && $0.dispatcher != nil }) {
            pendingDispatcherLink = nil
            // A notification arriving before the catalog is an explicit navigation request, not a start preference.
            if dispatcherDesktops.contains(where: { $0.id == target.hostID }) { open(target, hosts: hosts) }
        }
        for key in paths.keys {
            paths[key] = paths[key]?.filter { route in
                !removed.contains(route.hostID) && !dispatcherDesktops.contains(where: { $0.target == route.agent })
            }
        }
    }

    mutating func open(_ target: CompanionTarget, hosts: [CompanionHost]) {
        interact()
        pendingDispatcherLink = nil
        if isDispatcher(target, hosts: hosts), dispatcherDesktops.contains(where: { $0.id == target.hostID }) {
            for key in paths.keys { paths[key] = paths[key]?.filter { !isDispatcher($0.agent, hosts: hosts) } }
            dispatcherHostID = target.hostID
            paths[.dispatcher] = []
            tab = .dispatcher
        } else {
            paths[tab] = [.agent(target)]
            if isDispatcher(target, hosts: hosts), !hosts.contains(where: { $0.id == target.hostID && $0.dispatcher != nil }) {
                pendingDispatcherLink = target
            }
        }
    }

    mutating func setPath(_ path: [CompanionRoute], for which: CompanionTab, hosts: [CompanionHost]) {
        interact()
        paths[which] = path
        if let target = path.last?.agent, isDispatcher(target, hosts: hosts),
           dispatcherDesktops.contains(where: { $0.id == target.hostID }) { open(target, hosts: hosts) }
    }

    private func isDispatcher(_ target: CompanionTarget?, hosts: [CompanionHost]) -> Bool {
        guard let target else { return false }
        return target.projectID == CompanionDispatcher.defaultProjectID || hosts.contains { $0.isDispatcher(target) } || dispatcherDesktops.contains { $0.target == target }
    }
}

/// What a tab's stack holds: agents' chats, and project pages.
enum CompanionRoute: Hashable {
    case agent(CompanionTarget)
    case project(CompanionProjectTarget)
    var agent: CompanionTarget? { if case .agent(let target) = self { target } else { nil } }
    var hostID: String {
        switch self { case .agent(let target): target.hostID; case .project(let project): project.hostID }
    }
}

extension CompanionStore {
    /// The same connected-agent and helper-request rule as Needs you, restricted to Dispatchers.
    var dispatcherNeedsYouCount: Int {
        hosts.filter(\.connection.canOperate).reduce(0) { count, host in
            let target = host.dispatcher?.liveAgent?.id
            return count + (host.dispatcher?.liveAgent?.status.needsYou == true ? 1 : 0)
                + helperRequests(on: host).filter { $0.agentTarget == target }.count
        }
    }
}
