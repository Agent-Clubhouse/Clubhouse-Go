import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Framebriar
@testable import FramebriarUI

/// Each save can fail before the write, after the write with the file already replaced, or after writing
/// something other than what it was given. Each load can fail too.
private final class FaultQueue: FeedbackStore, @unchecked Sendable {
    enum Fault { case beforeWrite, afterWrite, wrote(@Sendable ([QueuedFeedback]) -> [QueuedFeedback]) }
    private let lock = NSLock()
    private var items: [QueuedFeedback] = []
    private var pending: [Fault] = []
    private var failingLoads = 0
    private(set) var loads = 0
    var disk: [QueuedFeedback] { lock.withLock { items } }
    func fail(_ faults: Fault...) { lock.withLock { pending = faults } }
    func failLoads(_ count: Int) { lock.withLock { failingLoads = count } }
    func load(scope: String) throws -> [QueuedFeedback] {
        try lock.withLock {
            loads += 1
            if failingLoads > 0 { failingLoads -= 1; throw FramebriarError.storage }
            return items
        }
    }
    func save(_ next: [QueuedFeedback], scope: String) throws {
        try lock.withLock {
            guard !pending.isEmpty else { items = next; return }
            switch pending.removeFirst() {
            case .beforeWrite: break
            case .afterWrite: items = next
            case .wrote(let contents): items = contents(next)
            }
            throw FramebriarError.storage
        }
    }
}

/// The real store, with a throw after its write, so the read-back goes through real JSON.
private final class FileThenThrow: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileFeedbackStore
    private var failNext = false
    init(_ file: FileFeedbackStore) { self.file = file }
    func failNextSave() { lock.withLock { failNext = true } }
    func load(scope: String) throws -> [QueuedFeedback] { try file.load(scope: scope) }
    func save(_ items: [QueuedFeedback], scope: String) throws {
        try file.save(items, scope: scope)
        if lock.withLock({ defer { failNext = false }; return failNext }) { throw FramebriarError.storage }
    }
}

/// A service that records each report's media hash and the uploaded bytes, and can be taken offline.
private actor Service: HTTPTransport {
    private let clock: Clock
    var offline = false
    /// A report ID the service already holds with a different hash, as it does after a first delivery.
    var received: [String: String] = [:]
    private(set) var posted: [(id: String, sha: String?)] = []
    private(set) var uploaded: [String: Data] = [:]
    private let end: Date
    init(clock: Clock) { self.clock = clock; end = clock.now() + 30 * 86400 }
    func setOffline(_ value: Bool) { offline = value }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url!.path
        if path.hasSuffix("/access/redeem") || path.hasSuffix("/access/refresh") {
            // A refresh must keep the enrollment's end, whatever the clock has done.
            return json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
                         "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(end)])
        }
        if offline { throw FramebriarError.network }
        if path.hasSuffix("/media") {
            let id = path.split(separator: "/").dropLast().last.map(String.init)!
            uploaded[id] = request.httpBody
            return json(["id": id, "status": "ready", "gameId": "test-app"])
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let id = body["id"] as! String, sha = (body["media"] as? [String: Any])?["sha256"] as? String
        posted.append((id, sha))
        if let held = received[id], held != (sha ?? "") { return json([:], status: 409) }
        received[id] = sha ?? ""
        return json(["id": id, "status": sha == nil ? "ready" : "pending", "gameId": "test-app", "ticket": uploadTicket])
    }
}

@MainActor private final class RetryRig {
    let clock = Clock()
    let store = FaultQueue()
    let enrollment = MemoryEnrollment()
    let service: Service
    let config = try! Configuration(gameID: "test-app", buildSHA: "abcdef0")
    var captures = 0
    init() { service = Service(clock: clock) }
    /// A new client over the same stores is what a relaunch sees.
    func launch() async throws -> (Client, FeedbackModel) {
        let client = try Client(configuration: config, transport: service, enrollmentStore: enrollment, feedbackStore: store, now: clock.now)
        await client.resume()
        let clock = clock
        let model = FeedbackModel(client: client, diagnosticsProvider: { [weak self] in
            self?.captures += 1
            return FeedbackDiagnostics(windowStart: clock.now() - 60, windowEnd: clock.now(), entries: [.init(at: clock.now(), level: .info, ns: "app", event: "opened")])
        }, reportDiagnostics: .on, now: { clock.now() })
        return (client, model)
    }
    func enrolled() async throws -> (Client, FeedbackModel) {
        let (client, model) = try await launch()
        try await client.connect(invitation: invitation)
        await model.update()
        return (client, model)
    }
}

private func picture(_ value: UInt8) -> Data {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: CGFloat(value) / 255, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return ShakeScreenshot.encodePNG(context.makeImage()!)!
}
private let original = picture(10), edited = picture(200), editedAgain = picture(250)
private func id(_ draft: FeedbackDraft) -> String { draft.id.uuidString.lowercased() }

// MARK: failed before anything changed

