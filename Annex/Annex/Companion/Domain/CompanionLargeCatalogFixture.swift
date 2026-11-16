#if DEBUG
import Foundation
import ClubhouseTransport

/// Generated, sanitized scale input. No pairing, user catalog, file path or network data is read.
enum CompanionLargeCatalogFixture {
    static func hosts(hostCount: Int = 8, projectsPerHost: Int = 48, agentsPerProject: Int = 20) -> [CompanionHost] {
        let linkedCount = min(8, projectsPerHost)
        var groups: [AnnexProjectLinks.Group] = []
        if hostCount > 1 {
            for p in 0..<linkedCount {
                groups.append(.init(id: "synthetic-link-\(p)", projects: [
                    .init(machine: "synthetic-host-0", projectId: "project-\(p)"),
                    .init(machine: "synthetic-host-1", projectId: "project-\(p)")
                ], name: "Shared Synthetic Project \(p)"))
            }
        }
        let links = AnnexProjectLinks(projectLinks: groups)
        var hosts: [CompanionHost] = []
        for h in 0..<hostCount {
            let hostID = "synthetic-host-\(h)"
            var projects: [CompanionProject] = []
            var states: [String: CompanionProjectState] = [:]
            for p in 0..<projectsPerHost {
                let projectID = "project-\(p)"
                var agents: [CompanionAgent] = []
                for a in 0..<agentsPerProject {
                    agents.append(.init(id: .init(hostID: hostID, projectID: projectID, agentID: "agent-\(a)"),
                        name: "Synthetic agent \(a)", subtitle: "Generated catalog regression task",
                        status: a == 0 ? .sleeping : .working, lastActivity: Date(timeIntervalSince1970: 1_800_000_000)))
                }
                projects.append(.init(id: projectID, name: "Synthetic Project \(p)", agents: agents))
                states[projectID] = .init(linked: h < 2 && p < linkedCount)
            }
            var host = CompanionHost(id: hostID, name: "Synthetic Desktop \(h)", endpoint: "", connection: .connected, projects: projects)
            host.canLinkProjects = true; host.projectLinks = links; host.hasLoadedCatalog = true
            host.canSpawn = true; host.canSyncProjectState = true; host.canSyncLinkedProjectState = true
            host.projectState = states
            hosts.append(host)
        }
        return hosts
    }
}
#endif
