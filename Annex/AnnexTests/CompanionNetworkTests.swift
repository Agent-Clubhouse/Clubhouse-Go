import Foundation
import XCTest
import SwiftUI
import Testing
import Vision
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
    private let showsDispatcher: Bool
    private var first = true
    private var closed = false
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    init(showsDispatcher: Bool = false) { self.showsDispatcher = showsDispatcher }
    func receive() async throws -> Data {
        if closed { throw AnnexTransportError.disconnected }
        if first {
            first = false
            if showsDispatcher {
                return Data(#"{"type":"snapshot","lastSeq":0,"payload":{"projects":[],"agents":{},"quickAgents":{},"lastSeq":0,"dispatcher":{"enabled":true,"flagOn":true,"projectId":"__dispatcher__","agent":{"id":"dispatcher","name":"Recovered Navi","kind":"durable","status":"running","projectId":"__dispatcher__","isDispatcher":true}}}}"#.utf8)
            }
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
    let hostID: String
    let showsDispatcher: Bool
    var view: AnnexNetworkSnapshot
    private(set) var identityReads = 0
    private(set) var pairRequests = 0
    private var socket: NetworkRuntimeSocket?
    init(desktop: AnnexClientIdentity, view: AnnexNetworkSnapshot, showsDispatcher: Bool = false) throws {
        self.desktop = desktop
        self.hostID = try desktop.fingerprint
        self.view = view
        self.showsDispatcher = showsDispatcher
    }
    private func localized(_ view: AnnexNetworkSnapshot) -> AnnexNetworkSnapshot {
        let members = view.members.map { member in
            AnnexNetworkMember(fingerprint: member.fingerprint, publicKey: member.publicKey, name: member.name,
                               icon: member.icon, color: member.color, kind: member.kind, hosts: member.hosts,
                               port: member.port, certFingerprint: member.certFingerprint, certPem: member.certPem,
                               online: member.online, isSelf: member.fingerprint == hostID,
                               joinedAt: member.joinedAt, pairingId: member.pairingId)
        }
        return .init(version: view.version, joined: view.joined, members: members, removals: view.removals)
    }
    func change(_ view: AnnexNetworkSnapshot) async throws { self.view = view; try await socket?.push(localized(view)) }
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
            let base = try JSONDecoder().decode(AnnexJSON.self, from: Data(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"idempotency":{"scope":"peer-and-epoch","maxEntries":1,"ttlMs":1},"network":{"version":1,"path":"/api/v1/mobile/network","membersPath":"/api/v1/mobile/network/members","event":"network:changed","pairField":"network"}}"#.utf8))
            if showsDispatcher, case .object(var fields) = base {
                fields["dispatcher"] = .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true),
                    "projectId": .string("__dispatcher__"), "snapshotField": .string("dispatcher")])
                value = .object(fields)
            } else { value = base }
        } else if path.hasSuffix("/network/members") {
            value = .object(["added": .array([]), "skipped": .array([])])
        } else if path.hasSuffix("/network") {
            value = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(localized(view)))
        } else { value = .object(["projects": .array([])]) }
        return .init(status: 200, data: try JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = NetworkRuntimeSocket(showsDispatcher: showsDispatcher); self.socket = socket; return socket
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
        let ioA = try NetworkRuntimeIO(desktop: a, view: initial), ioB = try NetworkRuntimeIO(desktop: b, view: initial)
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
        #expect(await eventually {
            let saved = await pairings.loadAll()
            return saved.count == 2 && saved.allSatisfy { $0.network?.needsIntroduction == false }
        }, "Replacement membership exchanges must complete; malformed acknowledgements leave reconciliation pending")
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
        let ioA = try NetworkRuntimeIO(desktop: a, view: initial)
        let ioB = try NetworkRuntimeIO(desktop: b, view: initial)
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

/// Exercises the actual Runtime pairing completion and mounted AppRoot/Root handoff after a failed restore.
@MainActor final class CompanionDispatcherLaunchRecoveryTests: XCTestCase {
    private func cachedHost(id: String = "cached-studio", name: String = "Cached Navi") -> CompanionHost {
        var agent = CompanionAgent(id: .init(hostID: id, projectID: CompanionDispatcher.defaultProjectID, agentID: "dispatcher"),
                                   name: name, subtitle: "", status: .idle)
        agent.isDispatcher = true
        return CompanionHost(id: id, name: "Studio", endpoint: "", connection: .connected, projects: [],
                             dispatcher: .init(enabled: true, flagOn: true, agent: agent))
    }

