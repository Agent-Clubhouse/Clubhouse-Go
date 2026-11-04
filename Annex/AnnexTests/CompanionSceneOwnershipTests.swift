import XCTest
import SwiftUI
import Framebriar
import FramebriarUI
@testable import ClubhouseTransport
@testable import ClubhouseGo

/// All reports, enrollment, defaults and desktop traffic are synthetic and local to this test.
@MainActor final class CompanionSceneOwnershipTests: XCTestCase {
    func testSceneActivationOwnership() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") else {
            throw XCTSkip("Requires isolated scene test launch argument")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let enrollment = SceneEnrollment()
        let network = SceneHTTP()
        let source = AnnexTelemetry()
        let config = try Configuration(gameID: "scene-fixture")
        var runtimes: [CompanionRuntime] = []
        var transports: [SceneTransport] = []
        var registrations: [Task<Void, Never>] = []
        CompanionSceneTestSupport.makeFeedback = {
            let client = try! Client(configuration: config, transport: network, enrollmentStore: enrollment,
                                     feedbackStore: FileFeedbackStore(directory: directory))
            return CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        }
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "scene.invalid", port: 443), verifiedHostID: Array(repeating: "ab", count: 16).joined(separator: ":"),
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        CompanionSceneTestSupport.didCreateRuntime = { runtime in
            runtimes.append(runtime)
            let transport = SceneTransport(); transports.append(transport)
            registrations.append(Task { await runtime.service.register(.init(host: host, alias: "Synthetic desktop", transport: transport)) })
        }
        defer {
            for runtime in runtimes { runtime.appTelemetry?.stop(); runtime.service.remove(hostID: host.hostID) }
            CompanionSceneTestSupport.makeFeedback = nil
            CompanionSceneTestSupport.didCreateRuntime = nil
            try? FileManager.default.removeItem(at: directory)
        }
        CompanionSceneTestSupport.ready = true
        try await wait { runtimes.count == 1 }
        for task in registrations { await task.value }
        print("SCENE_BEFORE runtimes=\(runtimes.count) clients=\(Set(runtimes.compactMap { $0.feedback.map { ObjectIdentifier($0.client) } }).count) bridges=\(runtimes.compactMap(\.appTelemetry).count) sessions=\(UIApplication.shared.openSessions.count)")
        var activationError: Error?
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) { activationError = $0 }
        let multiple = UIApplication.shared.supportsMultipleScenes
        if multiple { try await wait { runtimes.count == 2 } }
        else { try await Task.sleep(for: .seconds(3)) }
        for task in registrations { await task.value }
        let counts = await transports.asyncCounts()
        let clients = Set(runtimes.compactMap { $0.feedback.map { ObjectIdentifier($0.client) } }).count
        print("SCENE_AFTER supportsMultiple=\(multiple) runtimes=\(runtimes.count) clients=\(clients) bridges=\(runtimes.compactMap(\.appTelemetry).count) transports=\(transports.count) hostConnectCounts=\(counts) sessions=\(UIApplication.shared.openSessions.count) connectedScenes=\(UIApplication.shared.connectedScenes.count) activationError=\(activationError.map { String(describing: $0) } ?? "none")")
        XCTAssertEqual(runtimes.count, multiple ? 2 : 1)
        XCTAssertEqual(clients, runtimes.count)
        XCTAssertEqual(transports.count, runtimes.count)
        XCTAssertEqual(counts, Array(repeating: 1, count: runtimes.count))
    }

    func testTwoClientsOverwriteAndDuplicateSyntheticQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Configuration(gameID: "scene-fixture")
        let store = try FileFeedbackStore(directory: directory)
        let enrollment = SceneEnrollment(), network = SceneHTTP()
        let make = { try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: store) }
        let a = try make(), b = try make()
        let first = try ReviewedFeedback(configuration: config, notes: "Synthetic A")
        let second = try ReviewedFeedback(configuration: config, notes: "Synthetic B")
        try await a.enqueue(first, enrollmentRef: "scene-enrollment")
        XCTAssertEqual(try store.load(scope: config.storageScope).map(\.feedback.id), [first.id])
        try await b.enqueue(second, enrollmentRef: "scene-enrollment")
        XCTAssertEqual(try store.load(scope: config.storageScope).map(\.feedback.id), [second.id])
        print("QUEUE_OVERWRITE accepted=2 persisted=1 lost=1 clientA=\(await a.status().queued) clientB=\(await b.status().queued)")
        // Both now cache B, and both deliver it, even though the first delivery removes it on disk.
        let c = try make()
        await b.resume(); await c.resume()
        try await b.flush(); try await c.flush()
        let ids = await network.reportIDs
        XCTAssertEqual(ids, [second.id.uuidString.lowercased(), second.id.uuidString.lowercased()])
        print("QUEUE_DUPLICATE distinctReports=1 reportRequests=\(ids.count) persisted=\(try store.load(scope: config.storageScope).count)")
        // The actor's cached enrollment also does not track another client's disconnect.
        _ = try await b.disconnect()
        XCTAssertFalse(b.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertTrue(c.enrollmentSignal.isEnrolled(at: Date()))
        print("ENROLLMENT_AFTER_DISCONNECT clientB=\(b.enrollmentSignal.isEnrolled(at: Date())) clientC=\(c.enrollmentSignal.isEnrolled(at: Date())) persisted=\(try enrollment.load(scope: config.storageScope).enrolled)")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Scene fixture did not reach expected state")
    }
}

nonisolated private final class SceneEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord(refreshToken: String(repeating: "r", count: 43), expiresAt: SceneFixtureValues.expiry, enrolled: true, notice: .connected, enrollmentRef: "scene-enrollment")
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
private actor SceneHTTP: HTTPTransport {
    private(set) var reportIDs: [String] = []
    func send(_ request: URLRequest) throws -> HTTPResponse {
        let path = request.url!.path
        let object: [String: Any]
        if path.hasSuffix("/reports") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            reportIDs.append(body["id"] as! String)
            object = ["id": body["id"]!, "status": "ready", "gameId": "scene-fixture"]
        } else if path.hasSuffix("access/refresh") {
            object = ["v": 1, "scopeVersion": 2, "gameId": "scene-fixture", "token": String(repeating: "b", count: 43), "refreshToken": String(repeating: "r", count: 43), "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(), "refreshExpiresAt": SceneFixtureValues.expiry.ISO8601Format()]
        } else if path.hasSuffix("access/disconnect") { object = ["v": 1, "disconnected": true] }
        else if path.contains("/otlp/") { object = [:] }
        else { throw FramebriarError.network }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}
private actor SceneTransport: AnnexTransporting {
    private(set) var connectCount = 0
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { _ in } }
    func connect() { connectCount += 1 }
    func disconnect() {}
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON { throw AnnexTransportError.disconnected }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
}
private extension Array where Element == SceneTransport {
    func asyncCounts() async -> [Int] {
        var counts: [Int] = []
        for transport in self { counts.append(await transport.connectCount) }
        return counts
    }
}

nonisolated private enum SceneFixtureValues { static let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86400) }
