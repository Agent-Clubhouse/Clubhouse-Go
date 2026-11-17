#if DEBUG
import Foundation
import ClubhouseTransport

/// Synthetic layout input: two live trees (with repeated IDs), a quiet-only machine,
/// and a disconnected machine whose cached Working state must never count as live.
enum CompanionHomeLinkedFixture {
    static func hosts(now: Date = Date()) -> [CompanionHost] {
        let names = ["Studio Mac", "Travel MacBook", "Archive Mac", "Offline Mac"]
        var hosts: [CompanionHost] = []
        for index in names.indices {
            let hostID = "combined-\(index)"
            func agent(_ id: String, _ name: String, _ status: CompanionAgentStatus, secondsAgo: Double) -> CompanionAgent {
                .init(id: .init(hostID: hostID, projectID: "project", agentID: id), name: name,
                      subtitle: "Synthetic linked project task", status: status, lastActivity: now.addingTimeInterval(-secondsAgo))
            }
            var agents: [CompanionAgent]
            switch index {
            case 0, 1:
                var helper = agent("helper", index == 0 ? "Fern" : "Willow", .idle, secondsAgo: 5)
                helper.parentAgentID = "root"
                agents = [agent("root", index == 0 ? "Cedar" : "River", .working, secondsAgo: index == 0 ? 20 : 10), helper]
            case 2:
                agents = [agent("sleeper", "Juniper", .sleeping, secondsAgo: 60)]
            default:
                agents = [agent("root", "Cached River", .working, secondsAgo: 0)]
            }
            if index < 3 {
                var finished = agent("finished", ["Maple", "Birch", "Ash"][index], .completed, secondsAgo: 120)
                finished.subtitle = "\(finished.name) synthetic task"
                finished.isQuick = true
                finished.hasExited = true
                agents.append(finished)
            }
            var host = CompanionHost(id: hostID, name: names[index], endpoint: "", connection: index == 3 ? .offline : .connected,
                projects: [.init(id: "project", name: "Clubhouse", agents: agents)])
            host.hasLoadedCatalog = true
            host.canSpawn = true
            host.canLinkProjects = true
            hosts.append(host)
        }
        let links = AnnexProjectLinks(projectLinks: [.init(id: "combined-home", projects: hosts.map {
            .init(machine: $0.id, projectId: "project")
        }, name: "Clubhouse")])
        for index in hosts.indices { hosts[index].projectLinks = links }
        return hosts
    }
}
#endif