    private func seed(_ runtime: CompanionRuntime, host: CompanionHost) throws {
        runtime.preferences.dispatcherDesktops = [try XCTUnwrap(CompanionDispatcherDesktop(host: host))]
        runtime.preferences.lastDispatcherHostID = host.id
        runtime.preferences.lastHostID = host.id
        runtime.preferences.lastTab = .dispatcher
    }

    private func pairingFixture() throws -> (owner: CompanionStateLifetime<CompanionRuntime>, host: TrustedAnnexHost) {
        let identity = try AnnexClientIdentity.ephemeral()
        let member = AnnexNetworkMember(fingerprint: try identity.fingerprint,
            publicKey: identity.pairingIdentity.publicKeyBase64, name: "Recovered desktop", icon: "computer", color: "indigo",
            kind: "desktop", hosts: ["127.0.0.1"], port: 7432, certFingerprint: identity.certificateFingerprint,
            certPem: "-----BEGIN CERTIFICATE-----\n" + identity.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n",
            online: true, isSelf: true, joinedAt: "2026-11-08T10:00:00.000Z", pairingId: "desktop")
        let io = try NetworkRuntimeIO(desktop: identity, view: .init(version: 1, joined: true, members: [], removals: []), showsDispatcher: true)
        let registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: MemoryAnnexPairingStore(),
            pairingIO: { _, _ in io })
        return (CompanionStateLifetime { CompanionRuntime(registry: registry, persistsDrafts: false) }, try member.trustedHost())
    }

    private func mount<Content: View>(_ view: Content, cleanup: @escaping @MainActor () async -> Void) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true; window.rootViewController = nil; original?.makeKey()
            CompanionSceneTestSupport.restoreRegistrations = nil
            let inbox = CompanionDispatcherLaunchInbox.shared
            if let pending = inbox.pending { inbox.consume(pending.id) }
            await cleanup()
        }
        return window
    }

    private func mountRuntime(_ owner: CompanionStateLifetime<CompanionRuntime>) throws -> UIWindow {
        let runtime = owner.value
        return try mount(CompanionAppRoot(runtimeLifetime: owner).environment(\.scenePhase, .active)) {
            runtime.store.shutdown()
            await runtime.lifecycle.settle()
            await runtime.service.shutdown()
            await runtime.registry.disconnectAll()
        }
    }

    private func waitForRendered(_ text: String, in window: UIWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var image: UIImage?
        var recognized = ""
        repeat {
            image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(image?.cgImage)).perform([request])
            recognized = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
            if recognized.contains(text) { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        let attachment = XCTAttachment(image: try XCTUnwrap(image))
        attachment.name = "Actual mounted root — \(text)"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(recognized.contains(text), "Expected visible \(text); OCR: \(recognized)")
    }

    func testSlowRuntimeRestoreKeepsUnknownAuthoritySelectionAndExternalRequestPending() async throws {
        let owner = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
        let runtime = owner.value, cached = cachedHost()
        try seed(runtime, host: cached)
        var restore: CheckedContinuation<[AnnexTransportRegistry.Registration], any Error>?
        CompanionSceneTestSupport.restoreRegistrations = { try await withCheckedThrowingContinuation { restore = $0 } }
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let pending = inbox.pending { inbox.consume(pending.id) }
        inbox.submit(.appIntent)
        let request = try XCTUnwrap(inbox.pending)
        _ = try mountRuntime(owner)
        defer { restore?.resume(returning: []); restore = nil }
        try await waitUntil { restore != nil && runtime.isRestoring && runtime.store.selection == cached.dispatcher?.agent?.id }
        // A bounded observation window includes the initial empty service report and SwiftUI effects.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(runtime.restoredHostIDs)
        XCTAssertEqual(runtime.preferences.lastTab, .dispatcher)
        XCTAssertEqual(runtime.preferences.lastDispatcherHostID, cached.id)
        XCTAssertEqual(runtime.store.selection, cached.dispatcher?.agent?.id)
        XCTAssertEqual(inbox.pending?.id, request.id, "Unknown authority cannot launch or consume a cached external target")
        restore?.resume(returning: []); restore = nil
        try await waitUntil { !runtime.isRestoring }
    }

    func testRuntimeMissingEntitlementKeepsAuthorityUnknownAndNeverLaunchesCachedTarget() async throws {
        let owner = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
        let runtime = owner.value, cached = cachedHost()
        try seed(runtime, host: cached)
        CompanionSceneTestSupport.restoreRegistrations = { throw AnnexTransportError.persistenceFailed(-34018) }
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let pending = inbox.pending { inbox.consume(pending.id) }
        inbox.submit(.appIntent)
        let request = try XCTUnwrap(inbox.pending)
        let window = try mountRuntime(owner)
        try await waitUntil { runtime.restoreError != nil && !runtime.isRestoring && runtime.store.selection == cached.dispatcher?.agent?.id }
        XCTAssertNil(runtime.restoredHostIDs)
        XCTAssertEqual(runtime.launchKeychainDiagnostic?.restoreKind, "persistenceFailed")
        XCTAssertEqual(runtime.launchKeychainDiagnostic?.restoreStatus, -34018)
        XCTAssertEqual(inbox.pending?.id, request.id)
        XCTAssertEqual(runtime.preferences.lastDispatcherHostID, cached.id)
        XCTAssertEqual(runtime.preferences.lastTab, .dispatcher)
        runtime.acknowledgeRestoreError()
        try await waitUntil { inbox.pending == nil }
        XCTAssertNil(runtime.restoredHostIDs)
        XCTAssertTrue(runtime.externalLaunchRestorationFailed)
        try await waitForRendered("No Dispatcher available", in: window)
    }

    func testKnownEmptyRuntimeRestorePrunesCachedDispatcherAndTab() async throws {
        let owner = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
        let runtime = owner.value
        try seed(runtime, host: cachedHost())
        CompanionSceneTestSupport.restoreRegistrations = { [] }
        _ = try mountRuntime(owner)
        try await waitUntil { runtime.restoredHostIDs == [] && runtime.preferences.dispatcherDesktops == [] && runtime.preferences.lastTab == .home }
        XCTAssertFalse(runtime.externalLaunchRestorationFailed)
        XCTAssertNil(runtime.store.selection)
    }

    func testRuntimeSuspendAndReconnectKeepVerifiedPairingAuthority() async throws {
        let fixture = try pairingFixture(), runtime = fixture.owner.value
        CompanionSceneTestSupport.restoreRegistrations = { [] }
        _ = try mountRuntime(fixture.owner)
        try await waitUntil { runtime.restoredHostIDs == [] && !runtime.isRestoring }
        try await runtime.pair(host: fixture.host, pin: "123456", name: "Studio", remember: true)
        try await waitUntil { runtime.store.hosts.first?.dispatcher?.agent != nil && runtime.preferences.dispatcherDesktops?.first?.id == fixture.host.hostID }
        let target = try XCTUnwrap(runtime.store.hosts.first?.dispatcher?.agent?.id)
        runtime.store.selection = target
        try await waitUntil { runtime.preferences.lastTab == .dispatcher }
        let verified = Set([fixture.host.hostID])
        XCTAssertEqual(runtime.restoredHostIDs, verified)
        runtime.lifecycle.update(.background)
        await runtime.lifecycle.settle()
        try await waitUntil { runtime.store.hosts.first?.connection == .offline }
        XCTAssertEqual(runtime.restoredHostIDs, verified, "Suspension does not revoke pairing authority")
        XCTAssertEqual(runtime.store.selection, target)
        XCTAssertEqual(runtime.preferences.lastTab, .dispatcher)
        runtime.lifecycle.update(.active)
        await runtime.lifecycle.settle()
        try await waitUntil { runtime.store.hosts.first?.connection == .connected }
        XCTAssertEqual(runtime.restoredHostIDs, verified, "A reconnect cannot publish an empty pairing set")
        XCTAssertEqual(runtime.store.selection, target)
        XCTAssertEqual(runtime.preferences.lastTab, .dispatcher)
    }

    func testRuntimeForgetPrunesThePreviouslyVerifiedDispatcherThroughAppRoot() async throws {
        let fixture = try pairingFixture(), runtime = fixture.owner.value
        CompanionSceneTestSupport.restoreRegistrations = { [] }
        _ = try mountRuntime(fixture.owner)
        try await waitUntil { runtime.restoredHostIDs == [] && !runtime.isRestoring }
        try await runtime.pair(host: fixture.host, pin: "123456", name: "Studio", remember: true)
        try await waitUntil { runtime.store.hosts.first?.dispatcher?.agent != nil && runtime.preferences.dispatcherDesktops?.first?.id == fixture.host.hostID }
        let host = try XCTUnwrap(runtime.store.hosts.first)
        let target = try XCTUnwrap(host.dispatcher?.agent?.id)
        runtime.store.selection = target
        try await waitUntil { runtime.preferences.lastTab == .dispatcher && runtime.preferences.dispatcherDesktops?.first?.id == host.id }
        XCTAssertEqual(runtime.restoredHostIDs, Set([host.id]))
        try await runtime.forget(hostID: host.id)
        try await waitUntil { runtime.restoredHostIDs == [] && runtime.preferences.dispatcherDesktops == [] && runtime.preferences.lastTab == .home }
        XCTAssertNil(runtime.store.selection)
    }

    func testRootPreservesUnknownAuthorityThenAdmitsKnownTargetAndPrunesKnownEmpty() async throws {
        let store = CompanionStore(service: CompanionLiveService())
        let preferences = CompanionPreferences(defaults: UserDefaults(suiteName: "dispatcher-authority-root-test")!)
        let host = cachedHost(), target = try XCTUnwrap(host.dispatcher?.agent?.id)
        preferences.dispatcherDesktops = [try XCTUnwrap(CompanionDispatcherDesktop(host: host))]
        preferences.lastTab = .dispatcher; preferences.lastDispatcherHostID = host.id
        func root(_ ids: Set<String>?, ready: Bool) -> CompanionRootView {
            CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: {},
                              pairedHostIDs: ids, externalLaunchReady: ready)
        }
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let pending = inbox.pending { inbox.consume(pending.id) }
        inbox.submit(.appIntent)
        let request = try XCTUnwrap(inbox.pending)
        let window = try mount(root(nil, ready: false)) { store.shutdown() }
        let controller = try XCTUnwrap(window.rootViewController as? UIHostingController<CompanionRootView>)
        try await waitUntil { store.selection == target }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(preferences.lastTab, .dispatcher)
        XCTAssertEqual(inbox.pending?.id, request.id)
        controller.rootView = root([host.id], ready: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(inbox.pending?.id, request.id, "Verified pairing alone cannot launch before the current report")
        XCTAssertEqual(preferences.lastTab, .dispatcher)
        store.apply(.hosts([host]))
        try await waitUntil { inbox.pending == nil && store.selection == target }
        try await waitForRendered("Cached Navi", in: window)
        controller.rootView = root([], ready: true)
        try await waitUntil { preferences.dispatcherDesktops == [] && preferences.lastTab == .home }
        XCTAssertNil(store.selection)
    }

    func testAcknowledgedRestoreFailureThenSuccessfulPairOpensTheNewlyVerifiedDispatcher() async throws {
        let fixture = try pairingFixture(), owner = fixture.owner, runtime = owner.value
        // A stale cached desktop must never join the newly established authority set.
        try seed(runtime, host: cachedHost())
        let inbox = CompanionDispatcherLaunchInbox.shared
        if let pending = inbox.pending { inbox.consume(pending.id) }
        CompanionSceneTestSupport.restoreRegistrations = { throw AnnexTransportError.persistenceFailed(-34018) }
        let window = try mountRuntime(owner)
        try await waitUntil { runtime.restoreError != nil && !runtime.isRestoring }
        XCTAssertNil(runtime.restoredHostIDs)
        XCTAssertFalse(runtime.externalLaunchRestorationReady, "The visible alert fences the external request")
        // This is the same action invoked by AppRoot's alert button and dismissal binding.
        runtime.acknowledgeRestoreError()
        XCTAssertTrue(runtime.externalLaunchRestorationReady)
        XCTAssertTrue(runtime.externalLaunchRestorationFailed)
        try await runtime.pair(host: fixture.host, pin: "123456", name: "Recovered desktop", remember: true)
        XCTAssertEqual(runtime.restoredHostIDs, Set([fixture.host.hostID]), "Only the successful current pairing restores authority")
        XCTAssertFalse(runtime.externalLaunchRestorationFailed)
        try await waitUntil { runtime.store.hosts.first(where: { $0.id == fixture.host.hostID })?.dispatcher?.agent != nil }
        let agent = try XCTUnwrap(runtime.store.hosts.first?.dispatcher?.agent)
        // A NEW external invocation must travel through the mounted AppRoot/Root and open this target.
        inbox.submit(.appIntent)
        try await waitUntil { runtime.store.selection == agent.id && inbox.pending == nil }
        XCTAssertEqual(runtime.preferences.lastTab, .dispatcher)
        XCTAssertEqual(runtime.preferences.lastDispatcherHostID, fixture.host.hostID)
        try await waitForRendered("Recovered Navi", in: window)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(condition() ? true : nil, "The actual runtime and mounted root must advance the recovery handoff")
    }
}
