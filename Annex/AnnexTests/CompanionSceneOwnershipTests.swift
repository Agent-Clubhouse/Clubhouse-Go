import XCTest
import SwiftUI
import Framebriar
import FramebriarUI
@testable import ClubhouseTransport
@testable import ClubhouseGo

/// All reports, enrollment, defaults and desktop traffic are synthetic and local to this test.
@MainActor final class CompanionSceneOwnershipTests: XCTestCase {
    func testBuiltManifestRequiresOneScene() throws {
        let manifest = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        XCTAssertFalse(UIApplication.shared.supportsMultipleScenes)
    }

    func testSceneActivationOwnership() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") else {
            throw XCTSkip("Requires isolated scene test launch argument")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try Configuration(gameID: "scene-fixture")
        let fileStore = try FileFeedbackStore(directory: directory)
        try fileStore.save([
            QueuedFeedback(feedback: ReviewedFeedback(configuration: config, notes: "Queued scene fixture"), nextAttemptAt: Date(timeIntervalSince1970: 4_000_000_000), enrollmentRef: "scene-enrollment"),
            QueuedFeedback(feedback: ReviewedFeedback(configuration: config, notes: "Held scene fixture"), blocked: true, enrollmentRef: "previous-enrollment", heldForEnrollment: true)
        ], scope: config.storageScope)
        let queueFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let originalQueue = try Data(contentsOf: queueFile)
        let enrollment = SceneEnrollment()
        let network = SceneHTTP()
        let source = AnnexTelemetry()
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
        XCTAssertFalse(multiple)
        try await Task.sleep(for: .seconds(3))
        for task in registrations { await task.value }
        let counts = await transports.asyncCounts()
        let clients = Set(runtimes.compactMap { $0.feedback.map { ObjectIdentifier($0.client) } }).count
        print("SCENE_AFTER supportsMultiple=\(multiple) runtimes=\(runtimes.count) clients=\(clients) bridges=\(runtimes.compactMap(\.appTelemetry).count) transports=\(transports.count) hostConnectCounts=\(counts) sessions=\(UIApplication.shared.openSessions.count) connectedScenes=\(UIApplication.shared.connectedScenes.count) activationError=\(activationError.map { String(describing: $0) } ?? "none")")
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene }.count, 1)
        XCTAssertEqual(clients, runtimes.count)
        XCTAssertEqual(transports.count, runtimes.count)
        XCTAssertEqual(counts, [1])
        XCTAssertNotNil(activationError)
        XCTAssertEqual((activationError as NSError?)?.domain, "UISceneErrorDomain")
        XCTAssertEqual(try Data(contentsOf: queueFile), originalQueue)
        let client = try XCTUnwrap(runtimes.first?.feedback?.client)
        let status = await client.status()
        XCTAssertEqual(status.queued, 2); XCTAssertEqual(status.heldForEnrollment, 1)
        XCTAssertTrue(client.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertEqual(client.enrollmentSignal.enrollmentRef, try enrollment.load(scope: config.storageScope).enrollmentRef)
    }

    func testOneClientKeepsQueueAndEnrollmentCoherentAcrossCallers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Configuration(gameID: "scene-fixture")
        let store = try FileFeedbackStore(directory: directory)
        let enrollment = SceneEnrollment(), network = SceneHTTP()
        let a = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: store)
        let b = a
        let first = try ReviewedFeedback(configuration: config, notes: "Synthetic A")
        let second = try ReviewedFeedback(configuration: config, notes: "Synthetic B")
        try await a.enqueue(first, enrollmentRef: "scene-enrollment")
        try await b.enqueue(second, enrollmentRef: "scene-enrollment")
        XCTAssertEqual(try store.load(scope: config.storageScope).map(\.feedback.id), [first.id, second.id])
        let aStatus = await a.status(), bStatus = await b.status()
        XCTAssertEqual(aStatus.queued, 2); XCTAssertEqual(bStatus.queued, 2)
        await a.resume()
        try await a.flush(); try await b.flush()
        let ids = await network.reportIDs
        XCTAssertEqual(ids, [first.id.uuidString.lowercased(), second.id.uuidString.lowercased()])
        XCTAssertTrue(try store.load(scope: config.storageScope).isEmpty)
        _ = try await a.disconnect()
        XCTAssertFalse(a.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertFalse(b.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertFalse(try enrollment.load(scope: config.storageScope).enrolled)
    }

    func testUpgradePersistence() async throws {
        let phase = ProcessInfo.processInfo.environment["CLUBHOUSE_SCENE_UPGRADE_PHASE"] ?? "roundtrip"
        let suite = "scene-upgrade-" + UUID().uuidString
        let defaults = phase == "roundtrip" ? try XCTUnwrap(UserDefaults(suiteName: suite)) : .standard
        let root = phase == "roundtrip" ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            : try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        defer {
            if phase == "roundtrip" { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        }
        let directory = root.appendingPathComponent("Framebriar")
        let expected = root.appendingPathComponent("scene-upgrade-expected.json")
        let config = try Configuration(gameID: "scene-fixture")
        let store = try FileFeedbackStore(directory: directory)
        let target = CompanionTarget(hostID: "fixture-host", projectID: "fixture-project", agentID: "fixture-agent")
        let text = "Saved before upgrade: café 👩🏽‍💻 日本語\nsecond line 🏠"
        let drafts = CompanionLocalDrafts(defaults: defaults)
        if phase != "verify" {
            let first = try ReviewedFeedback(configuration: config, notes: "Synthetic queued before upgrade")
            let held = try ReviewedFeedback(configuration: config, notes: "Synthetic held before upgrade")
            try store.save([
                QueuedFeedback(feedback: first, attempts: 3, nextAttemptAt: Date(timeIntervalSince1970: 4_000_000_000), enrollmentRef: "scene-enrollment"),
                QueuedFeedback(feedback: held, attempts: 2, blocked: true, enrollmentRef: "previous-enrollment", heldForEnrollment: true)
            ], scope: config.storageScope)
            drafts.save([target: text])
            defaults.set(true, forKey: CompanionInstallReset.markerKey)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            try Data(contentsOf: file).write(to: expected)
            print("UPGRADE_SEEDED reports=2 held=1 drafts=1 sessions=\(UIApplication.shared.openSessions.count)")
        }
        if phase != "seed" {
            var deletedServices: [String] = []
            XCTAssertFalse(CompanionInstallReset.clearLeftoversIfFreshInstall(defaults: defaults, domain: phase == "roundtrip" ? suite : Bundle.main.bundleIdentifier, delete: { deletedServices.append($0) }))
            XCTAssertTrue(deletedServices.isEmpty)
            let client = try Client(configuration: config, transport: SceneHTTP(), enrollmentStore: SceneEnrollment(), feedbackStore: store)
            let status = await client.status()
            XCTAssertEqual(status.queued, 2); XCTAssertEqual(status.heldForEnrollment, 1)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: expected))
            let restored = CompanionStore(service: CompanionPreviewService(), draftPersistence: drafts)
            XCTAssertEqual(restored.drafts[target], text)
            let items = try store.load(scope: config.storageScope)
            XCTAssertEqual(items.map(\.enrollmentRef), ["scene-enrollment", "previous-enrollment"])
            XCTAssertEqual(items.map(\.attempts), [3, 2])
            print("UPGRADE_VERIFIED byteIdentical=true reports=2 held=1 ids=\(items.map { $0.feedback.id.uuidString }) unicodeDraft=true sessions=\(UIApplication.shared.openSessions.count) connected=\(UIApplication.shared.connectedScenes.count)")
        }
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
