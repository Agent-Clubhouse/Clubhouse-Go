import Foundation
import Testing
@testable import ClubhouseGo
@testable import ClubhouseTransport

private actor NetworkServiceTransport: AnnexTransporting {
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    var offersNetwork: Bool
    private(set) var networkReads = 0
    let network: AnnexNetworkSnapshot
    init(offersNetwork: Bool, network: AnnexNetworkSnapshot) { self.offersNetwork = offersNetwork; self.network = network }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() { continuation?.yield(.connection(.disconnected)) }
    func emit(_ event: AnnexTransportEvent) { continuation?.yield(event) }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities:
            var value: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("e"), "controlAuth": .string("mtls-pinned-client"),
                "controlAvailable": .bool(true), "commands": .array([]), "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(1), "ttlMs": .integer(1)])]
            if offersNetwork { value["network"] = .object(["version": .integer(1), "path": .string("/api/v1/mobile/network"), "membersPath": .string("/api/v1/mobile/network/members"), "event": .string("network:changed"), "pairField": .string("network")]) }
            return .object(value)
        case .network:
            networkReads += 1
            return try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(network))
        default: return .object(["projects": .array([])])
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
}

@MainActor @Suite(.serialized) struct CompanionNetworkTests {
    private func view() -> AnnexNetworkSnapshot { .init(version: 1, joined: true, members: [], removals: []) }
    private func registration(_ transport: any AnnexTransporting) throws -> AnnexTransportRegistry.Registration {
        .init(host: try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432),
                                        verifiedHostID: "aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa:aa",
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32))), alias: "Studio", transport: transport)
    }
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    @Test func authenticatedNetworkEventAndEveryReconnectReadReachMembership() async throws {
        let service = CompanionLiveService()
        let transport = NetworkServiceTransport(offersNetwork: true, network: view())
        var snapshots: [AnnexNetworkSnapshot] = []
        service.onNetwork = { _, snapshot in snapshots.append(snapshot) }
        try await service.register(registration(transport))
        #expect(await eventually { snapshots.count == 1 })
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(view()))
        await transport.emit(.message(.init(type: "network:changed", payload: payload)))
        #expect(await eventually { snapshots.count == 2 })
        await transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 1)))
        await transport.emit(.connection(.connected))
        #expect(await eventually { snapshots.count == 3 })
        #expect(await transport.networkReads == 2)
        await service.suspend()
    }
    @Test func noCapabilityNeverReadsNetworkAndOfflineUsesExistingHostState() async throws {
        let service = CompanionLiveService()
        let transport = NetworkServiceTransport(offersNetwork: false, network: view())
        let store = CompanionStore(service: service)
        store.start()
        try await service.register(registration(transport))
        #expect(await eventually { store.hosts.first?.connection == .connected })
        #expect(await transport.networkReads == 0)
        await transport.emit(.connection(.disconnected))
        #expect(await eventually { store.hosts.first?.connection == .offline })
        #expect(store.hosts.first?.connection.canOperate == false)
        await service.suspend()
        store.stop()
    }
    @Test func onlyExplicitNetworkRevocationTriggersTheRemovalCallback() async throws {
        let service = CompanionLiveService()
        let transport = NetworkServiceTransport(offersNetwork: false, network: view())
        var refused: [String] = []
        service.onNetworkRefusal = { refused.append($0) }
        let host = try registration(transport)
        await service.register(host)
        await transport.emit(.connection(.failed(.unauthorized)))
        await transport.emit(.connection(.failed(.rejected(status: 401, code: "peer_not_paired"))))
        #expect(await eventually { refused == [host.host.hostID] })
        await service.suspend()
    }
}

private actor NetworkRuntimeSocket: AnnexWebSocket {
    private var first = true
    private var closed = false
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if first {
            first = false
            return Data(#"{"type":"snapshot","lastSeq":0,"payload":{"projects":[],"agents":{},"quickAgents":{},"lastSeq":0}}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func push(_ value: AnnexNetworkSnapshot) throws {
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(value))
        let data = try JSONEncoder().encode(AnnexEnvelope(type: "network:changed", payload: payload))
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { pending.append(data) }
    }
    func send(_ data: Data) {}
    func ping() {}
    func close() { closed = true; waiter?.resume(throwing: AnnexTransportError.disconnected); waiter = nil }
}