@MainActor @Test func aSaveThatFailedBeforeWritingTakesTheEditUnderTheSameID() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.beforeWrite)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 0)
    #expect(model.recovery(after: FramebriarError.storage, for: draft).draft.id == draft.id)

    let report = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(report.id == draft.id && report.screenshotPNG == edited)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.map(\.sha) == [digest(edited)])
    #expect(await rig.service.uploaded[id(draft)] == edited)
}

// MARK: file replaced, error thrown afterward, read-back agrees

@MainActor @Test func aSaveThatWroteThenThrewCountsAsSavedAndDeliversThoseBytesOnce() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite)
    let report = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(report.screenshotPNG == original)
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [original])
    #expect(await client.status().queued == 1, "Memory and disk agree, so this process can send it")

    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original)], "Once")
    #expect(await rig.service.uploaded[id(draft)] == original)
    #expect(rig.store.disk.isEmpty)
}

/// The user tapped Send on unredacted bytes, and that save wrote and then threw. Nothing lets them redact
/// over that copy: the composer moved on, and the same ID is a conflict that leaves those bytes alone.
@MainActor @Test func redactingAfterAWriteThatThrewCannotSupersedeTheCommittedBytesWithoutTheConflictPath() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let redacted = try #require(ScreenshotFlattener.flatten(original, marks: [.redaction(CGRect(x: 0, y: 0, width: 16, height: 16))]))
    #expect(redacted != original)
    let draft = model.openDraft()
    await rig.service.setOffline(true)
    rig.store.fail(.afterWrite)
    // `FeedbackView` leaves composing when this returns, which is the only way out of the failure path.
    let committed = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(committed.screenshotPNG == original)

    // Only a custom composer can still try, and it's refused.
    var thrown: (any Error)?
    do { _ = try await model.save(draft, notes: "n", screenshotPNG: redacted, includeDiagnostics: true) } catch { thrown = error }
    #expect(thrown as? FramebriarError == .conflict)
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [original], "Committed bytes stay")

    let recovery = model.recovery(after: thrown!, for: draft)
    #expect(recovery.notice == FeedbackDisclosure.saveConflictNotice && recovery.notice.contains("may also be delivered"))
    #expect(recovery.draft.id != draft.id)
    #expect(await rig.service.posted.isEmpty, "Nothing goes out before the next Send")

    await rig.service.setOffline(false)
    let separate = try await model.save(recovery.draft, notes: "n", screenshotPNG: redacted, includeDiagnostics: true)
    #expect(await model.deliver(separate, includeDiagnostics: true) == .sent)
    try await client.flush()
    #expect(await rig.service.posted.count == 2, "Each once, as the notice said")
    #expect(await rig.service.uploaded[id(draft)] == original)
    #expect(await rig.service.uploaded[id(recovery.draft)] == redacted)
}

@MainActor @Test func aWriteThatThrewAndCountedAsSavedSurvivesARelaunchAsTheBytesTheUserSent() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite)
    _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    let (client, relaunched) = try await rig.launch()
    await #expect(throws: FramebriarError.conflict) { _ = try await relaunched.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original)])
}

@MainActor @Test func aSuccessfulSaveNeverReadsTheStoreBack() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let loads = rig.store.loads
    let report = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(rig.store.loads == loads)
}

// MARK: file replaced, error thrown afterward, read-back failed

@MainActor @Test func aSaveThatWroteThenThrewWithAFailedReadBackThrowsAndTheEditSupersedesTheUnacknowledgedCopy() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [original], "On disk")
    #expect(await client.status().queued == 0, "Not in memory, so this process can't send it")

    // Nothing on the wire yet, and what the user is told allows for the copy.
    let recovery = model.recovery(after: FramebriarError.storage, for: draft)
    #expect(recovery.draft.id == draft.id)
    #expect(recovery.notice.contains("Couldn't confirm") && recovery.notice.contains("still here") && recovery.notice.contains("could send"))
    #expect(!recovery.notice.contains("Not saved"))
    try await client.flush()
    #expect(await rig.service.posted.isEmpty)

    let report = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited], "One report, the one the user last sent")
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.map(\.sha) == [digest(edited)], "The unacknowledged bytes never reach the wire")
    #expect(await rig.service.uploaded[id(draft)] == edited)
}

@MainActor @Test func anyLaterSuccessfulSaveClearsAnUnacknowledgedCopyBecauseMemoryIsAuthoritative() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(model.openDraft(), notes: "abandoned", screenshotPNG: original, includeDiagnostics: true) }
    let other = model.openDraft()
    _ = try await model.save(other, notes: "other", screenshotPNG: nil, includeDiagnostics: true)
    #expect(rig.store.disk.map(\.feedback.id) == [other.id])
}

/// THE DOCUMENTED RESIDUAL. The save wrote and then threw, the read-back failed too, and no later save
/// succeeded before a relaunch. The earlier bytes send, even though the user went on to redact. The
/// `.storageUnavailable` wording warns of exactly this. Nothing in the SDK can see or prevent it.
@MainActor @Test func residualWroteThenThrewAndReadBackFailedAndNoLaterSaveSucceededThenRelaunchSendsTheEarlierBytes() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite, .beforeWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    #expect(FeedbackDisclosure.detail(.needsAttention(.storageUnavailable)).contains("a copy may still be on this device and could send the next time the app opens"))

    let (client, _) = try await rig.launch()
    #expect(await client.status().queued == 1)
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original)])
    #expect(await rig.service.uploaded[id(draft)] == original)
}

