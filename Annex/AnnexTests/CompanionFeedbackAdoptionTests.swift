import Foundation
import Testing
import Framebriar
import FramebriarUI
@testable import ClubhouseGo

/// Tagged identity API, real SDK stores/pump/model, and a transport that never opens a socket.
@MainActor @Suite(.serialized) struct CompanionFeedbackAdoptionTests {
    private let config = try! Configuration(gameID: "go-adoption-fixture", buildSHA: "abcdef0")

    private func fixture(_ group: String, _ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: FeedbackFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "held-reports-v1", withExtension: "json"))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return try #require((root[group] as? [String: Any])?[name] as? [String: Any])
    }
    private func model(queue: AdoptionQueue = AdoptionQueue()) throws -> (FeedbackModel, AdoptionNetwork) {
        let network = AdoptionNetwork()
        return (FeedbackModel(client: try Client(configuration: config, transport: network,
            enrollmentStore: AdoptionEnrollment(), feedbackStore: queue)), network)
    }
    private func enroll(_ model: FeedbackModel) async {
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        #expect(model.status?.canSubmit == true, "Fake enrollment must succeed before exercising identity")
    }

    @Test func changedEnrollmentRequiresNewDraftAndAnotherExplicitSave() async throws {
        let (model, network) = try model()
        await enroll(model)
        let old = model.openDraft(), note = "Only this reviewed note carries over"
        let png = Data([137,80,78,71,13,10,26,10,1])
        await enroll(model)
        await #expect(throws: FramebriarError.enrollmentChanged) {
            try await model.save(old, notes: note, screenshotPNG: png, includeDiagnostics: false)
        }
        #expect(model.status?.queued == 0)
        #expect(await network.reports.isEmpty)
        let reopened = model.openDraft()
        #expect(reopened.id != old.id && reopened.enrollmentRef != old.enrollmentRef)
        #expect(model.status?.queued == 0, "Opening the replacement never saves or sends")
        let saved = try await model.save(reopened, notes: note, screenshotPNG: png, includeDiagnostics: false)
        #expect(saved.id == reopened.id && saved.notes == note && saved.screenshotPNG == png)
        #expect(saved.incident == nil)
        #expect(await network.reports.isEmpty, "Save only commits locally; a new Send is intentional")
        #expect(FeedbackDisclosure.enrollmentChangedNotice.contains("then tap Send"))
    }

    @Test func displayedReleaseTokenBecomesStaleInsteadOfSendingWithChangedEnrollment() async throws {
        let (model, network) = try model()
        await enroll(model)
        for _ in 0..<2 { _ = try await model.save(model.openDraft(), notes: "held", screenshotPNG: nil, includeDiagnostics: false) }
        await enroll(model)
        let displayed = try #require(model.status?.releaseToken)
        #expect(model.status?.heldForEnrollment == 2 && model.status?.blocked == 0)
        await enroll(model)
        let result = await model.releaseHeldReports(releaseToken: displayed)
        let expected = try fixture("release", "staleAfterEnrollmentChange")
        #expect(result.released == expected["released"] as? Int)
        #expect(result.remaining == expected["remaining"] as? Int)
        #expect(result.code == expected["code"] as? String)
        #expect(await network.reports.isEmpty)
        #expect(model.status?.heldForEnrollment == 2)
    }

    @Test func partialReleaseReportsCountsAndQueuesWithoutClaimingDelivery() async throws {
        let queue = AdoptionQueue(), (model, network) = try model(queue: queue)
        await enroll(model)
        for _ in 0..<2 { _ = try await model.save(model.openDraft(), notes: "held", screenshotPNG: nil, includeDiagnostics: false) }
        await enroll(model)
        let displayed = try #require(model.status?.releaseToken)
        queue.fail(after: 1)
        let result = await model.releaseHeldReports(releaseToken: displayed)
        let expected = try fixture("release", "partial")
        #expect(result.released == expected["released"] as? Int)
        #expect(result.failed == expected["failed"] as? Int)
        #expect(result.remaining == expected["remaining"] as? Int)
        #expect(model.message == FeedbackDisclosure.releaseResult(result))
        #expect(model.message?.contains("1 couldn't be moved") == true)
        #expect(model.status?.heldForEnrollment == 1 && model.status?.queued == 2)
        #expect(model.status?.releaseToken != displayed)
        #expect(model.status?.lastReceivedID == nil)
        #expect(await network.reports.count == 1, "Only the released report may attempt; fake network is offline")
    }

    @Test func heldOnlyClearWorksUnenrolledWithoutATokenOrAnyRequest() async throws {
        let (model, network) = try model()
        await enroll(model)
        for _ in 0..<2 { _ = try await model.save(model.openDraft(), notes: "held", screenshotPNG: nil, includeDiagnostics: false) }
        await model.disconnect()
        #expect(model.status?.heldForEnrollment == 2 && model.status?.releaseToken == nil)
        let before = await network.calls
        let result = await model.clearHeldReports(), expected = try fixture("clear", "whileUnenrolled")
        #expect(result.cleared == expected["cleared"] as? Int)
        #expect(result.remaining == expected["remaining"] as? Int)
        #expect(model.status?.queued == 0)
        let after = await network.calls, reports = await network.reports
        #expect(after == before && reports.isEmpty)
    }

    @Test func immediateDeliveryAndGoQueueWakeDoNotDuplicateTheReport() async throws {
        let (model, network) = try model()
        await enroll(model)
        await network.allowReports()
        let report = try await model.save(model.openDraft(), notes: "explicit send", screenshotPNG: nil, includeDiagnostics: false)
        let wake = Task { await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false) }
        let outcome = await model.deliver(report, includeDiagnostics: false)
        await wake.value
        #expect(outcome == .sent)
        #expect(await network.reports.count == 1)
        #expect(model.status?.queued == 0 && model.status?.lastReceivedID == report.id)
    }

    @Test func savedWhileBackgroundedWaitsForResumeAndSendsOnce() async throws {
        let (model, network) = try model()
        await enroll(model)
        await network.allowReports()
        await model.setActive(false)
        let report = try await model.save(model.openDraft(), notes: "save before resume", screenshotPNG: nil, includeDiagnostics: false)
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: true)
        #expect(await network.reports.isEmpty)
        await model.setActive(true)
        await model.tick()
        await model.tick()
        #expect(await network.reports.count == 1)
        #expect(model.status?.lastReceivedID == report.id)
    }

    @Test func everyAttentionReasonUsesAnAttentionOutcomeRatherThanSent() {
        let reasons: [FeedbackDeliveryOutcome.AttentionReason] = [.accessRequired, .heldForEnrollment, .enrollmentChanged,
            .rejected, .removed, .deliveryUnconfirmed, .storageFull, .storageUnavailable, .invalidReport, .notEnrolled, .busy]
        for reason in reasons {
            #expect(FeedbackDisclosure.title(.needsAttention(reason)) == "Needs attention")
            #expect(!FeedbackDisclosure.detail(.needsAttention(reason)).isEmpty)
        }
    }
}

