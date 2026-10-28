import Testing
import Foundation
@testable import ClubhouseTransport

// quick.dismiss / quick.clear and the finishedQuickAgents capability (desktop Agent-Clubhouse/Clubhouse#2468).

private func decoded(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
    try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "cmd", epoch: "e", kind: kind).encoded())
}
private func keys(_ value: AnnexJSON) -> Set<String> {
    if case .object(let fields) = value { Set(fields.keys) } else { [] }
}
private let envelope: Set<String> = ["version", "commandId", "epoch", "type"]

private func capabilities(commands: [String], feature: String? = #"{"version":1}"#) throws -> AnnexCapabilities {
    let list = commands.map { "\"\($0)\"" }.joined(separator: ",")
    let field = feature.map { #","finishedQuickAgents":\#($0)"# } ?? ""
    let json = #"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(list)],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}\#(field)}"#
    return try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8))
}

private let quickCommands = ["chat.send", "quick.dismiss", "quick.clear"]

@Test func dismissEncodesTheProjectAndAgent() throws {
    let value = try decoded(.dismissFinishedQuick(projectID: "proj-1", agentID: "quick-1"))
    #expect(value["type"]?.string == "quick.dismiss")
    #expect(keys(value) == envelope.union(["projectId", "agentId"]))
    #expect(value["projectId"]?.string == "proj-1" && value["agentId"]?.string == "quick-1")
}

@Test func clearEncodesOnlyTheProject() throws {
    let value = try decoded(.clearFinishedQuick(projectID: "proj-1"))
    #expect(value["type"]?.string == "quick.clear")
    #expect(keys(value) == envelope.union(["projectId"]))
}

@Test func finishedQuickAgentsNeedTheFeatureAndBothCommands() throws {
    #expect(try capabilities(commands: quickCommands).supportsFinishedQuickAgents)
    #expect(try !capabilities(commands: quickCommands, feature: nil).supportsFinishedQuickAgents, "An older desktop keeps the list on the phone")
    #expect(try !capabilities(commands: quickCommands, feature: #"{"version":0}"#).supportsFinishedQuickAgents)
    #expect(try !capabilities(commands: ["chat.send", "quick.dismiss"]).supportsFinishedQuickAgents, "Both commands are needed")
}

@Test func finishedQuickCommandsAreMeasuredTogether() {
    #expect(AnnexCommand(epoch: "e", kind: .dismissFinishedQuick(projectID: "p", agentID: "a")).diagnosticOperation == .finishedQuick)
    #expect(AnnexCommand(epoch: "e", kind: .clearFinishedQuick(projectID: "p")).diagnosticOperation == .finishedQuick)
}