// MARK: relaunch between

@MainActor @Test func aSameIDEditAfterRelaunchConflictsAndRecoversAsASeparateReportKeepingTheFrozenCaptures() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    #expect(rig.captures == 1)
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }

    let (client, relaunched) = try await rig.launch()
    await relaunched.update()
    var thrown: (any Error)?
    do { _ = try await relaunched.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) } catch { thrown = error }
    #expect(thrown as? FramebriarError == .conflict)
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [original], "Committed bytes stay")

    let recovery = relaunched.recovery(after: thrown!, for: draft)
    #expect(recovery.notice == FeedbackDisclosure.saveConflictNotice)
    #expect(recovery.notice.contains("may also be delivered") && recovery.notice.contains("still here"))
    #expect(recovery.draft.id != draft.id)
    #expect(recovery.draft.capturedDiagnostics == draft.capturedDiagnostics && recovery.draft.openedAt == draft.openedAt)
    #expect(recovery.draft.enrollmentRef == draft.enrollmentRef)
    #expect(rig.captures == 1, "Diagnostics aren't recaptured")

    #expect(await rig.service.posted.isEmpty, "Nothing goes out before the next Send")
    let report = try await relaunched.save(recovery.draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(await relaunched.deliver(report, includeDiagnostics: true) == .sent)
    try await client.flush()
    let posted = await rig.service.posted
    #expect(Set(posted.map(\.id)) == [id(draft), id(recovery.draft)] && posted.count == 2, "Both go, each once, as the notice said")
    #expect(await rig.service.uploaded[id(draft)] == original)
    #expect(await rig.service.uploaded[id(recovery.draft)] == edited)
    #expect(await client.status().queued == 0)
}

@MainActor @Test func theSameContentAfterRelaunchIsIdempotent() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    let (client, relaunched) = try await rig.launch()
    let report = try await relaunched.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(rig.store.disk.count == 1)
    #expect(await relaunched.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.count == 1)
    #expect(await client.status().queued == 0)
}

@MainActor @Test func anEditAfterTheCopyWasDeliveredIsRefusedByTheServiceAndNeverSaysSent() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    let (first, _) = try await rig.launch()
    try await first.flush()
    #expect(await rig.service.uploaded[id(draft)] == original)

    let (_, relaunched) = try await rig.launch()
    let report = try await relaunched.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(await relaunched.deliver(report, includeDiagnostics: true) == .needsAttention(.rejected))
    #expect(await rig.service.uploaded[id(draft)] == original, "The service keeps the delivered bytes")
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited], "The edit stays on this device")
}

// MARK: a write that landed something else

@MainActor @Test func aWriteThatLandedDifferentBytesIsNotCommittedAndConflictsAfterRelaunch() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let other = try draft.report(configuration: rig.config, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    rig.store.fail(.wrote { _ in [QueuedFeedback(feedback: other, enrollmentRef: draft.enrollmentRef)] })
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    #expect(await client.status().queued == 0, "What's on disk isn't adopted")
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited])

    let (_, relaunched) = try await rig.launch()
    await #expect(throws: FramebriarError.conflict) { _ = try await relaunched.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true) }
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited], "Loaded bytes are committed and stay")
}

@MainActor @Test func aPartialWriteIsNotCommittedAndTheNextSaveRestoresWhatMemoryCommitted() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    await rig.service.setOffline(true)
    let kept = try await model.save(model.openDraft(), notes: "kept", screenshotPNG: original, includeDiagnostics: true)
    let draft = model.openDraft()
    rig.store.fail(.wrote { Array($0.suffix(1)) })
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    #expect(rig.store.disk.map(\.feedback.id) == [draft.id], "The earlier report is missing from this write")
    #expect(await client.status().queued == 1, "Memory still holds what was committed")

    _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(rig.store.disk.map(\.feedback.id) == [kept.id, draft.id])
    #expect(rig.store.disk.first?.feedback.screenshotPNG == original, "Committed bytes intact")
}

@MainActor @Test func theSameReportWithDifferentQueueStateOnDiskIsNotCommitted() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    rig.store.fail(.wrote { items in items.map { item in var changed = item; changed.attempts = 1; return changed } })
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) }
    #expect(await client.status().queued == 0)
}

// MARK: every other caller

@MainActor private func held(_ rig: RetryRig, _ client: Client, _ model: FeedbackModel) async throws -> ReviewedFeedback {
    await rig.service.setOffline(true)
    let report = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)
    await rig.service.setOffline(false)
    try await client.connect(invitation: String(repeating: "j", count: 43))
    #expect(await client.status().heldForEnrollment == 1)
    return report
}

@MainActor @Test func aReleaseThatWroteThenThrewCountsAndTheReportSendsOnce() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    _ = try await held(rig, client, model)
    let token = await client.status().releaseToken
    rig.store.fail(.afterWrite)
    let result = await client.releaseHeldReports(releaseToken: token)
    #expect(result.released == 1 && result.failed == 0 && result.remaining == 0)
    #expect(await client.status().heldForEnrollment == 0)
    #expect(rig.store.disk.first?.heldForEnrollment == false)
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original)])
}

