import Foundation
import Testing
@testable import ClubhouseTransport

/// Machine-qualified agent addresses (#339, desktop `docs/annex-network-phone.md` §Agent addresses), against the
/// desktop's recorded fixtures: `agent-address.json`, `snapshot.json`, `capabilities.json` and `commands/_common.json`.
@Suite struct AgentAddressTests {
    static let studio = "aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa"
    static let other = "bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb"

    // MARK: Contract fixtures

    @Test func theSnapshotsMachineDecodes() throws {
        let fixture = try AnnexContract.json("agent-address.json")
        let machine = try #require(fixture["snapshotField"]?["machine"]).decode(AnnexMachine.self)
        #expect(machine == .init(fingerprint: Self.studio, name: "Studio Mac"))
        let snapshot = try #require(try AnnexContract.json("snapshot.json")["frame"]?["payload"]?["machine"]).decode(AnnexMachine.self)
        #expect(AnnexAgentAddress.isMachineFingerprint(snapshot.fingerprint) && !snapshot.name.isEmpty)
    }

    @Test func theCapabilityIsAdvertisedAndCheckedFieldByField() throws {
        let caps = try #require(try AnnexContract.json("capabilities.json")["response"]?["body"]).decode(AnnexCapabilities.self)
        #expect(caps.supportsAgentAddress)
        #expect(caps.agentAddress?.wrongMachineCode == AnnexAgentAddressCapability.wrongMachine)
        guard case .object(let block)? = try AnnexContract.json("capabilities.json")["response"]?["body"]?["agentAddress"] else {
            Issue.record("no agentAddress block"); return
        }
        for key in block.keys.sorted() {
            var damaged = block; damaged[key] = key == "version" ? .integer(2) : .string("other")
            #expect(try !AnnexJSON.object(damaged).decode(AnnexAgentAddressCapability.self).isSupported, "\(key)")
        }
    }

    @Test func aWrongMachineReceiptNamesTheOtherMachine() throws {
        let body = try #require(try AnnexContract.json("agent-address.json")["wrongMachine"]?["body"])
        let receipt = try body.decode(AnnexCommandReceipt.self)
        #expect(receipt.status == .rejected && receipt.error?.code == "wrong_machine")
        #expect(receipt.wrongMachine == Self.other)
        // Only a well-formed machine on a wrong_machine refusal counts.
        guard case .object(var fields) = body else { return }
        fields["machine"] = .string("bb")
        #expect(try AnnexJSON.object(fields).decode(AnnexCommandReceipt.self).wrongMachine == nil)
        fields["machine"] = .string(Self.other.uppercased())
        #expect(try AnnexJSON.object(fields).decode(AnnexCommandReceipt.self).wrongMachine == Self.other)
        fields["error"] = .object(["code": .string("agent_not_found"), "message": .string("agent_not_found")])
        #expect(try AnnexJSON.object(fields).decode(AnnexCommandReceipt.self).wrongMachine == nil)
    }

