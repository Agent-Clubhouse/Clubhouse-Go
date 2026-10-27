import Testing
import Foundation
@testable import ClubhouseTransport

// chat.setModel / chat.setLevel and the chatControls and permissions capabilities (desktop Agent-Clubhouse/Clubhouse#2464).

private func decoded(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
    try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "cmd", epoch: "e", kind: kind).encoded())
}
private func keys(_ value: AnnexJSON) -> Set<String> {
    if case .object(let fields) = value { Set(fields.keys) } else { [] }
}
private let envelope: Set<String> = ["version", "commandId", "epoch", "type"]

private func caps(commands: [String], extra: String = "") throws -> AnnexCapabilities {
    let list = commands.map { "\"\($0)\"" }.joined(separator: ",")
    let json = #"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(list)],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}\#(extra)}"#
    return try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8))
}
private let allCommands = ["chat.send", "chat.permission", "agent.create", "agent.update", "chat.setModel", "chat.setLevel"]
private let newFeatures = #","chatControls":{"version":1},"permissions":{"version":1,"persistentApprovals":true,"freeAgentMode":true}"#

@Test func setModelEncodesEffortAsStringNullOrOmitted() throws {
    let omitted = try decoded(.setModel(agentID: "a", sessionID: "s", model: "opus"))
    #expect(omitted["type"]?.string == "chat.setModel")
    #expect(keys(omitted) == envelope.union(["agentId", "sessionId", "model"]))
    #expect(omitted["model"]?.string == "opus" && omitted["agentId"]?.string == "a" && omitted["sessionId"]?.string == "s")

    let chosen = try decoded(.setModel(agentID: "a", sessionID: "s", model: "opus", effort: .set("xhigh")))
    #expect(keys(chosen) == envelope.union(["agentId", "sessionId", "model", "effort"]))
    #expect(chosen["effort"]?.string == "xhigh")

    // `null` is the provider's default, so it must reach the wire rather than be dropped.
    let providerDefault = try decoded(.setModel(agentID: "a", sessionID: "s", model: "opus", effort: .providerDefault))
    #expect(keys(providerDefault).contains("effort"))
    #expect(providerDefault["effort"] == .null)
}

@Test func setModelRefusesEmptyOrOversizedValuesBeforeSending() {
    #expect(throws: AnnexTransportError.malformedResponse) { try decoded(.setModel(agentID: "a", sessionID: "s", model: "")) }
    #expect(throws: AnnexTransportError.malformedResponse) { try decoded(.setModel(agentID: "a", sessionID: "s", model: "m", effort: .set(""))) }
    #expect(throws: AnnexTransportError.malformedResponse) {
        try decoded(.setModel(agentID: "a", sessionID: "s", model: "m", effort: .set(String(repeating: "x", count: 65))))
    }
}

@Test func setLevelEncodesTheLadderAndRefusesAnythingElse() throws {
    for level in ["plan", "ask", "auto_edit", "auto", "full_access"] {
        let value = try decoded(.setLevel(agentID: "a", sessionID: "s", level: level))
        #expect(value["type"]?.string == "chat.setLevel")
        #expect(keys(value) == envelope.union(["agentId", "sessionId", "level"]))
        #expect(value["level"]?.string == level)
    }
    #expect(throws: AnnexTransportError.malformedResponse) { try decoded(.setLevel(agentID: "a", sessionID: "s", level: "bypassPermissions")) }
    #expect(AnnexCommand.permissionLevels == ["plan", "ask", "auto_edit", "auto", "full_access"])
}

@Test func newCommandsUseTheGenericCommandDiagnostic() {
    #expect(AnnexCommand(epoch: "e", kind: .setLevel(agentID: "a", sessionID: "s", level: "ask")).diagnosticOperation == .command)
    #expect(AnnexCommand(epoch: "e", kind: .setModel(agentID: "a", sessionID: "s", model: "m")).diagnosticOperation == .command)
}

@Test func currentDesktopAdvertisesChatControlsAndFullPermissionControl() throws {
    let current = try caps(commands: allCommands, extra: newFeatures)
    #expect(current.supportsModelSwitch && current.supportsLevelSwitch)
    #expect(current.supportsPersistentApprovals && current.supportsFreeAgentMode)
    #expect(current.chatControls == .init(version: 1, path: nil))
    #expect(current.permissions == .init(version: 1, persistentApprovals: true, freeAgentMode: true))
}

@Test func olderDesktopsKeepTheReadOnlyBehaviour() throws {
    let older = try caps(commands: ["chat.send", "chat.permission", "agent.create", "agent.update"])
    #expect(older.chatControls == nil && older.permissions == nil)
    #expect(!older.supportsModelSwitch && !older.supportsLevelSwitch)
    #expect(!older.supportsPersistentApprovals && !older.supportsFreeAgentMode)

    // The block without the commands, or the commands without the block, offer nothing.
    let blockOnly = try caps(commands: ["chat.send"], extra: #","chatControls":{"version":1}"#)
    #expect(!blockOnly.supportsModelSwitch && !blockOnly.supportsLevelSwitch)
    let commandsOnly = try caps(commands: allCommands)
    #expect(!commandsOnly.supportsModelSwitch && !commandsOnly.supportsLevelSwitch)
    let versionZero = try caps(commands: allCommands, extra: #","chatControls":{"version":0},"permissions":{"version":0,"persistentApprovals":true,"freeAgentMode":true}"#)
    #expect(!versionZero.supportsModelSwitch && !versionZero.supportsPersistentApprovals && !versionZero.supportsFreeAgentMode)
}

@Test func permissionsGrantOnlyWhatTheyName() throws {
    let approvalsOnly = try caps(commands: allCommands, extra: #","permissions":{"version":1,"persistentApprovals":true,"freeAgentMode":false}"#)
    #expect(approvalsOnly.supportsPersistentApprovals && !approvalsOnly.supportsFreeAgentMode)
    // Persistent approvals ride on chat.permission.
    let noPermissionCommand = try caps(commands: ["chat.send"], extra: newFeatures)
    #expect(!noPermissionCommand.supportsPersistentApprovals)
    // A malformed block grants nothing and doesn't break the capability document.
    let malformed = try caps(commands: allCommands, extra: #","permissions":{"version":"one","persistentApprovals":"yes"}"#)
    #expect(!malformed.supportsPersistentApprovals && !malformed.supportsFreeAgentMode)
}