@MainActor @Test func aReleaseThatFailedOrCouldNotBeReadBackStaysHeldInThisProcess() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    _ = try await held(rig, client, model)
    let token = await client.status().releaseToken
    rig.store.fail(.beforeWrite)
    #expect(await client.releaseHeldReports(releaseToken: token).failed == 1)
    #expect(rig.store.disk.first?.heldForEnrollment == true)

    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    #expect(await client.releaseHeldReports(releaseToken: token).failed == 1)
    #expect(await client.status().heldForEnrollment == 1)
    try await client.flush()
    #expect(await rig.service.posted.isEmpty, "This process still holds it")
}

/// The same residual as the save's, for a release: it landed, the read-back failed, and it was reported as failed.
/// The user had chosen to release it, but after a relaunch it sends under the new enrollment despite that report.
@MainActor @Test func residualAReleaseThatLandedAndCouldNotBeReadBackSendsAfterARelaunch() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    _ = try await held(rig, client, model)
    let token = await client.status().releaseToken
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    #expect(await client.releaseHeldReports(releaseToken: token).failed == 1)
    #expect(await client.status().heldForEnrollment == 1, "Still held in this process")
    #expect(rig.store.disk.first?.heldForEnrollment == false, "But rebound on disk")

    let (relaunched, _) = try await rig.launch()
    #expect(await relaunched.status().heldForEnrollment == 0)
    try await relaunched.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original)])
}

@MainActor @Test func aHeldClearThatWroteThenThrewCounts() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    _ = try await held(rig, client, model)
    rig.store.fail(.afterWrite)
    let result = await client.clearHeldReports(clearToken: client.status().clearToken)
    #expect(result.cleared == 1 && result.failed == 0 && result.remaining == 0)
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 0)
}

@MainActor @Test func aHeldClearThatFailedBeforeWritingKeepsTheReport() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    _ = try await held(rig, client, model)
    rig.store.fail(.beforeWrite)
    let token = await client.status().clearToken
    let failed = await client.clearHeldReports(clearToken: token)
    #expect(failed == HeldClearResult(cleared: 0, remaining: 1, failed: 1))
    #expect(rig.store.disk.count == 1)
    #expect(await client.status().queued == 1)
}

@MainActor @Test func aQueueClearFollowsTheDiskAfterAWriteThenThrow() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    await rig.service.setOffline(true)
    _ = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)

    rig.store.fail(.beforeWrite)
    await #expect(throws: FramebriarError.storage) { try await client.clearQueuedFeedback() }
    #expect(await client.status().queued == 1)

    rig.store.fail(.afterWrite)
    try await client.clearQueuedFeedback()
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 0)
}

/// Disk already equals `items` from an earlier landed write, while memory still holds the report. A later
/// failed save reads that back and counts: a relaunch would see the report gone, so memory should too.
@MainActor @Test func aFailedSaveFindingAnEarlierLandedRemovalDropsTheReportFromMemoryToo() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    await rig.service.setOffline(true)
    _ = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    await #expect(throws: FramebriarError.storage) { try await client.clearQueuedFeedback() }
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 1, "Apart, because nothing could be read")

    rig.store.fail(.beforeWrite)
    try await client.clearQueuedFeedback()
    #expect(await client.status().queued == 0)
}

@MainActor @Test func aDeliveryRecordThatWroteThenThrewIsSentAndDoesNotPostAgain() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let report = try await model.save(model.openDraft(), notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    rig.store.fail(.afterWrite)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent, "The service confirmed it, and the record is on disk")
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 0)
    try await client.flush()
    #expect(await rig.service.posted.count == 1)
}

@MainActor @Test func aDeliveryRecordThatRemovesOneReportLeavesTheOtherQueued() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let first = try await model.save(model.openDraft(), notes: "first", screenshotPNG: original, includeDiagnostics: true)
    let second = try await model.save(model.openDraft(), notes: "second", screenshotPNG: edited, includeDiagnostics: true)
    rig.store.fail(.afterWrite)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent)
    #expect(rig.store.disk.map(\.feedback.id) == [second.id])
    #expect(await client.status().queued == 1)
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(original), digest(edited)], "Each once")
}

@MainActor @Test func aDeliveryRecordThatFailedBeforeWritingSaysUnconfirmedAndResendsTheSameBytes() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let report = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    rig.store.fail(.beforeWrite)
    #expect(await model.deliver(report, includeDiagnostics: true) == .needsAttention(.deliveryUnconfirmed))
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited])
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(edited), digest(edited)], "The same bytes both times")
    #expect(await client.status().queued == 0)
}

@MainActor @Test func aDeliveryRecordThatWroteThenCouldNotBeReadBackStillDoesNotSaySent() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let report = try await model.save(model.openDraft(), notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    rig.store.fail(.afterWrite); rig.store.failLoads(1)
    #expect(await model.deliver(report, includeDiagnostics: true) == .needsAttention(.deliveryUnconfirmed))
    #expect(rig.store.disk.isEmpty)
    #expect(await client.status().queued == 1)
    try await client.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(edited), digest(edited)], "The same bytes both times")
    #expect(await client.status().queued == 0)
}