    /// The desktop's recorded refusal, through the real transport: a definitive answer naming the machine, and the
    /// phone builds the qualified request byte for byte.
    @Test func theRecordedRefusalIsReadThroughTheTransport() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        let item = try #require(try AnnexContract.cases("commands/_common.json").first { $0["response"]?["body"]?["machine"] != nil })
        let request = try #require(item["request"])
        let agent = try #require(request["agentId"]?.string)
        let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: .stop(agentID: agent))
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == request)
        #expect(command.agentReference == agent)
        #expect(AnnexAgentAddress(parsing: agent) == .init(agentID: "durable_chat", machine: Self.other))

        let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(item["response"])])
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.capabilities)
        let receipt = try await transport.execute(command)
        #expect(receipt.wrongMachine == Self.other)
        // A retry in the same form replays the recorded refusal; the other form of the agent is a different command
        // (the desktop would answer command_conflict), refused before anything is sent.
        #expect(try await transport.execute(command) == receipt)
        let bare = AnnexCommand(commandID: command.commandID, epoch: command.epoch, kind: .stop(agentID: "durable_chat"))
        await #expect(throws: AnnexTransportError.duplicateCommandConflict) { try await transport.execute(bare) }
        #expect(await io.requests.count == 2)
    }

    // MARK: Addresses

    @Test func addressesParseAndFormatAsTheDesktopDoes() {
        let upper = Self.other.uppercased()
        #expect(AnnexAgentAddress(parsing: "agent@\(upper)") == .init(agentID: "agent", machine: Self.other))
        #expect(AnnexAgentAddress(parsing: "agent@\(upper)").formatted == "agent@\(Self.other)")
        #expect(AnnexAgentAddress(parsing: "agent").formatted == "agent")
        // Anything without a well-formed machine after the last `@` is a plain id.
        #expect(AnnexAgentAddress(parsing: "agent@studio").machine == nil)
        #expect(AnnexAgentAddress(parsing: "agent@studio").agentID == "agent@studio")
        #expect(AnnexAgentAddress(parsing: "@\(Self.other)").agentID == "@\(Self.other)")
        #expect(AnnexAgentAddress(parsing: "a@b@\(Self.other)") == .init(agentID: "a@b", machine: Self.other))
        // 16 to 32 bytes of two hex digits.
        #expect(AnnexAgentAddress.isMachineFingerprint(Self.other))
        #expect(AnnexAgentAddress.isMachineFingerprint(Array(repeating: "0f", count: 32).joined(separator: ":")))
        #expect(!AnnexAgentAddress.isMachineFingerprint(Array(repeating: "0f", count: 15).joined(separator: ":")))
        #expect(!AnnexAgentAddress.isMachineFingerprint(Array(repeating: "0f", count: 33).joined(separator: ":")))
        #expect(!AnnexAgentAddress.isMachineFingerprint(Array(repeating: "zz", count: 16).joined(separator: ":")))
        #expect(!AnnexAgentAddress.isMachineFingerprint(Array(repeating: "f", count: 16).joined(separator: ":")))
        #expect(!AnnexAgentAddress.isMachineFingerprint(Self.other + ":"))
        // Where it routes.
        #expect(AnnexAgentAddress(parsing: "agent@\(upper)").isElsewhere(than: Self.studio))
        #expect(!AnnexAgentAddress(parsing: "agent@\(Self.other)").isElsewhere(than: upper))
        #expect(!AnnexAgentAddress(parsing: "agent").isElsewhere(than: Self.studio))
    }

    @Test func commandsSayWhichAgentTheyName() {
        func reference(_ kind: AnnexCommand.Kind) -> String? { AnnexCommand(epoch: "e", kind: kind).agentReference }
        #expect(reference(.send(agentID: "a", sessionID: "s", text: "t")) == "a")
        #expect(reference(.dismissFinishedQuick(projectID: "p", agentID: "q")) == "q")
        #expect(reference(.update(AnnexAgentUpdate(agentID: "u"))) == "u")
        #expect(reference(.setDispatcherEnabled(true)) == nil)
        #expect(reference(.spawn(projectID: "p", prompt: "x")) == nil)
        #expect(reference(.helperApprove(requestID: "r")) == nil)
    }

    // MARK: The snapshot's machine and the pinned identity

    private func connect(machine: AnnexJSON?, advertise: Bool = true) async throws -> AnnexConnectionState {
        let io = MachineIO(machine: machine, advertise: advertise)
        let id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id,
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let credentials = MemoryAnnexCredentialStore(); await credentials.save(try AnnexCredential(bearerToken: "test-only"), for: id)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
        let events = await transport.events()
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        for try await event in events {
            guard case .connection(let state) = event else { continue }
            switch state {
            case .connected, .failed: return state
            default: continue
            }
        }
        return .disconnected
    }
    private func machine(_ fingerprint: String) -> AnnexJSON { .object(["fingerprint": .string(fingerprint), "name": .string("Studio Mac")]) }

    @Test func aSnapshotFromThePinnedMachineConnects() async throws {
        #expect(try await connect(machine: .string(MachineIO.selfMarker)) == .connected)
    }

    @Test func aSnapshotFromAnotherMachineIsAnIdentityError() async throws {
        #expect(try await connect(machine: machine(Self.other)) == .failed(.identityMismatch))
    }

    @Test func aSnapshotWithoutItsMachineOrWithAnUnreadableOneIsRefused() async throws {
        #expect(try await connect(machine: nil) == .failed(.malformedResponse))
        #expect(try await connect(machine: .null) == .failed(.malformedResponse))
        #expect(try await connect(machine: .string("Studio Mac")) == .failed(.malformedResponse))
        #expect(try await connect(machine: machine("studio")) == .failed(.malformedResponse))
    }

    @Test func aDesktopThatDoesntAdvertiseAddressesStillHasItsMachineChecked() async throws {
        #expect(try await connect(machine: nil, advertise: false) == .connected)
        #expect(try await connect(machine: machine(Self.other), advertise: false) == .failed(.identityMismatch))
    }
}

/// Serves an identity, the recorded capabilities (with or without `agentAddress`), and one socket whose first
/// frame is the recorded snapshot with its `machine` replaced.
private actor MachineIO: AnnexIO {
    /// Stands for this host's own fingerprint in `machine`, which a test can't know before the identity exists.
    static let selfMarker = "<self>"
    nonisolated let identity = AnnexPairingIdentity()
    let machine: AnnexJSON?
    let advertise: Bool
    init(machine: AnnexJSON?, advertise: Bool) { self.machine = machine; self.advertise = advertise }

    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64)
        if request.url!.path.hasSuffix("/identity") {
            return try .init(status: 200, data: JSONEncoder().encode(AnnexJSON.object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(fingerprint)])))
        }
        guard case .object(var caps)? = try AnnexContract.json("capabilities.json")["response"]?["body"] else { throw AnnexTransportError.malformedResponse }
        if !advertise { caps.removeValue(forKey: "agentAddress") }
        return try .init(status: 200, data: AnnexContract.encode(.object(caps)))
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64)
        guard case .object(var frame)? = try AnnexContract.json("snapshot.json")["frame"], case .object(var payload)? = frame["payload"] else {
            throw AnnexTransportError.malformedResponse
        }
        switch machine {
        case nil: payload.removeValue(forKey: "machine")
        case .string(Self.selfMarker)?: payload["machine"] = .object(["fingerprint": .string(fingerprint.uppercased()), "name": .string("Studio Mac")])
        case let value?: payload["machine"] = value
        }
        frame["payload"] = .object(payload)
        return MachineSocket(first: try AnnexContract.encode(.object(frame)))
    }
}

private actor MachineSocket: AnnexWebSocket {
    var first: Data?
    var pending: CheckedContinuation<Data, Error>?
    init(first: Data) { self.first = first }
    func receive() async throws -> Data {
        if let first { self.first = nil; return first }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) {}
    func ping() {}
    func close() { pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil }
}
