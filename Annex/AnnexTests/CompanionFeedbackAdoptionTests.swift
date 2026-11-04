import Foundation
import CryptoKit
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

    // Serialized by the real v0.7.1 bb9b614292e54e4a4d0e9a764f9cbc47b7fc1981 adapter.
    // Synthetic credentials and PNG-signature bytes only; no device Keychain or live service.
    @Test func v071PersistedIdentityBoundAndHeldQueueSurviveUpgrade() async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let enrollmentJSON = #"{"enrolled":true,"enrollmentRef":"v071-current","expiresAt":821692800,"notice":"disconnected","refreshToken":"rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"}"#
        let queueJSON = #"[{"attempts":2,"blocked":false,"enrollmentRef":"v071-current","feedback":{"buildSHA":"abcdef0","capturedAt":815472773.194344,"gameID":"go-adoption-fixture","id":"F2143F44-AEA4-4E21-82A5-047223DAF497","notes":"v071 bound","screenshotPNG":"iVBORw0KGgoB","sessionID":"43b84639-e15a-4551-beaa-7976277b0b55"},"heldForEnrollment":false,"nextAttemptAt":821692800},{"attempts":0,"blocked":true,"enrollmentRef":"v071-previous","feedback":{"buildSHA":"abcdef0","capturedAt":815472773.196141,"gameID":"go-adoption-fixture","id":"68710BEA-CDFE-4D5B-AC92-3823AC3540EC","notes":"v071 held","sessionID":"43b84639-e15a-4551-beaa-7976277b0b55"},"heldForEnrollment":true,"nextAttemptAt":-63114076800}]"#
        let record = try JSONDecoder().decode(EnrollmentRecord.self, from: Data(enrollmentJSON.utf8))
        let original = try JSONDecoder().decode([QueuedFeedback].self, from: Data(queueJSON.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileFeedbackStore(directory: directory)
        let filename = SHA256.hash(data: Data(config.storageScope.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        try Data(queueJSON.utf8).write(to: directory.appendingPathComponent(filename))
        let enrollment = AdoptionEnrollment(record: record)
        let network = AdoptionNetwork()
        let client = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: store,
                                now: { Date(timeIntervalSince1970: 1_793_779_200) })
        let model = FeedbackModel(client: client, reportDiagnostics: .off)
        await model.update()
        #expect(model.status?.queued == 2 && model.status?.heldForEnrollment == 1 && model.status?.blocked == 0)
        #expect(client.enrollmentSignal.enrollmentRef == "v071-current")
        let persisted = try enrollment.load(scope: config.storageScope)
        #expect(persisted.enrollmentRef == record.enrollmentRef && persisted.refreshToken == record.refreshToken)
        let reloaded = try store.load(scope: config.storageScope)
        #expect(try encoder.encode(reloaded) == encoder.encode(original))
        #expect(await network.calls == 0, "Upgrade and inspection make no request")
        let displayed = try #require(model.status?.releaseToken)
        let released = await model.releaseHeldReports(releaseToken: displayed)
        #expect(released.released == 1 && released.remaining == 0 && released.failed == 0)
        #expect(model.status?.queued == 2 && model.status?.heldForEnrollment == 0)
        let after = try store.load(scope: config.storageScope)
        for (old, current) in zip(original, after) {
            #expect(try encoder.encode(old.feedback) == encoder.encode(current.feedback))
            #expect(current.enrollmentRef == record.enrollmentRef)
        }
        #expect(after[0].attempts == 2 && after[0].nextAttemptAt == original[0].nextAttemptAt)
        let stale = await model.releaseHeldReports(releaseToken: displayed)
        #expect(stale.code == "stale-release")
        #expect(await network.calls == 0, "Paused release queues for later, never claims delivery")
    }

    @Test func failedSameEnrollmentSaveKeepsDraftIDAndReviewedBytes() async throws {
        let queue = AdoptionQueue(), (model, network) = try model(queue: queue)
        await enroll(model)
        let draft = model.openDraft()
        let png = Data([137,80,78,71,13,10,26,10,1])
        queue.fail(after: 0)
        await #expect(throws: FramebriarError.storage) {
            try await model.save(draft, notes: "same reviewed report", screenshotPNG: png, includeDiagnostics: false)
        }
        let recovery = model.recovery(after: FramebriarError.storage, for: draft)
        #expect(recovery.draft.id == draft.id && recovery.draft.enrollmentRef == draft.enrollmentRef)
        #expect(await network.reports.isEmpty)
        queue.allowSaves()
        let saved = try await model.save(recovery.draft, notes: "same reviewed report", screenshotPNG: png, includeDiagnostics: false)
        #expect(saved.id == draft.id && saved.screenshotPNG == png && saved.notes == "same reviewed report")
        #expect(try queue.load(scope: config.storageScope).first?.feedback.id == draft.id)
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

    @Test func heldOnlyClearWorksUnenrolledWithDisplayedTokenWithoutAnyRequest() async throws {
        let (model, network) = try model()
        await enroll(model)
        for _ in 0..<2 { _ = try await model.save(model.openDraft(), notes: "held", screenshotPNG: nil, includeDiagnostics: false) }
        await model.disconnect()
        #expect(model.status?.heldForEnrollment == 2 && model.status?.releaseToken == nil)
        let before = await network.calls
        let prompt = try #require(CompanionHeldFeedbackClearPrompt(status: model.status))
        #expect(prompt.count == 2)
        #expect(await prompt.confirm(using: model) == nil)
        #expect(model.message == "2 cleared from this device. They weren't sent.")
        #expect(model.status?.queued == 0)
        let after = await network.calls, reports = await network.reports
        #expect(after == before && reports.isEmpty)
    }

    @Test func clearPromptRetainsDisplayedTokenAndReasksWhenAnotherReportJoinsTheHold() async throws {
        let queue = AdoptionQueue(), (model, network) = try model(queue: queue)
        await enroll(model)
        _ = try await model.save(model.openDraft(), notes: "first held", screenshotPNG: nil, includeDiagnostics: false)
        await enroll(model)
        _ = try await model.save(model.openDraft(), notes: "joins the hold later", screenshotPNG: nil, includeDiagnostics: false)
        let prompt = try #require(CompanionHeldFeedbackClearPrompt(status: model.status))
        #expect(prompt.count == 1 && prompt.title == "Clear 1 report saved under a previous enrollment? They won't be sent.")
        await model.disconnect() // The second saved report joins the hold while the first prompt is open.
        #expect(model.status?.heldForEnrollment == 2)
        #expect(prompt.count == 1 && prompt.token != model.status?.clearToken)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(queue.load(scope: config.storageScope))
        let calls = await network.calls
        let retry = try #require(await prompt.confirm(using: model))
        #expect(try encoder.encode(queue.load(scope: config.storageScope)) == before, "Stale confirmation deletes nothing")
        #expect(model.status?.queued == 2 && model.status?.heldForEnrollment == 2)
        #expect(retry.count == 2 && retry.title == "Clear 2 reports saved under a previous enrollment? They won't be sent.")
        #expect(retry.token == model.status?.clearToken)
        #expect(retry.message == model.message && retry.message == "These reports changed, so nothing was cleared. Check the count and try again.")
        #expect(await retry.confirm(using: model) == nil)
        #expect(model.status?.queued == 0 && model.status?.heldForEnrollment == 0)
        #expect(model.message == "2 cleared from this device. They weren't sent.")
        let after = await network.calls, reports = await network.reports
        #expect(after == calls && reports.isEmpty)
    }

    @Test func missingClearTokenDeletesNothingAndMatchingTokenKeepsCurrentEnrollmentReports() async throws {
        let queue = AdoptionQueue(), (model, network) = try model(queue: queue)
        await enroll(model)
        _ = try await model.save(model.openDraft(), notes: "held", screenshotPNG: nil, includeDiagnostics: false)
        await enroll(model)
        let current = try await model.save(model.openDraft(), notes: "current", screenshotPNG: nil, includeDiagnostics: false)
        let calls = await network.calls
        let missing = await model.clearHeldReports(clearToken: nil)
        #expect(missing.code == "stale-release" && missing.cleared == 0 && missing.remaining == 1)
        #expect(model.status?.queued == 2)
        let prompt = try #require(CompanionHeldFeedbackClearPrompt(status: model.status))
        #expect(await prompt.confirm(using: model) == nil)
        #expect(model.status?.queued == 1 && model.status?.heldForEnrollment == 0)
        #expect(try queue.load(scope: config.storageScope).map(\.feedback.id) == [current.id])
        let after = await network.calls, reports = await network.reports
        #expect(after == calls && reports.isEmpty)
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
    private var record: EnrollmentRecord
    init(record: EnrollmentRecord = EnrollmentRecord()) { self.record = record }
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
nonisolated private final class AdoptionQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedFeedback] = []
    private var remainingSaves: Int?
    func allowSaves() { lock.withLock { remainingSaves = nil } }
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