private actor NetworkRuntimeIO: AnnexIO {
    let desktop: AnnexClientIdentity
    var view: AnnexNetworkSnapshot
    private(set) var identityReads = 0
    private(set) var pairRequests = 0
    private var socket: NetworkRuntimeSocket?
    init(desktop: AnnexClientIdentity, view: AnnexNetworkSnapshot) { self.desktop = desktop; self.view = view }
    func change(_ view: AnnexNetworkSnapshot) async throws { self.view = view; try await socket?.push(view) }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        let value: AnnexJSON
        if path == "/pair" {
            pairRequests += 1
            value = .object(["token": .string("fixture-only"), "publicKey": .string(desktop.pairingIdentity.publicKeyBase64), "fingerprint": .string(try desktop.fingerprint),
                "alias": .string("Studio"), "tlsCertificateFingerprint": .string(desktop.certificateFingerprint), "mobileProtocolVersion": .integer(1),
                "pairingMode": .string("persistent"), "network": .integer(1),
                "pairing": .object(["id": .string("phone"), "joinedAt": .string("2026-11-08T10:00:00.000Z")]),
                "serverPairing": .object(["id": .string("desktop"), "joinedAt": .string("2026-11-08T10:00:00.000Z")])])
        } else if path == "/api/v1/identity" {
            identityReads += 1
            value = .object(["publicKey": .string(desktop.pairingIdentity.publicKeyBase64), "fingerprint": .string(try desktop.fingerprint)])
        } else if path.hasSuffix("/capabilities") {
            value = try JSONDecoder().decode(AnnexJSON.self, from: Data(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"idempotency":{"scope":"peer-and-epoch","maxEntries":1,"ttlMs":1},"network":{"version":1,"path":"/api/v1/mobile/network","membersPath":"/api/v1/mobile/network/members","event":"network:changed","pairField":"network"}}"#.utf8))
        } else if path.hasSuffix("/network") {
            value = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(view))
        } else { value = .object(["projects": .array([])]) }
        return .init(status: 200, data: try JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = NetworkRuntimeSocket(); self.socket = socket; return socket
    }
}

