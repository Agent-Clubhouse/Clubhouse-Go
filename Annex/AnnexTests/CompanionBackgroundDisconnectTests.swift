import XCTest
import os
@testable import ClubhouseGo
@testable import ClubhouseTransport

private actor BackgroundDisconnectSocket: AnnexWebSocket {
    private var initial = true
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    func receive() async throws -> Data {
        guard !closed else { throw AnnexTransportError.disconnected }
        if initial {
            initial = false
            return Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) {}
    func ping() {}
    func close() {
        closed = true
        pending?.resume(throwing: AnnexTransportError.disconnected)
        pending = nil
    }
}

private actor BackgroundDisconnectIO: AnnexIO {
    let identity: AnnexPairingIdentity
    private(set) var sockets: [BackgroundDisconnectSocket] = []
    private(set) var openedHosts: [String] = []
    private var holdOpen: Bool
    private var openWaiter: CheckedContinuation<Void, Never>?
    private var commandWaiter: CheckedContinuation<Void, Never>?
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    var opening: Bool { openWaiter != nil }
    var commanding: Bool { commandWaiter != nil }
    var preparing: Bool { preparationWaiter != nil }

    init(holdOpen: Bool = false, identity: AnnexPairingIdentity = AnnexPairingIdentity()) {
        self.holdOpen = holdOpen
        self.identity = identity
    }

    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let value: AnnexJSON
        switch request.url?.lastPathComponent {
        case "identity":
            value = try .object(["publicKey": .string(identity.publicKeyBase64),
                                 "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        case "capabilities":
            value = .object(["version": .integer(1), "epoch": .string("e"), "controlAuth": .string("mtls-pinned-client"),
                             "controlAvailable": .bool(true), "commands": .array([.string("chat.interrupt")]),
                             "idempotency": .object(["scope": .string("client"), "maxEntries": .integer(16), "ttlMs": .integer(60000)])])
        case "commands":
            await withCheckedContinuation { commandWaiter = $0 }
            value = .object(["version": .integer(1), "epoch": .string("e"), "commandId": .string("held-command"),
                             "status": .string("completed"), "result": .null, "error": .null])
        default: value = .array([])
        }
        return try .init(status: 200, data: JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) async -> any AnnexWebSocket {
        let socket = BackgroundDisconnectSocket()
        sockets.append(socket)
        openedHosts.append(request.url?.host ?? "")
        if holdOpen {
            holdOpen = false
            await withCheckedContinuation { openWaiter = $0 }
        }
        return socket
    }
    func releaseOpen() { openWaiter?.resume(); openWaiter = nil }
    func releaseCommand() { commandWaiter?.resume(); commandWaiter = nil }
    func holdPreparation() async { await withCheckedContinuation { preparationWaiter = $0 } }
    func releasePreparation() { preparationWaiter?.resume(); preparationWaiter = nil }
    func releaseAll() { releaseOpen(); releaseCommand(); releasePreparation() }
}

@MainActor final class CompanionBackgroundDisconnectTests: XCTestCase {
    private struct Harness {
        let runtime: CompanionRuntime
        let transport: AnnexTransport
        let registration: AnnexTransportRegistry.Registration
        let telemetry: AnnexTelemetry
        let clock: ClubhouseTransport.AnnexManualClock
    }

    private func start(_ io: BackgroundDisconnectIO) async throws -> Harness {
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let telemetry = AnnexTelemetry()
        telemetry.setEnabled(true)
        let clock = ClubhouseTransport.AnnexManualClock()
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: telemetry, clock: clock.clock)
        let runtime = CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false)
        let registration = AnnexTransportRegistry.Registration(host: host, alias: "Fixture", transport: transport)
        runtime.store.start()
        addTeardownBlock { @MainActor in
            await io.releaseAll()
            runtime.service.prepareResume = nil
            await runtime.lifecycle.settle()
            await runtime.service.shutdown()
            runtime.store.stop()
        }
        await runtime.service.register(registration)
        return .init(runtime: runtime, transport: transport, registration: registration, telemetry: telemetry, clock: clock)
    }

    private func eventually(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        return false
    }

    private func connected(_ harness: Harness) async throws {
        let ready = try await eventually { harness.runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(ready)
    }

    private func assertDisconnected(_ harness: Harness, socket: BackgroundDisconnectSocket) async throws {
        let disconnected = try await eventually {
            let closed = await socket.closed
            return closed && harness.runtime.store.hosts.first?.connection == .offline
        }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(harness.telemetry.snapshot().records.contains { $0.events.contains("disconnectCompleted") })
        XCTAssertEqual(harness.runtime.store.hosts.first?.connection, .offline)
    }

    func testBackgroundDuringConnectClosesTheLateSocket() async throws {
        let io = BackgroundDisconnectIO(holdOpen: true)
        let harness = try await start(io)
        let opening = try await eventually { await io.opening }
        XCTAssertTrue(opening)
        harness.runtime.lifecycle.update(.background)
        await harness.runtime.lifecycle.settle()
        XCTAssertTrue(harness.telemetry.snapshot().records.contains { $0.events.contains("disconnectCompleted") })
        await io.releaseOpen()
        let sockets = await io.sockets
        let socket = try XCTUnwrap(sockets.first)
        try await assertDisconnected(harness, socket: socket)
        harness.clock.advance(by: .seconds(60))
        let count = await io.sockets.count
        XCTAssertEqual(count, 1)
    }

    func testBackgroundDuringReconnectBackoffCancelsTheRetry() async throws {
        let io = BackgroundDisconnectIO()
        let harness = try await start(io)
        try await connected(harness)
        let sockets = await io.sockets
        let socket = try XCTUnwrap(sockets.first)
        await socket.close()
        let backingOff = try await eventually {
            harness.telemetry.snapshot().records.contains { $0.operation == .backoff } && harness.clock.sleeperCount == 1
        }
        XCTAssertTrue(backingOff)
        harness.runtime.lifecycle.update(.background)
        await harness.runtime.lifecycle.settle()
        try await assertDisconnected(harness, socket: socket)
        let cancelled = try await eventually { harness.clock.sleeperCount == 0 }
        XCTAssertTrue(cancelled)
        harness.clock.advance(by: .seconds(60))
        let count = await io.sockets.count
        XCTAssertEqual(count, 1)
    }

    func testBackgroundDoesNotWaitForAnInflightCommand() async throws {
        let io = BackgroundDisconnectIO()
        let harness = try await start(io)
        try await connected(harness)
        let command = Task {
            try await harness.transport.execute(.init(commandID: "held-command", epoch: "e", kind: .interrupt(agentID: "a", sessionID: "s")))
        }
        let commanding = try await eventually { await io.commanding }
        XCTAssertTrue(commanding)
        harness.runtime.lifecycle.update(.background)
        await harness.runtime.lifecycle.settle()
        let sockets = await io.sockets
        let socket = try XCTUnwrap(sockets.first)
        try await assertDisconnected(harness, socket: socket)
        let stillPending = await io.commanding
        XCTAssertTrue(stillPending, "Suspension must not wait for an unrelated HTTP receipt")
        await io.releaseCommand()
        let receipt = try await command.value
        XCTAssertEqual(receipt.status, .completed, "A valid dispatched receipt still wins the disconnect race")
    }

    func testRapidPhaseChangesFinishSuspendedAndCanResume() async throws {
        let io = BackgroundDisconnectIO()
        let harness = try await start(io)
        try await connected(harness)
        for phase in [CompanionLifecycle.Phase.background, .inactive, .active, .background, .inactive, .active, .background] {
            harness.runtime.lifecycle.update(phase)
        }
        await harness.runtime.lifecycle.settle()
        for socket in await io.sockets { try await assertDisconnected(harness, socket: socket) }
        let cancelled = try await eventually { harness.clock.sleeperCount == 0 }
        XCTAssertTrue(cancelled)
        let before = await io.sockets.count
        harness.clock.advance(by: .seconds(60))
        harness.runtime.lifecycle.update(.active)
        await harness.runtime.lifecycle.settle()
        try await connected(harness)
        let after = await io.sockets.count
        XCTAssertEqual(after, before + 1)
        harness.runtime.lifecycle.update(.background)
        await harness.runtime.lifecycle.settle()
        for socket in await io.sockets { try await assertDisconnected(harness, socket: socket) }
    }

    func testBackgroundDisconnectsWhileForegroundPreparationIsHeld() async throws {
        let io = BackgroundDisconnectIO()
        let harness = try await start(io)
        try await connected(harness)
        harness.runtime.lifecycle.update(.background)
        await harness.runtime.lifecycle.settle()
        harness.runtime.service.prepareResume = {
            // Route selection can register one answering desktop before probing the next.
            await harness.runtime.service.register(harness.registration)
            await io.holdPreparation()
            return [harness.registration.host.hostID]
        }
        harness.runtime.lifecycle.update(.active)
        let preparing = try await eventually { await io.preparing }
        XCTAssertTrue(preparing)
        try await connected(harness)
        let sockets = await io.sockets
        let socket = try XCTUnwrap(sockets.last)
        harness.runtime.lifecycle.update(.background)
        let closedPromptly = try await eventually(timeout: .milliseconds(500)) { await socket.closed }
        XCTAssertTrue(closedPromptly, "Background disconnect must not queue behind foreground network preparation")
        await io.releasePreparation()
        await harness.runtime.lifecycle.settle()
        try await assertDisconnected(harness, socket: socket)
    }

    func testForegroundReconcilesRouteCommittedByCancelledRelocation() async throws {
        let io = BackgroundDisconnectIO()
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let oldEndpoint = try AnnexEndpoint(host: "127.0.0.1", port: 8443)
        let newEndpoint = try AnnexEndpoint(host: "127.0.0.2", port: 8443)
        let host = try TrustedAnnexHost(endpoint: oldEndpoint, verifiedHostID: hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        let credential = try AnnexCredential(bearerToken: "fixture-only")
        await credentials.save(credential, for: hostID)
        let identity = try AnnexClientIdentity.ephemeral()
        let pairings = MemoryAnnexPairingStore()
        await pairings.save(AnnexSavedPairing(host: host, alias: "Fixture", identity: identity, credential: credential))
        let registry = AnnexTransportRegistry(credentials: credentials, pairings: pairings, pairingIO: { _, _ in io })
        let old = try await registry.restore(host: host, alias: "Fixture", clientIdentity: identity)
        let runtime = CompanionRuntime(registry: registry, persistsDrafts: false)
        runtime.store.start()
        var heldResume: Task<Void, Never>?
        addTeardownBlock { @MainActor in
            heldResume?.cancel()
            await io.releaseAll()
            await heldResume?.value
            runtime.service.prepareResume = nil
            await runtime.service.shutdown()
            runtime.store.stop()
        }
        await runtime.service.register(old)
        let initiallyConnected = try await eventually { runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(initiallyConnected)
        await runtime.service.suspend()
        runtime.service.prepareResume = {
            await runtime.switchToAnsweringRoutes(resolveRoute: { registration in
                let relocated = try! await registry.relocate(hostID: hostID, to: newEndpoint)
                await io.holdPreparation() // The real registry has persisted/replaced the route already.
                return relocated
            })
        }
        let pendingResume = Task { await runtime.service.resume() }
        heldResume = pendingResume
        let heldAfterCommit = try await eventually { await io.preparing }
        XCTAssertTrue(heldAfterCommit)
        let saved = await pairings.loadAll()
        XCTAssertEqual(saved.first?.host.endpoint, newEndpoint, "The regression must hold AFTER relocation persists")
        let registrations = await registry.all()
        let authoritative = try XCTUnwrap(registrations.first)
        XCTAssertNotEqual(authoritative.transportID, old.transportID)
        XCTAssertTrue(runtime.service.hasRegistration(old), "The old service transport must still be installed at the cancellation boundary")
        pendingResume.cancel()
        await runtime.service.suspend()
        await io.releasePreparation()
        await pendingResume.value
        runtime.service.prepareResume = {
            // No route change is needed now: the registry already holds the answering new route.
            await runtime.switchToAnsweringRoutes(resolveRoute: { $0 })
        }
        await runtime.service.resume()
        let reconnected = try await eventually { runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(reconnected)
        XCTAssertTrue(runtime.service.hasRegistration(authoritative), "Fresh foreground must install the already-committed route")
        XCTAssertFalse(runtime.service.hasRegistration(old), "The stale transport must be replaced")
        let opened = await io.openedHosts
        XCTAssertEqual(opened, [oldEndpoint.host, newEndpoint.host], "Fresh foreground must connect the new route exactly once")
        for socket in await io.sockets.dropLast() {
            let closed = await socket.closed
            XCTAssertTrue(closed)
        }
        await runtime.service.suspend()
        await runtime.service.resume()
        let correctRouteConnected = try await eventually { runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(correctRouteConnected)
        let laterOpens = await io.openedHosts
        XCTAssertEqual(laterOpens, [oldEndpoint.host, newEndpoint.host, newEndpoint.host], "An already-current registration gets one reconnect, without a second register/connect")
    }

    func testHeldRouteResolutionCannotReplaceNewerAuthoritativeTransport() async throws {
        let oldIO = BackgroundDisconnectIO()
        let newIO = BackgroundDisconnectIO(identity: oldIO.identity)
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: oldIO.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let identity = try AnnexClientIdentity.ephemeral()
        let nextIO = OSAllocatedUnfairLock(initialState: 0)
        let registry = AnnexTransportRegistry(credentials: credentials, pairings: nil, pairingIO: { _, _ in
            nextIO.withLock { count in
                defer { count += 1 }
                return count == 0 ? oldIO : newIO
            }
        })
        let old = try await registry.restore(host: host, alias: "Old", clientIdentity: identity)
        let runtime = CompanionRuntime(registry: registry, persistsDrafts: false)
        runtime.store.start()
        var heldResume: Task<Void, Never>?
        addTeardownBlock { @MainActor in
            heldResume?.cancel()
            await oldIO.releaseAll()
            await newIO.releaseAll()
            await heldResume?.value
            runtime.service.prepareResume = nil
            await runtime.service.shutdown()
            runtime.store.stop()
        }
        await runtime.service.register(old)
        let oldConnected = try await eventually { runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(oldConnected)
        await runtime.service.suspend()
        runtime.service.prepareResume = {
            await runtime.switchToAnsweringRoutes(resolveRoute: { registration in
                await oldIO.holdPreparation()
                return registration
            })
        }
        let pendingResume = Task { await runtime.service.resume() }
        heldResume = pendingResume
        let resolving = try await eventually { await oldIO.preparing }
        XCTAssertTrue(resolving)
        let newer = try await registry.restore(host: host, alias: "New", clientIdentity: identity)
        XCTAssertEqual(newer.host.endpoint, old.host.endpoint, "This must cover unchanged endpoints with a newer registration identity")
        XCTAssertNotEqual(newer.transportID, old.transportID)
        await runtime.service.register(newer)
        let newConnected = try await eventually { runtime.store.hosts.first?.connection == .connected }
        XCTAssertTrue(newConnected)
        XCTAssertTrue(runtime.service.hasRegistration(newer))
        XCTAssertFalse(pendingResume.isCancelled, "Cancellation must not be what rejects the stale resolver result")
        await oldIO.releasePreparation()
        await pendingResume.value
        XCTAssertTrue(runtime.service.hasRegistration(newer), "A held resolution must not replace the newer authoritative transport")
        XCTAssertFalse(runtime.service.hasRegistration(old))
        let oldOpens = await oldIO.sockets.count
        XCTAssertEqual(oldOpens, 1, "The stale transport must never reconnect after the newer pairing wins")
        for socket in await oldIO.sockets {
            let closed = await socket.closed
            XCTAssertTrue(closed)
        }
    }
}