@MainActor @Test func aRetryRecordThatWroteThenThrewKeepsItsBackoffInMemory() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    await rig.service.setOffline(true)
    let report = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)
    rig.store.fail(.afterWrite)
    #expect(await model.deliver(report, includeDiagnostics: true) == .saved(.offline))
    #expect(rig.store.disk.first?.attempts == 1)
    // Each save writes the whole queue from memory, so a stale memory would put this back to zero.
    _ = try await model.save(model.openDraft(), notes: "other", screenshotPNG: nil, includeDiagnostics: true)
    #expect(rig.store.disk.first?.attempts == 1)
}

@MainActor @Test func aFenceThatWroteThenThrewHoldsTheReportAndSendsNothing() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    await rig.service.setOffline(true)
    _ = try await model.save(model.openDraft(), notes: "n", screenshotPNG: original, includeDiagnostics: true)
    await rig.service.setOffline(false)
    rig.store.fail(.afterWrite)
    try await client.connect(invitation: String(repeating: "j", count: 43))
    #expect(rig.store.disk.first?.heldForEnrollment == true)
    #expect(await client.status().heldForEnrollment == 1)
    try await client.flush()
    #expect(await rig.service.posted.isEmpty)
}

// MARK: committed bytes

@MainActor @Test func aCommittedReportCannotBeReplacedByAnEditUnderTheSameID() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    await rig.service.setOffline(true)
    let report = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    await #expect(throws: FramebriarError.conflict) { _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [original])
    #expect(try await client.enqueue(report, enrollmentRef: draft.enrollmentRef) == draft.id, "The same report is idempotent")
    #expect(rig.store.disk.count == 1)
}

// MARK: outcome of a draft saved again after delivery

/// `FeedbackView` can't reach these, since it never returns to composing after a commit. A custom composer can.
@MainActor @Test func aDeliveredDraftSavedAgainWithNewBytesIsRejectedNeverSent() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let first = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent)
    let second = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(await model.deliver(second, includeDiagnostics: true) == .needsAttention(.rejected))
    #expect(await rig.service.uploaded[id(draft)] == original, "The delivered bytes didn't change")
    #expect(rig.store.disk.map(\.feedback.screenshotPNG) == [edited], "The edit stays on this device")
    #expect(rig.store.disk.first?.blocked == true)
}

@MainActor @Test func aDeliveredDraftSavedAgainWithTheSameBytesIsSent() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let first = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent, "Asking again still answers")
    let second = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(second, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.map(\.sha) == [digest(original), digest(original)])
    #expect(await client.status().queued == 0)
}

/// Saved again and not delivered yet, this attempt's result is what's reported, even for the same bytes.
@MainActor @Test func aDeliveredDraftSavedAgainWhileOfflineReportsThisAttempt() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let first = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent)
    await rig.service.setOffline(true)
    let second = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(second, includeDiagnostics: true) == .saved(.offline))
}

@MainActor @Test func aDeliveredDraftSavedAgainThenClearedSaysRemovedNotSent() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    let first = try await model.save(draft, notes: "n", screenshotPNG: original, includeDiagnostics: true)
    #expect(await model.deliver(first, includeDiagnostics: true) == .sent)
    let second = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    try await client.clearQueuedFeedback()
    #expect(await model.deliver(second, includeDiagnostics: true) == .needsAttention(.removed))
}

// MARK: enrollment change

@MainActor @Test func anEnrollmentChangeKeepsTheEditForANewSendUnderANewDraft() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let draft = model.openDraft()
    try await client.connect(invitation: String(repeating: "j", count: 43))
    await #expect(throws: FramebriarError.enrollmentChanged) { _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    #expect(rig.store.disk.isEmpty, "Nothing saved")

    let recovery = model.recovery(after: FramebriarError.enrollmentChanged, for: draft)
    #expect(recovery.notice == FeedbackDisclosure.enrollmentChangedNotice)
    #expect(recovery.draft.id != draft.id && recovery.draft.enrollmentRef != draft.enrollmentRef)
    #expect(await rig.service.posted.isEmpty, "Nothing until a new Send")
    let report = try await model.save(recovery.draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.map(\.sha) == [digest(edited)])
    #expect(await rig.service.uploaded[id(recovery.draft)] == edited)
}

// MARK: delivered bytes

@MainActor @Test func theDeliveredBytesAreTheComposersBytesAcrossOfflineRetryAndRelaunch() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    let flattened = try #require(ScreenshotFlattener.flatten(original, marks: [.redaction(CGRect(x: 2, y: 2, width: 4, height: 4))]))
    let draft = model.openDraft()
    await rig.service.setOffline(true)
    let report = try await model.save(draft, notes: "n", screenshotPNG: flattened, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .saved(.offline))
    rig.clock.advance(600)
    try? await client.flush()
    rig.clock.advance(600)

    await rig.service.setOffline(false)
    let (relaunched, _) = try await rig.launch()
    try await relaunched.flush()
    #expect(await rig.service.posted.map(\.sha) == [digest(flattened)])
    #expect(await rig.service.uploaded[id(draft)] == flattened, "Byte for byte")
    #expect(await relaunched.status().queued == 0)
}

