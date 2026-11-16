import XCTest
import SwiftUI
import UIKit
import Vision
import ClubhouseTransport
@testable import ClubhouseGo

/// No network or native accessibility navigation: exercise the actual sheet projection/button methods
/// while its presentation binding stays open and synthetic events replace the selected request.
@MainActor final class CompanionComposerApprovalReviewTests: XCTestCase {
    func testNativeMenuActivationRevalidatesSelectionReplacementAndExpiry() {
        let first = request("first"), second = request("second")
        let fixture = ReviewFixture([first, second], selected: first.id)
        defer { fixture.tearDown() }
        let captured = fixture.store.decisionPresentation(.approval(first), target: fixture.target)
        // Model a callback retained when the native menu opened; selection and Store are read at invocation.
        var selectedID: String?
        let activateOpenedMenu = { CompanionConversationPendingDecisions.currentSelection(captured, in: fixture.store, selectedID: selectedID) }
        XCTAssertEqual(activateOpenedMenu(), .approval(first))
        selectedID = "approval:second"
        XCTAssertNil(activateOpenedMenu(),
                     "An open menu cannot act on the previous selection")
        selectedID = "approval:first"
        var replacement = first
        replacement.summary = "A different same-ID request"
        fixture.publish([replacement, second])
        XCTAssertNil(activateOpenedMenu(), "The already-open callback cannot remap a same-ID replacement")
        var expired = first
        expired.deadline = .distantPast
        fixture.publish([expired, second])
        let expiredPresentation = fixture.store.decisionPresentation(.approval(expired), target: fixture.target)
        XCTAssertNil(CompanionConversationPendingDecisions.currentSelection(expiredPresentation, in: fixture.store, selectedID: "approval:first"),
                     "Expiry is checked at activation even if the native item was previously presented")
        XCTAssertTrue(fixture.service.commands.isEmpty)
    }

    func testMountedTitleAndQueueLabelsUpdateWhenTheirRealInputsChange() async throws {
        let first = request("first"), second = request("second")
        let fixture = ReviewFixture([first], selected: first.id)
        defer { fixture.tearDown() }
        let (window, _, originalKey) = try mountTray(fixture)
        defer { window.isHidden = true; window.rootViewController = nil; originalKey?.makeKey() }
        try await requireRenderedLabel("Review first", in: window)
        var changed = first
        changed.title = "Updated menu title"
        fixture.publish([changed, second])
        try await requireRenderedLabel("Updated menu title", in: window)
        try await requireRenderedLabel("1 of 2 waiting", in: window)
        XCTAssertFalse(try renderedText(window).contains("Review first"))
        XCTAssertTrue(fixture.service.commands.isEmpty)
    }

