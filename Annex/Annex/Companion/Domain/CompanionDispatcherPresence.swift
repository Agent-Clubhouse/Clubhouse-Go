import Foundation

/// Read-only reports about other computers, never a source of pairing or command authority.
struct CompanionDispatcherPresence: Decodable, Equatable, Sendable {
    struct Remote: Decodable, Equatable, Sendable, Identifiable {
        struct Link: Decodable, Equatable, Sendable {
            var state: String
            var reason: String?

            var text: String {
                switch state {
                case "active": "Link active"
                case "paused": "Link paused"
                default: "Link unavailable"
                }
            }
        }

        var machineId: String
        var machineName: String
        var address: String?
        var dispatcherName: String?
        var label: String
        var state: String
        var lastSeen: String?
        var link: Link
        var id: String { machineId }

        func stateText(now: Date = Date()) -> String {
            switch state {
            case "online": return "Online"
            case "working": return "Working"
            case "asleep": return "Asleep"
            case "off": return "Off"
            case "offline":
                guard let lastSeen,
                      let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(lastSeen))
                        ?? (try? Date.ISO8601FormatStyle().parse(lastSeen)) else { return "Offline" }
                let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
                return "Offline, last seen \(relative)"
            default: return "Unknown"
            }
        }

        var symbol: String {
            switch state {
            case "online": "circle"
            case "working": "gearshape.2"
            case "asleep": "moon"
            case "offline": "wifi.slash"
            case "off": "power"
            default: "questionmark.circle"
            }
        }
    }

    var remotes: [Remote]
}

struct CompanionDispatcherSwitcherRow: Identifiable {
    var id: String
    var desktop: CompanionDispatcherDesktop?
    var presence: CompanionDispatcherPresence.Remote?
    var label: String { presence?.label ?? desktop?.accessibilityLabel ?? CompanionDispatcher.name }
    var detail: String? { presence.map { "\($0.stateText()) · \($0.link.text)" } }
    var accessibilityLabel: String { [label, detail].compactMap { $0 }.joined(separator: ", ") }

    static func rows(desktops: [CompanionDispatcherDesktop], hosts: [CompanionHost]) -> [Self] {
        var reports: [String: (remote: CompanionDispatcherPresence.Remote, received: Date, source: String)] = [:]
        for host in hosts {
            guard let received = host.dispatcherPresenceReceivedAt else { continue }
            for remote in host.dispatcherPresence?.remotes ?? [] {
                if let previous = reports[remote.id],
                   previous.received > received || (previous.received == received && previous.source < host.id) { continue }
                reports[remote.id] = (remote, received, host.id)
            }
        }
        var rows = desktops.map { Self(id: $0.id, desktop: $0, presence: reports.removeValue(forKey: $0.id)?.remote) }
        rows += reports.values.map { Self(id: $0.remote.id, presence: $0.remote) }
        return rows.sorted {
            let name = ($0.presence?.dispatcherName ?? $0.desktop?.displayName ?? CompanionDispatcher.name)
                .localizedStandardCompare($1.presence?.dispatcherName ?? $1.desktop?.displayName ?? CompanionDispatcher.name)
            if name != .orderedSame { return name == .orderedAscending }
            let machine = ($0.presence?.machineName ?? $0.desktop?.name ?? "")
                .localizedStandardCompare($1.presence?.machineName ?? $1.desktop?.name ?? "")
            return machine == .orderedSame ? $0.id < $1.id : machine == .orderedAscending
        }
    }
}