nonisolated private final class FeedbackFixtureBundle {}
nonisolated private final class AdoptionEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord()
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
nonisolated private final class AdoptionQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedFeedback] = []
    private var remainingSaves: Int?
    func fail(after count: Int) { lock.withLock { remainingSaves = count } }
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    func save(_ items: [QueuedFeedback], scope: String) throws {
        try lock.withLock {
            if let remainingSaves {
                guard remainingSaves > 0 else { throw FramebriarError.storage }
                self.remainingSaves = remainingSaves - 1
            }
            self.items = items
        }
    }
}
private actor AdoptionNetwork: HTTPTransport {
    private(set) var reports: [Data] = []
    private(set) var calls = 0
    private var offline = true
    func allowReports() { offline = false }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        calls += 1
        if request.url!.path.hasSuffix("/reports") {
            reports.append(request.httpBody!)
            if offline { throw FramebriarError.network }
            let sent = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject:
                ["id": sent["id"]!, "status": "ready", "gameId": "go-adoption-fixture"]))
        }
        let body: [String: Any] = request.url!.path.hasSuffix("/disconnect") ? ["v": 1, "disconnected": true] :
            ["v": 1, "scopeVersion": 2, "gameId": "go-adoption-fixture", "feedbackCorrelationVersion": 1,
             "token": String(repeating: "t", count: 43), "refreshToken": String(repeating: "r", count: 43),
             "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(), "refreshExpiresAt": Date().addingTimeInterval(86400).ISO8601Format()]
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: body))
    }
}
