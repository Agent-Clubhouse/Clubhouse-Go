import Foundation

/// Read-only reports about other computers, never a source of pairing or command authority.
struct CompanionDispatcherPresence: Decodable, Equatable, Sendable {
    struct Remote: Decodable, Equatable, Sendable, Identifiable {
        struct Link: Decodable, Equatable, Sendable {
            var state: String
            var reason: String?

            /// An active link needs no second state label. Unknown values are not evidence of a block.
            var blocksReachability: Bool {
                switch state {
                case "paused", "unavailable": true
                default: false
                }
            }
            var text: String? { blocksReachability ? CompanionMachineStatePresentation.unreachableFromPhone : nil }
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

        var chatLabel: String {
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
            // Beta.4 presence published the controller name without the chosen chat name.
            if text.isEmpty || text == "\(CompanionDispatcher.controllerName) on \(machineName)" {
                return "\(CompanionDispatcher.chatDisplayName(dispatcherName, fromPresence: true)) on \(machineName)"
            }
            return text
        }

        var machineState: CompanionMachineState { .init(presenceState: state) }
        func presentation(now: Date = Date()) -> CompanionMachineStatePresentation {
            let seen = lastSeen.flatMap {
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0))
                    ?? (try? Date.ISO8601FormatStyle().parse($0))
            }
            return machineState.presentation(lastSeen: seen, linkBlocked: link.blocksReachability, now: now)
        }
        func stateText(now: Date = Date()) -> String { presentation(now: now).label }
        func detailText(now: Date = Date()) -> String { presentation(now: now).detail }

        /// Compatibility for RootView's two existing nonoptional Label sites. They will adopt presentation.symbol.
        var symbol: String { machineState.symbol ?? "circle" }
    }

    var remotes: [Remote]
}

struct CompanionDispatcherSwitcherRow: Identifiable {
    var id: String
    var desktop: CompanionDispatcherDesktop?
    var presence: CompanionDispatcherPresence.Remote?
    var label: String { desktop?.accessibilityLabel ?? presence?.chatLabel ?? CompanionDispatcher.name }
    var detail: String? { presence?.presentation().menuDetail }
    var accessibilityLabel: String { [label, presence?.detailText()].compactMap { $0 }.joined(separator: ", ") }

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
            let name = ($0.desktop?.displayName ?? CompanionDispatcher.chatDisplayName($0.presence?.dispatcherName, fromPresence: true))
                .localizedStandardCompare($1.desktop?.displayName ?? CompanionDispatcher.chatDisplayName($1.presence?.dispatcherName, fromPresence: true))
            if name != .orderedSame { return name == .orderedAscending }
            let machine = ($0.presence?.machineName ?? $0.desktop?.name ?? "")
                .localizedStandardCompare($1.presence?.machineName ?? $1.desktop?.name ?? "")
            return machine == .orderedSame ? $0.id < $1.id : machine == .orderedAscending
        }
    }
}
