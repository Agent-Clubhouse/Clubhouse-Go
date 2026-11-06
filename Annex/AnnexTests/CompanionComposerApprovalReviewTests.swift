import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

/// No network or native accessibility navigation: exercise the actual sheet projection/button methods
/// while its presentation binding stays open and synthetic events replace the selected request.
@MainActor final class CompanionComposerApprovalReviewTests: XCTestCase {
    func testOpenReviewTracksQueueResolutionAndRemovalWithoutDispatch() async throws {
        let first = request("first"), second = request("second"), earlier = request("earlier")
        let fixture = ReviewFixture([first, second], selected: second.id)
        let sheet = fixture.sheet
        let oldOption = try XCTUnwrap(second.options.first)
        let queuedAction = { await sheet.respond(to: second.id, option: oldOption) }
        XCTAssertEqual(sheet.queuePosition(at: .now), "2 of 2")
        fixture.publish([earlier, first, second])
        XCTAssertEqual(sheet.queuePosition(at: .now), "3 of 3")
        XCTAssertEqual(sheet.currentApproval?.id, second.id)
        var resolvedEarlier = earlier, resolvedFirst = first
        resolvedEarlier.resolution = .allowed; resolvedFirst.resolution = .denied
        fixture.publish([resolvedEarlier, resolvedFirst, second])
        XCTAssertNil(sheet.queuePosition(at: .now), "The remaining request no longer claims a multi-request position")
        var resolvedSecond = second
        resolvedSecond.resolution = .allowed
        fixture.publish([resolvedEarlier, resolvedFirst, resolvedSecond])
        XCTAssertEqual(sheet.currentApproval?.resolution, .allowed)
        await queuedAction()
        fixture.publish([resolvedEarlier, resolvedFirst])
        XCTAssertNil(sheet.currentApproval, "Removal must not fall back to a captured pending value")
        XCTAssertNotNil(fixture.selection, "Removal does not silently choose another request or close review")
        await queuedAction()
        sheet.close()
        XCTAssertNil(fixture.selection)
        XCTAssertTrue(fixture.service.commands.isEmpty)
        XCTAssertEqual(fixture.store.drafts[fixture.target], "Keep every line\n🙂")
    }

    func testOldCallbackCannotRemapChangedOptionsOrFollowNewSelection() async throws {
        let first = request("first"), second = request("second")
        let fixture = ReviewFixture([first, second], selected: first.id)
        let sheet = fixture.sheet
        let originalOption = try XCTUnwrap(first.options.first)
        let queuedAction = { await sheet.respond(to: first.id, option: originalOption) }
        var changed = first
        changed.title = "Updated request"
        changed.options[0].label = "Changed option wording"
        fixture.publish([changed, second])
        XCTAssertEqual(sheet.currentApproval?.title, changed.title)
        await queuedAction()
        XCTAssertTrue(fixture.service.commands.isEmpty, "An option with the same ID but changed value is not the original option")
        sheet.close()
        await queuedAction()
        fixture.selection = .init(target: fixture.target, approvalID: second.id)
        await queuedAction()
        fixture.selection = .init(target: CompanionPreviewService.dispatcherTarget, approvalID: first.id)
        XCTAssertNil(sheet.currentApproval, "A same-ID request on another target is not this review")
        await queuedAction()
        XCTAssertTrue(fixture.service.commands.isEmpty, "Closed or switched review must reject its old callback")
    }

    func testOneValidDecisionDisablesPendingDuplicatesAndCloseAddsNoCommand() async throws {
        let approval = request("valid")
        let fixture = ReviewFixture([approval], selected: approval.id)
        let sheet = fixture.sheet
        let option = try XCTUnwrap(approval.options.first)
        let arrived = expectation(description: "One synthetic response reached the service")
        fixture.service.holdsResponse = true
        fixture.service.responseArrived = { arrived.fulfill() }
        let sending = Task { await sheet.respond(to: approval.id, option: option) }
        await fulfillment(of: [arrived], timeout: 1)
        XCTAssertFalse(sheet.canRespond)
        XCTAssertEqual(sheet.currentApproval?.resolution, .submitting)
        await sheet.respond(to: approval.id, option: option)
        XCTAssertEqual(fixture.service.commands, ["respond"])
        XCTAssertEqual(fixture.service.responses.first?.target, fixture.target)
        XCTAssertEqual(fixture.service.responses.first?.approvalID, approval.id)
        XCTAssertEqual(fixture.service.responses.first?.optionID, option.id)
        sheet.close()
        XCTAssertEqual(fixture.service.commands, ["respond"], "Close does not dispatch or cancel an already submitted decision")
        fixture.service.finishResponse()
        await sending.value
        XCTAssertEqual(fixture.service.commands, ["respond"])
    }