extension CompanionNetworkTests {
    @Test func qa341RuntimeKeepsALaterPairingAndRebindsAReplacementTransport() async throws {
        let a = try AnnexClientIdentity.ephemeral(), b = try AnnexClientIdentity.ephemeral()
        func member(_ identity: AnnexClientIdentity, isSelf: Bool) throws -> AnnexNetworkMember {
            .init(fingerprint: try identity.fingerprint, publicKey: identity.pairingIdentity.publicKeyBase64, name: "Desktop", icon: "computer", color: "indigo", kind: "desktop", hosts: ["127.0.0.1"], port: 7432,
                  certFingerprint: identity.certificateFingerprint, certPem: "-----BEGIN CERTIFICATE-----\n" + identity.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n",
                  online: true, isSelf: isSelf, joinedAt: "2026-11-08T10:00:00.000Z", pairingId: "desktop")
        }
        let memberA = try member(a, isSelf: true), memberB = try member(b, isSelf: false)
        let initial = AnnexNetworkSnapshot(version: 1, joined: true, members: [memberA, memberB], removals: [])
        let ioA = NetworkRuntimeIO(desktop: a, view: initial), ioB = NetworkRuntimeIO(desktop: b, view: initial)
        let pairings = MemoryAnnexPairingStore()
        let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: pairings, pairingIO: { host, _ in host.hostID == memberA.fingerprint ? ioA : ioB })
        let runtime = CompanionRuntime(registry: registry, persistsDrafts: false)
        await runtime.start()
        try await runtime.pair(host: memberA.trustedHost(), pin: "123456", name: "Studio", remember: true)
        #expect(await eventually { runtime.store.hosts.count == 2 && runtime.store.hosts.allSatisfy { $0.connection == .connected } })
        let repaired = memberB.keepingPairing(id: "new-desktop", joinedAt: "2026-11-08T10:01:00.000Z")
        let removal = AnnexNetworkRemoval(fingerprint: memberB.fingerprint, removedAt: "2026-11-08T12:00:00.000Z", pairingId: "desktop", joinedAt: memberB.joinedAt)
        try await ioA.change(.init(version: 1, joined: true, members: [memberA, repaired], removals: [removal]))
        #expect(await eventually { await pairings.loadAll().first { $0.host.hostID == memberB.fingerprint }?.network?.member?.pairingId == "new-desktop" })
        #expect(await eventually { runtime.store.hosts.first { $0.id == memberB.fingerprint }?.connection == .connected })
        // Re-pairing can replace a transport without changing its host ID. A
        // subsequent membership refresh must bind and connect that replacement.
        let readsBefore = await ioB.identityReads
        let replacement = try await registry.pair(host: memberB.trustedHost(), pin: "123456", alias: "Phone", persistence: .persistent)
        #expect(!runtime.service.hasRegistration(replacement))
        try await ioA.change(.init(version: 1, joined: true, members: [memberA, repaired], removals: [removal]))
        #expect(await eventually { runtime.service.hasRegistration(replacement) })
        #expect(await eventually { await ioB.identityReads > readsBefore })
        // Also replace the sender from inside its own event callback. Rebinding
        // cancels that callback's task, but must still connect the new transport.
        let receiveNetwork = runtime.service.onNetwork
        let sourceReadsBefore = await ioA.identityReads
        var replaceSource = true
        runtime.service.onNetwork = { hostID, view in
            if hostID == memberA.fingerprint && replaceSource {
                replaceSource = false
                do { try await registry.pair(host: memberA.trustedHost(), pin: "123456", alias: "Phone", persistence: .persistent) }
                catch { Issue.record(error) }
            }
            await receiveNetwork?(hostID, view)
        }
        try await ioA.change(.init(version: 1, joined: true, members: [memberA, repaired], removals: [removal]))
        #expect(await eventually { await ioA.identityReads > sourceReadsBefore })
        await runtime.service.suspend()
        runtime.store.stop()
        await registry.disconnectAll()
    }

    @Test func runtimeConnectsLearnedMembersAndRemovesThemWithoutAnotherPairing() async throws {
        let a = try AnnexClientIdentity.ephemeral()
        let b = try AnnexClientIdentity.ephemeral()
        func member(_ identity: AnnexClientIdentity, self isSelf: Bool) throws -> AnnexNetworkMember {
            .init(fingerprint: try identity.fingerprint, publicKey: identity.pairingIdentity.publicKeyBase64, name: isSelf ? "Studio" : "Travel", icon: "computer", color: "indigo", kind: "desktop", hosts: ["127.0.0.1"], port: 7432,
                  certFingerprint: identity.certificateFingerprint, certPem: "-----BEGIN CERTIFICATE-----\n" + identity.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n",
                  online: isSelf, isSelf: isSelf, joinedAt: "2026-11-08T10:00:00.000Z", pairingId: "desktop")
        }
        let memberA = try member(a, self: true), memberB = try member(b, self: false)
        let initial = AnnexNetworkSnapshot(version: 1, joined: true, members: [memberA, memberB], removals: [])
        let ioA = NetworkRuntimeIO(desktop: a, view: initial)
        let ioB = NetworkRuntimeIO(desktop: b, view: initial)
        let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: MemoryAnnexPairingStore(), pairingIO: { host, _ in host.hostID == memberA.fingerprint ? ioA : ioB })
        let runtime = CompanionRuntime(registry: registry, persistsDrafts: false)
        await runtime.start()
        try await runtime.pair(host: memberA.trustedHost(), pin: "123456", name: "Studio", remember: true)
        #expect(await eventually { runtime.store.hosts.count == 2 && runtime.store.hosts.allSatisfy { $0.connection == .connected } })
        #expect(await ioB.identityReads > 0)
        #expect(await ioB.pairRequests == 0)
        let removed = AnnexNetworkSnapshot(version: 1, joined: true, members: [memberA], removals: [
            .init(fingerprint: memberB.fingerprint, removedAt: "2026-11-08T12:00:00.000Z", pairingId: "desktop", joinedAt: memberB.joinedAt)
        ])
        try await ioA.change(removed)
        #expect(await eventually { runtime.store.hosts.map(\.id) == [memberA.fingerprint] })
        #expect(await registry.transport(for: memberB.fingerprint) == nil)
        // A stale view from A cannot resurrect B on its next reconnect.
        try await ioA.change(initial)
        await runtime.service.reconnect(hostID: memberA.fingerprint)
        #expect(await eventually { runtime.store.hosts.first?.connection == .connected })
        #expect(runtime.store.hosts.map(\.id) == [memberA.fingerprint])
        await runtime.service.suspend()
        runtime.store.stop()
        await registry.disconnectAll()
    }
}
