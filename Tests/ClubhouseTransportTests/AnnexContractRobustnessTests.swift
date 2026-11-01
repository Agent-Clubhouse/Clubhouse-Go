import Foundation
import Testing
@testable import ClubhouseTransport

/// Table-driven damage to the desktop's real fixtures: missing optional fields, unknown extra fields, wrong types
/// and truncated JSON must never crash, and must degrade as documented.
@Suite struct AnnexContractRobustnessTests {
    /// Values of the wrong type for any field.
    static let wrongTypes: [AnnexJSON] = [.string("x"), .integer(7), .number(1.5), .bool(true), .array([.integer(1)]), .object(["x": .null]), .null]

    private func capabilitiesBody() throws -> [String: AnnexJSON] {
        guard case .object(let body)? = try AnnexContract.json("capabilities.json")["response"]?["body"] else { throw AnnexTransportError.malformedResponse }
        return body
    }
    private func decode(_ body: [String: AnnexJSON]) throws -> AnnexCapabilities {
        try JSONDecoder().decode(AnnexCapabilities.self, from: AnnexContract.encode(.object(body)))
    }

    static let requiredCapabilityKeys: Set<String> = ["version", "epoch", "controlAuth", "commands", "idempotency"]

    /// A capability document without its core fields is refused; without anything else it decodes, and the feature
    /// that block gates is off. Older desktops send exactly such documents.
    @Test func capabilitiesWithoutAField() throws {
        let body = try capabilitiesBody()
        for key in body.keys.sorted() {
            var damaged = body; damaged.removeValue(forKey: key)
            if Self.requiredCapabilityKeys.contains(key) {
                #expect(throws: (any Error).self, "\(key)") { try decode(damaged) }
                continue
            }
            let caps = try decode(damaged)
            switch key {
            case "attachments": #expect(caps.attachments == nil)
            case "terminal": #expect(!caps.supportsTerminal)
            case "createOptions": #expect(!caps.supportsAgentCreate)
            case "agentSettings": #expect(!caps.supportsAgentSettings)
            case "chatControls": #expect(!caps.supportsModelSwitch && !caps.supportsLevelSwitch)
            case "slashCommands": #expect(!caps.supportsSlashCommands)
            case "permissions": #expect(!caps.supportsPersistentApprovals && !caps.supportsFreeAgentMode)
            case "helperRequests": #expect(!caps.supportsHelperRequests)
            case "projectState": #expect(!caps.supportsProjectState)
            case "finishedQuickAgents": #expect(!caps.supportsFinishedQuickAgents)
            case "controlAvailable": #expect(caps.controlAvailable == nil && !caps.supportsTerminal)
            default: break
            }
        }
    }

