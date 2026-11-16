import Foundation
import Testing
@testable import CompanionDomain
@testable import ClubhouseTransport

struct CompanionProjectInfoTests {
    @Test func snapshotAndRESTProjectRootsArePreservedWithoutInferringAWorktree() throws {
        let snapshot = (try ContractFixtures.json("snapshot.json")["frame"]?["payload"]?["projects"]).arrayValue
        let rest = (try ContractFixtures.json("rest-catalog.json")["projects"]?["response"]?["body"]).arrayValue
        for projects in [snapshot, rest] {
            let value = try #require(projects.first)
            let project = CompanionLiveService.project(value, id: "proj_app", agents: [], icon: nil)
            #expect(project.path == "/work/app")
        }
        for value in [AnnexJSON.object([:]), .object(["path": .null]), .object(["path": .integer(1)])] {
            #expect(CompanionLiveService.project(value, id: "p", agents: [], icon: nil).path == nil)
        }
        let windows: AnnexJSON = .object(["path": .string(#"C:\work\Project with spaces"#)])
        #expect(CompanionLiveService.project(windows, id: "p", agents: [], icon: nil).path == #"C:\work\Project with spaces"#)
    }

    @Test func defaultsUseTheExistingContractAndKeepTheDesktopNames() throws {
        var options = try CompanionCreateOptions(json: ContractFixtures.body("create-options.json"))
        let defaults = CompanionProjectInfoDefaults(options: options)
        #expect(defaults.access == "Ask first")
        #expect(defaults.mcpServers == ["GitHub"])
        #expect(options.mcpDefaultsReported)
        options.options.accessLevels = [.init(id: .ask, label: "Desktop access label", description: "")]
        #expect(CompanionProjectInfoDefaults(options: options).access == "Desktop access label")
    }

    @Test func missingAndMalformedMCPDefaultsDoNotClaimAnEmptySelection() throws {
        for mcp in [AnnexJSON.object([:]), .object(["defaults": .null]), .object(["defaults": .string("bad")]),
                    .object(["defaults": .array([.string("github"), .integer(1)])])] {
            let json: AnnexJSON = .object(["defaults": .object([:]), "mcp": mcp])
            let options = try CompanionCreateOptions(json: json)
            #expect(!options.mcpDefaultsReported)
            #expect(CompanionProjectInfoDefaults(options: options).mcpServers == nil)
            #expect(CompanionProjectInfoDefaults(options: options).access == nil)
        }
        let options = try CompanionCreateOptions(json: .object(["defaults": .object([:]), "mcp": .object(["defaults": .array([])])]))
        #expect(options.mcpDefaultsReported)
        #expect(CompanionProjectInfoDefaults(options: options).mcpServers == [])
    }

    @Test func aReceivedMCPDefaultSurvivesAnIncompleteCatalogAndDuplicatesDoNotRepeatRows() throws {
        var options = try CompanionCreateOptions(json: ContractFixtures.body("create-options.json"))
        options.mcpDefaults = ["github", "custom-server", "github"]
        #expect(CompanionProjectInfoDefaults(options: options).mcpServers == ["GitHub", "custom-server"])
    }

    @Test func linkedEntriesKeepEachReportedMachineRoot() {
        let a = CompanionHost(id: "a", name: "Studio", endpoint: "a", connection: .connected,
                              projects: [.init(id: "p", name: "App", agents: [], path: "/work/app")])
        let b = CompanionHost(id: "b", name: "Laptop", endpoint: "b", connection: .connected,
                              projects: [.init(id: "q", name: "Copy", agents: [], path: "/Users/me/app")])
        let link = AnnexProjectLinks.Group(id: "linked", projects: [.init(machine: "a", projectId: "p"), .init(machine: "b", projectId: "q")])
        let entry = CompanionLinkedProjects.entries(hosts: [a, b], links: [link]).first
        #expect(entry?.members.map(\.project.path) == ["/work/app", "/Users/me/app"])
        #expect(entry?.members.map(\.host.name) == ["Studio", "Laptop"])
        let single = CompanionLinkedProjects.entries(hosts: [a], links: []).first
        #expect(single?.members.map(\.project.path) == ["/work/app"])
    }
}