    func testPinnedTrayRetiresAtItsDeadlineWithoutStoreTrafficOrPeriodicMenuRebuilds() async throws {
        var approval = request("one-shot")
        approval.deadline = .now.addingTimeInterval(5)
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
        let openedPresentation = fixture.store.decisionPresentation(.approval(approval), target: fixture.target)
        let activateOpenedMenu = { CompanionConversationPendingDecisions.currentSelection(openedPresentation, in: fixture.store, selectedID: nil) }
        XCTAssertEqual(activateOpenedMenu(), .approval(approval))
        let (window, controller, originalKey) = try mountTray(fixture)
        defer { window.isHidden = true; window.rootViewController = nil; originalKey?.makeKey() }
        try await requireRenderedLabel("Review one-shot", in: window)
        controller.view.layoutIfNeeded()
        let size = CGSize(width: 402, height: 1000)
        XCTAssertGreaterThan(controller.sizeThatFits(in: size).height, 0)
        let originalItems = fixture.store.conversation(for: fixture.target).items
        let retired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.sizeThatFits(in: size).height == 0
        }, object: nil)
        await fulfillment(of: [retired], timeout: 8)
        XCTAssertEqual(controller.sizeThatFits(in: size).height, 0)
        XCTAssertFalse(try renderedText(window).contains("Review one-shot"), "The expired tray is absent from the mounted screen")
        XCTAssertNil(activateOpenedMenu(), "The callback captured before expiry rechecks the deadline at activation")
        XCTAssertEqual(fixture.store.conversation(for: fixture.target).items, originalItems, "No event or source mutation retires the tray")
        XCTAssertTrue(fixture.service.commands.isEmpty)
    }

    #if DEBUG
    func testMountedReviewStaysOnTheSameControllerWhenTheLastApprovalBecomesUncertain() async throws {
        let approval = request("last")
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
        let selection = CompanionComposerApprovalReviewSelection(target: fixture.target, approvalID: approval.id,
            presentation: fixture.store.decisionPresentation(.approval(approval), target: fixture.target))
        let (window, controller, originalKey) = try mountTray(fixture, initialReview: selection)
        defer { window.isHidden = true; window.rootViewController = nil; originalKey?.makeKey() }
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.presentedViewController?.viewIfLoaded?.window === window
        }, object: nil)
        await fulfillment(of: [appeared], timeout: 5)
        let presented = try XCTUnwrap(controller.presentedViewController)
        try await requireRenderedLabel("Review last", in: window)
        var uncertain = approval
        uncertain.resolution = .uncertain
        fixture.publish([uncertain])
        XCTAssertTrue(CompanionPendingDecision.pending(in: fixture.store.conversation(for: fixture.target).items).isEmpty)
        try await requireRenderedLabel("Decision delivery unknown", in: window)
        XCTAssertTrue(controller.presentedViewController === presented, "The same full Review survives the final pending row disappearing")
        XCTAssertTrue(presented.view.window === window)
        XCTAssertEqual(controller.sizeThatFits(in: CGSize(width: 402, height: 1000)).height, 0,
                       "The empty tray occupies zero height while its Review remains presented")
        XCTAssertTrue(fixture.service.commands.isEmpty)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presented.dismiss(animated: false) { continuation.resume() }
        }
        XCTAssertNil(controller.presentedViewController)
        XCTAssertTrue(fixture.service.commands.isEmpty, "Closing Review sends no decision")
    }
    #endif

    func testOpenReviewTracksQueueResolutionAndRemovalWithoutDispatch() async throws {
        let first = request("first"), second = request("second"), earlier = request("earlier")
        let fixture = ReviewFixture([first, second], selected: second.id)
        defer { fixture.tearDown() }
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
        defer { fixture.tearDown() }
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
        let secondTarget = CompanionPreviewService.dispatcherTarget
        fixture.publish([first], for: secondTarget)
        fixture.selection = .init(target: secondTarget, approvalID: first.id)
        XCTAssertNil(sheet.currentApproval, "A same-ID request on another target is not this review")
        await queuedAction()
        XCTAssertTrue(fixture.service.commands.isEmpty, "Closed or switched review must reject its old callback")
        let secondSheet = fixture.sheet(for: secondTarget)
        XCTAssertEqual(secondSheet.currentApproval, first, "The second target really contains the same request ID")
        XCTAssertTrue(secondSheet.canRespond)
        await secondSheet.respond(to: first.id, option: originalOption)
        XCTAssertEqual(fixture.service.commands, ["respond"], "The legitimately selected second request can dispatch")
        XCTAssertEqual(fixture.service.responses.first?.target, secondTarget)
        XCTAssertEqual(fixture.service.responses.first?.approvalID, first.id)
        XCTAssertEqual(secondSheet.currentApproval?.resolution, .allowed)
    }

    func testOneValidDecisionDisablesPendingDuplicatesAndCloseAddsNoCommand() async throws {
        let approval = request("valid")
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
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
        // Clean up before awaiting the task even if an assertion/arrival wait failed. Teardown also
        // disables future holds, so a task that starts late cannot install a new suspended response.
        fixture.tearDown()
        await sending.value
        XCTAssertEqual(fixture.service.commands, ["respond"])
        XCTAssertFalse(fixture.service.hasHeldResponse)
        XCTAssertNil(fixture.service.responseArrived)
    }

    func testExistingOfflineExpiryAndErrorRulesRemainAuthoritative() async throws {
        let approval = request("gates")
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
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

    /// The review sheet answers through the same store.canApprove gate as the transcript (#345).
    func testIncompleteRequestAllowWaitsForFullReviewButDenyStaysAvailable() async throws {
        var approval = request("incomplete")
        approval.summary = "Incomplete input: synthetic truncated payload"
        approval.options.append(.init(id: "deny-incomplete", label: "Deny", kind: .rejectOnce))
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
        let sheet = fixture.sheet
        XCTAssertTrue(sheet.canRespond)
        XCTAssertFalse(fixture.store.canApprove(approval, target: fixture.target))
        await sheet.respond(to: approval.id, option: approval.options[0])
        XCTAssertTrue(fixture.service.commands.isEmpty, "Allow on an incomplete request needs its full review first")
        await sheet.respond(to: approval.id, option: approval.options[1])
        XCTAssertEqual(fixture.service.commands, ["respond"], "Deny stays available")
        XCTAssertEqual(fixture.service.responses.first?.optionID, "deny-incomplete")
    }

    func testPinnedReviewUsesOneSubmittingStateAndDismissalDoesNotCancelOrResubmit() async throws {
        let first = request("first"), second = request("second")
        let fixture = ReviewFixture([first, second], selected: first.id)
        defer { fixture.tearDown() }
        let presentation = fixture.store.decisionPresentation(.approval(first), target: fixture.target)
        fixture.selection = .init(target: fixture.target, approvalID: first.id, presentation: presentation)
        let sheet = fixture.sheet
        let option = try XCTUnwrap(first.options.first)
        let arrived = expectation(description: "Pinned response arrived")
        fixture.service.holdsResponse = true
        fixture.service.responseArrived = { arrived.fulfill() }
        let sending = Task { await sheet.respond(presentation, option: option) }
        await fulfillment(of: [arrived], timeout: 1)
        let queue = CompanionPendingDecision.pending(in: fixture.store.conversation(for: fixture.target).items)
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(queue[0].isSubmitting)
        XCTAssertEqual(sheet.currentApproval?.resolution, .submitting)
        await fixture.store.respond(presentation, option: option)
        await sheet.respond(presentation, option: option)
        sheet.close()
        await sheet.respond(presentation, option: option)
        XCTAssertEqual(fixture.service.commands, ["respond"])
        fixture.tearDown()
        await sending.value
        XCTAssertEqual(CompanionPendingDecision.pending(in: fixture.store.conversation(for: fixture.target).items).map(\.id), ["approval:second"])
    }

    func testPinnedReviewEpochReplacementAndReconnectRetryUseActualStoreGuards() async throws {
        let approval = request("epoch")
        let fixture = ReviewFixture([approval], selected: approval.id)
        defer { fixture.tearDown() }
        var hosts = fixture.store.hosts
        hosts[0].controlEpoch = "first"
        fixture.store.apply(.hosts(hosts))
        let original = fixture.store.decisionPresentation(.approval(approval), target: fixture.target)
        fixture.selection = .init(target: fixture.target, approvalID: approval.id, presentation: original)
        let sheet = fixture.sheet
        let option = try XCTUnwrap(approval.options.first)
        hosts[0].connection = .synchronizing
        fixture.store.apply(.hosts(hosts))
        await sheet.respond(original, option: option)
        XCTAssertEqual(fixture.store.decisionNotices(for: fixture.target).count, 1)
        hosts[0].connection = .connected
        fixture.store.apply(.hosts(hosts))
        XCTAssertTrue(fixture.service.commands.isEmpty, "Reconnect sends nothing automatically")
        hosts[0].controlEpoch = "second"
        fixture.store.apply(.hosts(hosts))
        XCTAssertNil(sheet.currentDecision)
        await sheet.respond(original, option: option)
        XCTAssertTrue(fixture.service.commands.isEmpty)
        let current = fixture.store.decisionPresentation(.approval(approval), target: fixture.target)
        fixture.selection = .init(target: fixture.target, approvalID: approval.id, presentation: current)
        await fixture.sheet.respond(current, option: option)
        XCTAssertEqual(fixture.service.commands, ["respond"])
        XCTAssertEqual(fixture.sheet.currentApproval?.resolution, .allowed)
    }

    func testPinnedQuestionReviewDismissalAnswerAndWithdrawalShareTheQueue() async {
        let fixture = ReviewFixture([], selected: "question")
        defer { fixture.tearDown() }
        var question = CompanionQuestion(id: "question", prompts: [
            .init(id: "color", text: "Which color?", options: [.init(id: "red", label: "Red")],
                  allowsMultiple: false, allowsFreeText: false)])
        var hosts = fixture.store.hosts
        for project in hosts[0].projects.indices {
            if let index = hosts[0].projects[project].agents.firstIndex(where: { $0.id == fixture.target }) {
                hosts[0].projects[project].agents[index].capabilities.insert(.answer)
            }
        }
        fixture.store.apply(.hosts(hosts))
        fixture.store.apply(.timeline(fixture.target, items: [.question(question)], sequence: 2, reset: true, sessionID: "synthetic-review"))
        let presentation = fixture.store.decisionPresentation(.question(question), target: fixture.target)
        fixture.selection = .init(target: fixture.target, approvalID: question.id, presentation: presentation)
        let sheet = fixture.sheet
        XCTAssertEqual(sheet.currentDecision, .question(question))
        sheet.close()
        await sheet.answer(presentation, answers: ["color": .text("red")])
        XCTAssertTrue(fixture.service.commands.isEmpty)
        fixture.selection = .init(target: fixture.target, approvalID: question.id, presentation: presentation)
        await fixture.sheet.answer(presentation, answers: ["color": .text("red")])
        XCTAssertEqual(fixture.service.commands, ["answer"])
        XCTAssertTrue(CompanionPendingDecision.pending(in: fixture.store.conversation(for: fixture.target).items).isEmpty)
        question.resolution = .cancelled
        fixture.store.apply(.upsert(fixture.target, .question(question), sequence: 3))
        await fixture.sheet.answer(presentation, answers: ["color": .text("red")])
        XCTAssertEqual(fixture.sheet.currentDecision, .question(question))
        XCTAssertEqual(fixture.service.commands, ["answer"])
    }

    private func mountTray(_ fixture: ReviewFixture, initialReview: CompanionComposerApprovalReviewSelection? = nil) throws -> (UIWindow, UIHostingController<CompanionConversationPendingDecisions>, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        var tray = CompanionConversationPendingDecisions(store: fixture.store, target: fixture.target,
            maximumHeight: 400, compactHeight: false, showInChat: { _ in })
        #if DEBUG
        if let initialReview { tray = tray.withInitialReviewForTesting(initialReview) }
        #endif
        let controller = UIHostingController(rootView: tray)
        // Production mounts the tray inside a footer, not as a whole screen. Measure its content,
        // excluding this isolated hosting window's top/bottom safe areas; no tolerance or fixed inset.
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller, originalKey)
    }

    private func renderedText(_ window: UIWindow) throws -> String {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let cgImage = try XCTUnwrap(image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func requireRenderedLabel(_ label: String, in window: UIWindow) async throws {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.renderedText(window).contains(label)) == true
        }, object: nil)
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertTrue(try renderedText(window).contains(label), "The mounted native Menu label updates after a genuine change")
    }

    private func request(_ id: String) -> CompanionApproval {
        .init(id: id, toolName: "Synthetic tool", summary: "Synthetic approval", title: "Review \(id)",
              deadline: .now.addingTimeInterval(300), options: [.init(id: "allow-\(id)", label: "Allow once", kind: .allowOnce)])
    }
}