// MARK: the real store

private func storeDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("framebriar-readback-\(UUID().uuidString)") }
private func setMode(_ mode: Int, _ directory: URL) throws { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path) }

@MainActor private func fileClient(_ rig: RetryRig, _ store: any FeedbackStore) async throws -> (Client, FeedbackModel) {
    let client = try Client(configuration: rig.config, transport: rig.service, enrollmentStore: rig.enrollment, feedbackStore: store, now: rig.clock.now)
    await client.resume()
    try await client.connect(invitation: invitation)
    let clock = rig.clock
    let model = FeedbackModel(client: client, diagnosticsProvider: {
        FeedbackDiagnostics(windowStart: clock.now() - 60, windowEnd: clock.now(), entries: [.init(at: clock.now(), level: .info, ns: "app", event: "opened")])
    }, reportDiagnostics: .on, now: { clock.now() })
    await model.update()
    return (client, model)
}

/// Dates with no short decimal form, image, diagnostics and backoff all go through real JSON and still compare equal.
@MainActor @Test func theRealStoresContentsReadBackEqualAcrossJSON() async throws {
    let directory = storeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let rig = RetryRig(); rig.clock.advance(1.0 / 3)
    let store = FileThenThrow(try FileFeedbackStore(directory: directory))
    let (client, model) = try await fileClient(rig, store)
    await rig.service.setOffline(true)
    let first = try await model.save(model.openDraft(), notes: "first", screenshotPNG: original, includeDiagnostics: true)
    store.failNextSave()
    #expect(await model.deliver(first, includeDiagnostics: true) == .saved(.offline), "A retry record with a backoff date")

    rig.clock.advance(1.0 / 7)
    store.failNextSave()
    let second = try await model.save(model.openDraft(), notes: "second", screenshotPNG: edited, includeDiagnostics: true)
    #expect(try store.load(scope: rig.config.storageScope).map(\.feedback) == [first, second])
    #expect(await client.status().queued == 2)
}

/// A read-only directory stops the write before it replaces the file, on this platform. The file stays,
/// the read-back sees the earlier queue, and that isn't `items`.
@MainActor @Test func theRealStoreInAReadOnlyDirectoryFailsBeforeReplacingAndReadsBackAsNotCommitted() async throws {
    let directory = storeDirectory(); defer { try? setMode(0o700, directory); try? FileManager.default.removeItem(at: directory) }
    let rig = RetryRig(); let store = try FileFeedbackStore(directory: directory)
    let (client, model) = try await fileClient(rig, store)
    await rig.service.setOffline(true)
    let kept = try await model.save(model.openDraft(), notes: "kept", screenshotPNG: original, includeDiagnostics: true)

    try setMode(0o500, directory)
    let draft = model.openDraft()
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true) }
    #expect(try store.load(scope: rig.config.storageScope).map(\.feedback) == [kept], "Readable, and unchanged")
    #expect(await client.status().queued == 1)

    try setMode(0o700, directory)
    let report = try await model.save(draft, notes: "n", screenshotPNG: edited, includeDiagnostics: true)
    #expect(try store.load(scope: rig.config.storageScope).map(\.feedback) == [kept, report], "Same ID, once writable")
}

/// A directory that can't be searched looks like no file at all to `fileExists`. If that read as an empty
/// queue, a failed clear would read back as a successful one while the reports stayed on disk.
@MainActor @Test func theRealStoreThrowsWhenItCannotTellWhatIsStoredSoAFailedClearStaysFailed() async throws {
    let directory = storeDirectory(); defer { try? setMode(0o700, directory); try? FileManager.default.removeItem(at: directory) }
    let rig = RetryRig(); let store = try FileFeedbackStore(directory: directory)
    #expect(try store.load(scope: rig.config.storageScope).isEmpty, "No file yet is an empty queue")
    let (client, model) = try await fileClient(rig, store)
    await rig.service.setOffline(true)
    let kept = try await model.save(model.openDraft(), notes: "kept", screenshotPNG: original, includeDiagnostics: true)

    try setMode(0o000, directory)
    #expect(throws: FramebriarError.storage) { _ = try store.load(scope: rig.config.storageScope) }
    await #expect(throws: FramebriarError.storage) { try await client.clearQueuedFeedback() }
    #expect(await client.status().queued == 1)

    try setMode(0o700, directory)
    #expect(try store.load(scope: rig.config.storageScope).map(\.feedback) == [kept])
}

// MARK: reversibility

private func pixel(_ png: Data, _ x: Int, _ y: Int) throws -> [UInt8] {
    let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let (width, height) = (image.width, image.height)
    bytes.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let i = (y * width + x) * 4
    return Array(bytes[i..<i + 3])
}
private let black: [UInt8] = [0, 0, 0], secretRed: [UInt8] = [10, 0, 0]
private let cover = ScreenshotMark.redaction(CGRect(x: 0, y: 0, width: 16, height: 8))