    func testExistingOfflineExpiryAndErrorRulesRemainAuthoritative() async throws {
        let approval = request("gates")
        let fixture = ReviewFixture([approval], selected: approval.id)
        let sheet = fixture.sheet
        let option = try XCTUnwrap(approval.options.first)
        var hosts = fixture.store.hosts
        hosts[0].connection = .offline
        fixture.store.apply(.hosts(hosts))
        XCTAssertFalse(sheet.canRespond)
        await sheet.respond(to: approval.id, option: option)
        hosts[0].connection = .connected
        fixture.store.apply(.hosts(hosts))
        var expired = approval
        expired.deadline = .distantPast
        fixture.publish([expired])
        await sheet.respond(to: approval.id, option: option)
        XCTAssertTrue(fixture.service.commands.isEmpty)
        fixture.publish([approval])
        fixture.service.refusesResponse = true
        await sheet.respond(to: approval.id, option: option)
        XCTAssertEqual(fixture.service.commands, ["respond"])
        XCTAssertEqual(sheet.currentApproval?.resolution, .pending, "A definite refusal restores the actual request")
        let error = try XCTUnwrap(fixture.store.operationErrors[fixture.target])
        sheet.close()
        XCTAssertEqual(fixture.store.operationErrors[fixture.target], error, "Closing review does not erase the error")
    }

    private func request(_ id: String) -> CompanionApproval {
        .init(id: id, toolName: "Synthetic tool", summary: "Synthetic approval", title: "Review \(id)",
              deadline: .now.addingTimeInterval(300), options: [.init(id: "allow-\(id)", label: "Allow once", kind: .allowOnce)])
    }
}

@MainActor private final class ReviewFixture {
    nonisolated deinit {}
    let service = ReviewServiceSpy()
    let store: CompanionStore
    let target = CompanionPreviewService.target
    var selection: CompanionComposerApprovalReviewSelection?
    private var sequence = 0

    init(_ approvals: [CompanionApproval], selected: String) {
        store = CompanionStore(service: service)
        store.apply(.hosts(CompanionPreviewService.hosts(now: .now)))
        store.drafts[target] = "Keep every line\n🙂"
        selection = .init(target: target, approvalID: selected)
        publish(approvals)
    }

    var sheet: CompanionComposerApprovalReviewSheet {
        .init(store: store, target: target, selection: Binding(get: { self.selection }, set: { self.selection = $0 }))
    }

    func publish(_ approvals: [CompanionApproval]) {
        sequence += 1
        store.apply(.timeline(target, items: approvals.map(CompanionTimelineItem.approval), sequence: sequence, reset: true, sessionID: "synthetic-review"))
    }
}

@MainActor private final class ReviewServiceSpy: CompanionService {
    nonisolated deinit {}
    struct Response { let approvalID: String; let optionID: String; let target: CompanionTarget }
    var commands: [String] = []
    var responses: [Response] = []
    var holdsResponse = false
    var refusesResponse = false
    var responseArrived: (() -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?

    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: [], lastSequence: 0) }
    func reconnect(hostID: String) async {}
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        commands.append("send"); throw CompanionServiceError.unavailable("Synthetic service")
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { commands.append("cancel") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        commands.append("spawn"); throw CompanionServiceError.unavailable("Synthetic service")
    }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        commands.append("respond")
        responses.append(.init(approvalID: approvalID, optionID: optionID, target: target))
        if holdsResponse {
            await withCheckedContinuation { continuation in waiting = continuation; responseArrived?() }
        } else { responseArrived?() }
        if refusesResponse { throw CompanionServiceError.rejected("Synthetic refusal") }
    }
    func finishResponse() { waiting?.resume(); waiting = nil }
}