@MainActor private final class ReviewFixture {
    // ARC-only after explicit MainActor tearDown: owns a UI-free Store + the reviewed synthetic spy,
    // a target/selection and a counter. No started listener or persistence/UI owner; see validation doc.
    nonisolated deinit {}
    let service = ReviewServiceSpy()
    let store: CompanionStore
    let target = CompanionPreviewService.target
    var selection: CompanionComposerApprovalReviewSelection?
    private var sequence = 0

    init(_ approvals: [CompanionApproval], selected: String) {
        store = CompanionStore(service: service)
        store.apply(.hosts(CompanionPreviewService.hosts(now: .now, dispatcher: true)))
        store.drafts[target] = "Keep every line\n🙂"
        selection = .init(target: target, approvalID: selected)
        publish(approvals)
    }

    var sheet: CompanionComposerApprovalReviewSheet {
        sheet(for: target)
    }

    func sheet(for target: CompanionTarget) -> CompanionComposerApprovalReviewSheet {
        .init(store: store, target: target, selection: Binding(get: { self.selection }, set: { self.selection = $0 }))
    }

    func publish(_ approvals: [CompanionApproval], for target: CompanionTarget? = nil) {
        sequence += 1
        store.apply(.timeline(target ?? self.target, items: approvals.map(CompanionTimelineItem.approval), sequence: sequence, reset: true, sessionID: "synthetic-review"))
    }

    func tearDown() {
        selection = nil
        service.tearDown()
        store.stop()
    }
}

@MainActor private final class ReviewServiceSpy: CompanionService {
    // Not String-only: the callback captures an XCTestExpectation and waiting retains a suspended task.
    // MainActor tearDown releases/resumes both before ARC-only destruction; no callback runs in deinit.
    nonisolated deinit {}
    struct Response { let approvalID: String; let optionID: String; let target: CompanionTarget }
    var commands: [String] = []
    var responses: [Response] = []
    var holdsResponse = false
    var refusesResponse = false
    var responseArrived: (() -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?
    var hasHeldResponse: Bool { waiting != nil }

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
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws {
        commands.append("answer")
    }
    func tearDown() {
        responseArrived = nil
        holdsResponse = false
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}