/// What the composer's Done does, from what the editor is opened with.
private func edit(_ attachment: inout ScreenshotAttachment, marks: [ScreenshotMark]) throws {
    attachment.edit(image: try #require(ScreenshotFlattener.flatten(attachment.source, marks: marks)), marks: marks)
}

@MainActor @Test func beforeSendMarksStayEditableOnTheSource() throws {
    var attachment = ScreenshotAttachment(png: original, isCapture: true)
    #expect(attachment.image == original && !attachment.hasEdits, "Unedited, it's the bytes it came with")
    try edit(&attachment, marks: [cover])
    #expect(attachment.source == original && attachment.marks == [cover] && attachment.hasEdits && !attachment.editsAreFinal)
    #expect(try pixel(attachment.image, 4, 4) == black)
}

@MainActor @Test func clearBeforeSendDeliversTheSourceReEncoded() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    try edit(&attachment, marks: [])
    #expect(!attachment.hasEdits)
    let draft = model.openDraft()
    let report = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.uploaded[id(draft)] == ScreenshotFlattener.flatten(original, marks: []))
    #expect(try pixel(try #require(await rig.service.uploaded[id(draft)]), 4, 4) == secretRed, "The original pixels, as the confirmation said")
}

/// The pinned path: redact, Send fails, Clear edits. The redaction is still there, on the delivered bytes.
@MainActor @Test func redactThenAFailedSendThenClearKeepsTheRedactionOnTheDeliveredBytes() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    let flattened = attachment.image, draft = model.openDraft()

    attachment.endReversibility()
    rig.store.fail(.beforeWrite)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true) }
    #expect(attachment.source == flattened && attachment.marks.isEmpty && attachment.editsAreFinal)

    // A new mark can be cleared. What's under the earlier redaction can't.
    try edit(&attachment, marks: [.pen(points: [CGPoint(x: 0, y: 12), CGPoint(x: 16, y: 12)], width: 2, ink: .blue)])
    try edit(&attachment, marks: [])
    #expect(try pixel(attachment.image, 4, 4) == black)
    #expect(attachment.editsAreFinal, "The wording stays the final one")

    let report = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    let delivered = try #require(await rig.service.uploaded[id(draft)])
    #expect(try pixel(delivered, 4, 4) == black, "Covered")
    #expect(try pixel(delivered, 4, 12) == secretRed, "The new mark is gone")
    #expect(delivered != original)
}