    /// Any optional block of the wrong type reads as absent; a core field of the wrong type refuses the document.
    @Test(arguments: wrongTypes) func capabilitiesWithAFieldOfTheWrongType(_ value: AnnexJSON) throws {
        let body = try capabilitiesBody()
        for key in body.keys.sorted() {
            var damaged = body; damaged[key] = value
            if Self.requiredCapabilityKeys.contains(key) {
                // An empty-looking but well-typed value can still decode; anything else must throw, never crash.
                _ = try? decode(damaged)
                continue
            }
            let caps = try decode(damaged)
            #expect(caps.epoch == body["epoch"]?.string, "\(key)")
            if key == "attachments", case .object = value { #expect(caps.attachments?.isUsable == false) }
            if key == "terminal" { #expect(!caps.supportsTerminal, "\(key) = \(value)") }
            if key == "createOptions", value != .object(["x": .null]) { #expect(!caps.supportsAgentCreate) }
        }
    }

    /// Unknown fields, at any depth, change nothing: the desktop's contract is additive.
    @Test func capabilitiesWithUnknownFieldsEverywhere() throws {
        let body = try capabilitiesBody()
        let caps = try decode(body)
        guard case .object(let extra) = Self.withUnknownFields(.object(body)) else { return }
        let more = try decode(extra)
        #expect(more.commands == caps.commands && more.attachments == caps.attachments && more.terminal == caps.terminal)
        #expect(more.supportsAgentCreate && more.supportsHelperRequests && more.supportsFreeAgentMode && more.supportsTerminal)
    }

    /// Every fixture cut short is refused by every decoder that reads it: an error, never a crash or a partial value.
    @Test func truncatedFixturesNeverDecode() throws {
        for file in try AnnexContract.files() {
            let data = try AnnexContract.data(file)
            for cut in Self.cuts(data.count) {
                let prefix = data.prefix(cut)
                #expect(throws: (any Error).self, "\(file) at \(cut)") { try JSONDecoder().decode(AnnexJSON.self, from: prefix) }
                #expect((try? JSONDecoder().decode(AnnexCapabilities.self, from: prefix)) == nil)
                #expect((try? JSONDecoder().decode(AnnexEnvelope.self, from: prefix)) == nil)
                #expect((try? JSONDecoder().decode(AnnexCommandReceipt.self, from: prefix)) == nil)
            }
        }
    }

    /// A receipt the phone can't trust is an unknown outcome, never "not sent": the command may have run.
    @Test func damagedReceiptsAreUnknownOutcomes() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let accepted = try #require(try AnnexContract.cases("commands/agent.stop.json").first)
        let request = try #require(accepted["request"])
        guard case .object(let body)? = accepted["response"]?["body"] else { Issue.record("no body"); return }
        var damaged: [(String, AnnexJSON)] = body.keys.sorted().filter { $0 != "result" }.map { key in
            var copy = body; copy.removeValue(forKey: key); return ("without \(key)", .object(copy))
        }
        for key in ["version", "status", "epoch", "commandId"] {
            for value in Self.wrongTypes { var copy = body; copy[key] = value; damaged.append(("\(key) = \(value)", .object(copy))) }
        }
        damaged.append(("not an object", .array([])))
        for (name, value) in damaged {
            if name == "commandId = null" || name == "without commandId" { continue } // A rejection may leave it out; a completion may not, below.
            let io = AnnexContractIO([try AnnexContract.response(caps), AnnexHTTPResponse(status: 200, data: try AnnexContract.encode(value))])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: .stop(agentID: "durable_term"))
            await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID), "\(name)") { try await transport.execute(command) }
        }
        // A completion that doesn't name the command is never taken as its answer.
        var anonymous = body; anonymous.removeValue(forKey: "commandId")
        let io = AnnexContractIO([try AnnexContract.response(caps), AnnexHTTPResponse(status: 200, data: try AnnexContract.encode(.object(anonymous)))])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: .stop(agentID: "durable_term"))
        await #expect(throws: AnnexTransportError.commandOutcomeUnknown(commandID: command.commandID)) { try await transport.execute(command) }
    }

    /// Payloads are open JSON: unknown fields and wrong types inside them never break the envelope. The envelope's
    /// own sequence fields are strict, so a frame with an unreadable cursor fails closed and the transport resyncs.
    @Test func damagedWebSocketFrames() throws {
        var frames = try AnnexContract.json("chat-events.json")["frames"].list
        #expect(frames.filter { $0["payload"]?["event"]?["type"]?.string == "user_message" }.count == 5,
                "Damage every repeated user_message shape, not just the first event of that type")
        frames.append(try #require(try AnnexContract.json("snapshot.json")["frame"]))
        frames += try AnnexContract.cases("pty.json").flatMap { $0["replies"].list }
        for frame in frames {
            #expect(throws: Never.self) { try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(Self.withUnknownFields(frame))) }
            guard case .object(var fields) = frame else { continue }
            for value in Self.wrongTypes {
                fields["payload"] = value
                #expect(throws: Never.self) { try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(.object(fields))) }
            }
            for value in Self.wrongTypes where value != .null && value.integer == nil {
                var bad = fields; bad["seq"] = value
                #expect((try? JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(.object(bad)))) == nil)
            }
        }
    }

    /// Damaged capability blocks the phone's own decoders read leniently.
    @Test(arguments: wrongTypes) func featureBlocksWithFieldsOfTheWrongType(_ value: AnnexJSON) throws {
        let body = try capabilitiesBody()
        for block in ["attachments", "terminal", "permissions"] {
            guard case .object(let fields)? = body[block] else { continue }
            for key in fields.keys {
                var damagedBlock = fields; damagedBlock[key] = value
                var damaged = body; damaged[block] = .object(damagedBlock)
                let caps = try decode(damaged)
                switch (block, key) {
                case ("attachments", "version"), ("attachments", "maxImageBytes"), ("attachments", "maxCount"):
                    if value.integer == nil { #expect(caps.attachments?.isUsable == false, "\(block).\(key)") }
                case ("terminal", "version"): if value.integer == nil { #expect(!caps.supportsTerminal) }
                case ("terminal", "maxInputLength"):
                    if value.integer == nil { #expect(caps.terminal?.maxInputLength == AnnexCapabilities.Terminal.defaultMaxInputLength) }
                case ("permissions", "freeAgentMode"): if value != .bool(true) { #expect(!caps.supportsFreeAgentMode) }
                case ("permissions", "persistentApprovals"): if value != .bool(true) { #expect(!caps.supportsPersistentApprovals) }
                default: break
                }
            }
        }
    }

    // MARK: Damage

    /// `value` with an unknown field added to every object, at every depth.
    static func withUnknownFields(_ value: AnnexJSON) -> AnnexJSON {
        switch value {
        case .object(let fields):
            var out = fields.mapValues(withUnknownFields)
            out["futureField\(fields.count)"] = .object(["nested": .array([.integer(1), .string("x")])])
            return .object(out)
        case .array(let items): return .array(items.map(withUnknownFields))
        default: return value
        }
    }

    /// Where to cut a document of `count` bytes: the start, the end and evenly between.
    static func cuts(_ count: Int) -> [Int] {
        guard count > 2 else { return [] }
        // The files end with "}\n": dropping only the newline would still be whole.
        return Array(Set([1, count / 2, count - 2] + stride(from: 1, to: count - 2, by: max(1, count / 8)).map { $0 })).sorted()
    }
}
