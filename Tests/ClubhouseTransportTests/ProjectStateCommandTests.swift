import Testing
import Foundation
@testable import ClubhouseTransport

// project.setPinned / project.setInactive and the projectState capability (desktop Agent-Clubhouse/Clubhouse#2461).

private func decoded(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
    try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "cmd", epoch: "e", kind: kind).encoded())
}

private func capabilities(commands: [String], projectState: String? = #"{"version":1}"#) throws -> AnnexCapabilities {
    let list = commands.map { "\"\($0)\"" }.joined(separator: ",")
    let feature = projectState.map { #","projectState":\#($0)"# } ?? ""
    let json = #"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(list)],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}\#(feature)}"#
    return try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8))
}

private let projectCommands = ["chat.send", "project.setPinned", "project.setInactive"]

@Test func setPinnedEncodesTheProjectAndFlag() throws {
    let value = try decoded(.setProjectPinned(projectID: "proj-1", pinned: true))
    #expect(value["type"]?.string == "project.setPinned")
    #expect(value["projectId"]?.string == "proj-1")
    #expect(value["pinned"] == .bool(true))
    #expect(value["agentId"] == nil && value["inactive"] == nil)
}

@Test func setInactiveEncodesTheProjectAndFlag() throws {
    let value = try decoded(.setProjectInactive(projectID: "proj-1", inactive: false))
    #expect(value["type"]?.string == "project.setInactive")
    #expect(value["projectId"]?.string == "proj-1")
    #expect(value["inactive"] == .bool(false))
    #expect(value["pinned"] == nil)
}

@Test func projectStateNeedsTheFeatureAndBothCommands() throws {
    #expect(try capabilities(commands: projectCommands).supportsProjectState)
    #expect(try !capabilities(commands: projectCommands, projectState: nil).supportsProjectState, "An older desktop keeps pins on the phone")
    #expect(try !capabilities(commands: projectCommands, projectState: #"{"version":0}"#).supportsProjectState)
    #expect(try !capabilities(commands: ["chat.send", "project.setPinned"]).supportsProjectState, "Both commands are needed")
}