@MainActor @Test func anEnrollmentChangeAfterSendAlsoEndsReversibility() async throws {
    let rig = RetryRig(); let (client, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    let draft = model.openDraft()
    try await client.connect(invitation: String(repeating: "j", count: 43))
    attachment.endReversibility()
    await #expect(throws: FramebriarError.enrollmentChanged) { _ = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true) }
    try edit(&attachment, marks: [])
    let next = model.recovery(after: FramebriarError.enrollmentChanged, for: draft).draft
    let report = try await model.save(next, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(try pixel(try #require(await rig.service.uploaded[id(next)]), 4, 4) == black)
}

@MainActor @Test func aSendWithNoEditsLeavesNothingFinal() throws {
    var attachment = ScreenshotAttachment(png: original, isCapture: true)
    attachment.endReversibility()
    #expect(!attachment.editsAreFinal && !attachment.hasEdits, "The wording stays about the capture")
    #expect(attachment.source == original && attachment.image == original)
}

@MainActor @Test func replaceAndRemoveStartOver() throws {
    var attachment: ScreenshotAttachment? = ScreenshotAttachment(png: original)
    try edit(&attachment!, marks: [cover])
    attachment = ScreenshotAttachment(png: edited)
    #expect(attachment?.marks == [] && attachment?.source == edited && attachment?.included == true && attachment?.hasEdits == false)
}

// MARK: include screenshot

@MainActor @Test func anUncheckedScreenshotPutsNoMediaOnTheWireAndTheSummarySaysSo() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    #expect(attachment.included && attachment.bytesToSend == original, "On by default")
    attachment.included = false
    #expect(attachment.bytesToSend == nil)
    let draft = model.openDraft()
    #expect(draft.summary(notes: "n", hasScreenshot: false, includeDiagnostics: false, screenshotLeftOut: true).contains("note · screenshot left out"))
    let report = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true)
    #expect(report.screenshotPNG == nil)
    #expect(await model.deliver(report, includeDiagnostics: true) == .sent)
    #expect(await rig.service.posted.map(\.sha) == [nil], "No media field")
    #expect(await rig.service.uploaded.isEmpty, "No bytes")
    #expect(FeedbackSendBlock.evaluate(status: model.status, notes: "", hasScreenshot: attachment.bytesToSend != nil, preparingImage: false, saving: false) == .empty, "With no note there's nothing to send")
}

@MainActor @Test func recheckingBeforeSendRestoresTheSameEditWithItsMarks() throws {
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    let image = attachment.image
    attachment.included = false
    attachment.included = true
    #expect(attachment.bytesToSend == image && attachment.marks == [cover] && attachment.source == original)
}

/// Send applies the rule to whatever's attached, including an image that wasn't in that Send.
@MainActor @Test func aFailedSendWhileUncheckedLeavesOnlyTheFlattenedImageWhenRechecked() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    let flattened = attachment.image, draft = model.openDraft()
    attachment.included = false
    attachment.endReversibility()
    rig.store.fail(.beforeWrite)
    await #expect(throws: FramebriarError.storage) { _ = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true) }
    #expect(await rig.service.posted.isEmpty)

    attachment.included = true
    #expect(attachment.source == flattened && attachment.marks.isEmpty && attachment.bytesToSend == flattened)
    try edit(&attachment, marks: [])
    #expect(try pixel(attachment.image, 4, 4) == black)
}

// MARK: only flattened bytes leave the composer

@MainActor @Test func theQueueHoldsOnlyFlattenedBytesAcrossRetryAndRelaunch() async throws {
    let rig = RetryRig(); let (_, model) = try await rig.enrolled()
    var attachment = ScreenshotAttachment(png: original)
    try edit(&attachment, marks: [cover])
    let flattened = attachment.image, draft = model.openDraft()
    attachment.endReversibility()
    await rig.service.setOffline(true)
    let report = try await model.save(draft, notes: "n", screenshotPNG: attachment.bytesToSend, includeDiagnostics: true)
    #expect(await model.deliver(report, includeDiagnostics: true) == .saved(.offline))

    let queued = try JSONEncoder().encode(rig.store.disk)
    #expect(queued.range(of: Data(original.base64EncodedString().utf8)) == nil, "The source isn't in the queue")
    #expect(queued.range(of: Data(flattened.base64EncodedString().utf8)) != nil)

    rig.clock.advance(600)
    await rig.service.setOffline(false)
    let (relaunched, _) = try await rig.launch()
    try await relaunched.flush()
    #expect(await rig.service.uploaded[id(draft)] == flattened, "Byte for byte, after a relaunch that lost the source")
    #expect(await rig.service.posted.map(\.sha) == [digest(flattened)])
}

// MARK: wording

@Test func theNotesMatchWhatEachStateAllows() {
    #expect(FeedbackDisclosure.editedImageNote.contains("until you tap Send"))
    #expect(!FeedbackDisclosure.editedImageNote.contains("can't be undone"))
    #expect(FeedbackDisclosure.editedImageFinalNote.contains("can't be undone") && FeedbackDisclosure.editedImageFinalNote.contains("stays covered"))
    #expect(FeedbackDisclosure.clearEditsConfirmation(editsAreFinal: false).contains("including anything you covered"))
    let final = FeedbackDisclosure.clearEditsConfirmation(editsAreFinal: true)
    #expect(final.contains("stays covered") && !final.contains("original"), "Never promises what can't come back")
}

@Test func noDisclosureNamesTheToolkit() {
    let outcomes: [FeedbackDeliveryOutcome] = [.sent, .saved(.offline), .saved(.paused), .saved(.serviceBusy), .saved(.waitingForService)]
        + ([.accessRequired, .rejected, .removed, .deliveryUnconfirmed, .heldForEnrollment, .storageFull, .invalidReport, .notEnrolled, .busy, .storageUnavailable, .enrollmentChanged] as [FeedbackDeliveryOutcome.AttentionReason]).map { .needsAttention($0) }
    var strings = outcomes.flatMap { [FeedbackDisclosure.title($0), FeedbackDisclosure.detail($0)] }
    strings += [FeedbackDisclosure.notesPrompt, FeedbackDisclosure.capturedScreenNote, FeedbackDisclosure.diagnosticsToggle, FeedbackDisclosure.screenshotToggle, FeedbackDisclosure.screenshotLeftOutNote,
                FeedbackDisclosure.imageToolsHint, FeedbackDisclosure.editedImageNote, FeedbackDisclosure.editedImageFinalNote, FeedbackDisclosure.editorMoveHint, FeedbackDisclosure.editorPenHint,
                FeedbackDisclosure.editorRedactHint, FeedbackDisclosure.editorCannotOpen, FeedbackDisclosure.editorCannotFinish, FeedbackDisclosure.saveConflictNotice, FeedbackDisclosure.enrollmentChangedNotice,
                FeedbackDisclosure.alwaysIncluded, FeedbackDisclosure.diagnosticsMeaning, FeedbackDisclosure.telemetryDiagnosticsMeaning, FeedbackDisclosure.sendingTitle, FeedbackDisclosure.sendingDetail,
                FeedbackDisclosure.clearEditsConfirmation(editsAreFinal: true), FeedbackDisclosure.clearEditsConfirmation(editsAreFinal: false),
                FeedbackDisclosure.screenshotUnavailable(.secureField), FeedbackDisclosure.screenshotUnavailable(.failed)]
    strings += [true, false].flatMap { excerptOnly in [true, false].compactMap { FeedbackDisclosure.telemetryNote(enabled: true, excerptOnly: excerptOnly, includeDiagnostics: $0) } }
    strings += [true, false].flatMap { t in [true, false].map { FeedbackDisclosure.enrollment(hasTelemetry: t, sendsDiagnostics: $0) } }
    #expect(strings.allSatisfy { !$0.localizedCaseInsensitiveContains("framebriar") })
}
