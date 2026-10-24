import Testing
import Foundation
@testable import ClubhouseGo

@MainActor struct FramebriarIntegrationTests {
    @Test func registeredMobileBuildRequiresExplicitEnrollment() async throws {
        let gameID = try #require(Bundle.main.object(forInfoDictionaryKey: "FramebriarGameID") as? String)
        #expect(gameID == "clubhouse-annex")
        let config = try Configuration(gameID: gameID)
        #expect(config.endpoint.absoluteString == "https://framebriar-masra91-poc.azurewebsites.net/api")
        let network = FeedbackMockTransport()
        let client = try Client(configuration: config, transport: network,
                                enrollmentStore: FeedbackMemoryEnrollment(), feedbackStore: FeedbackMemoryQueue())
        let model = FeedbackModel(client: client)
        await model.setActive(true)
        await model.tick()
        #expect(model.status?.canSubmit == false)
        #expect(model.status?.queued == 0)
        #expect(await network.paths.isEmpty)
    }

}

import Framebriar
import FramebriarUI

nonisolated private final class FeedbackMemoryEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord()
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
nonisolated private final class FeedbackMemoryQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [QueuedFeedback] = []
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { reports } }
    func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { reports = items } }
}
private actor FeedbackMockTransport: HTTPTransport {
    private(set) var paths: [String] = []
    func send(_ request: URLRequest) throws -> HTTPResponse {
        let path = request.url!.path
        paths.append(path)
        let object: [String: Any]
        if path.hasSuffix("access/redeem") {
            object = ["v": 1, "scopeVersion": 2, "gameId": "phone-ui-fixture", "token": String(repeating: "b", count: 43),
                      "refreshToken": String(repeating: "r", count: 43), "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(),
                      "refreshExpiresAt": Date().addingTimeInterval(86400).ISO8601Format()]
        } else if path.hasSuffix("/reports") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            object = ["id": body["id"]!, "status": "ready", "gameId": "phone-ui-fixture"]
        } else if path.hasSuffix("access/disconnect") {
            object = ["v": 1, "disconnected": true]
        } else { throw FramebriarError.network }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}
@MainActor extension FramebriarIntegrationTests {
    @Test func feedbackModelReviewsQueuesDeliversAndDisconnectsUsingMocksOnly() async throws {
        let network = FeedbackMockTransport()
        let config = try Configuration(gameID: "phone-ui-fixture")
        let client = try Client(configuration: config, transport: network, enrollmentStore: FeedbackMemoryEnrollment(), feedbackStore: FeedbackMemoryQueue())
        let model = FeedbackModel(client: client)
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        #expect(model.status?.canSubmit == true)
        let reviewed = try ReviewedFeedback(configuration: config, notes: "Explicitly reviewed fixture note", reviewedScreenshotPNG: nil)
        #expect(await model.submit(reviewed))
        #expect(model.status?.queued == 1)
        #expect(await network.paths.count == 1) // Submission itself does not upload.
        await model.tick()
        #expect(model.status?.queued == 0)
        #expect(model.status?.lastReceivedID == reviewed.id)
        await model.disconnect()
        #expect(model.status?.canSubmit == false)
        #expect(await network.paths == ["/api/v1/access/redeem", "/api/v1/reports", "/api/v1/access/disconnect"])
    }
}
