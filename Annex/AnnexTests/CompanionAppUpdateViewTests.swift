import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionAppUpdateViewTests: XCTestCase {
    private func fixture(_ name: String) throws -> AnnexJSON {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: url))
    }

    func testEveryDesktopStateAndRequestCanBeHostedAtPhoneWidths() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        var host = CompanionHost(id: "fixture", name: "Studio", endpoint: "local", connection: .connected, projects: [])
        host.canUpdateApp = true
        host.canCheckAppUpdate = true
        let values = try fixture("app-update-statuses")["values"].arrayValue
        XCTAssertFalse(values.isEmpty)
        var states = Set<String>()
        for value in values {
            let update = try value.decode(AnnexAppUpdate.self)
            states.insert(update.state.rawValue)
            host.appUpdate = update
            XCTAssertEqual(host.hasAppUpdateAffordance, update.state == .available || update.state == .downloading || update.state == .ready)
            store.apply(.hosts([host]))
            let controller = UIHostingController(rootView: CompanionAppUpdateView(store: store, hostID: host.id))
            for width in [320.0, 402.0] {
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 874))
                XCTAssertLessThanOrEqual(size.width, width)
                XCTAssertGreaterThan(size.height, 44)
            }
            switch update.state {
            case .none:
                XCTAssertEqual(CompanionAppUpdateText.status(update), "No update known (running \(update.currentVersion))")
                XCTAssertFalse(host.canRequestAppUpdate)
            case .downloading:
                XCTAssertTrue(CompanionAppUpdateText.status(update).contains("%"))
                XCTAssertFalse(host.canRequestAppUpdate)
            case .available, .unsupported: XCTAssertFalse(host.canRequestAppUpdate)
            case .ready: XCTAssertTrue(CompanionAppUpdateText.status(update).contains(try XCTUnwrap(update.availableVersion)))
            }
        }
        XCTAssertEqual(states, Set(["none", "available", "downloading", "ready", "unsupported"]))
    }

    func testTheFixturesInterruptionReviewPrecedesThreeExplicitChoicesAtNarrowAndAccessibleSizes() throws {
        let fixture = try fixture("snapshot-app-update-approval")
        var host = CompanionHost(id: "fixture", name: "Studio", endpoint: "local", connection: .connected, projects: [])
        host.canUpdateApp = true
        host.canAnswerGrantRequests = true
        host.controlEpoch = "fixture-epoch"
        host.appUpdate = try XCTUnwrap(fixture["appUpdate"]).decode(AnnexAppUpdate.self)
        host.grantRequests = CompanionLiveService.grantRequests(from: .array([try XCTUnwrap(fixture["grantRequest"])]),
                                                               hostID: host.id, epoch: host.controlEpoch)
        let request = try XCTUnwrap(host.appUpdateApproval)
        XCTAssertEqual(request.update?.workingAgents.first?.name, "planner")
        XCTAssertEqual(request.answers, [.allowOnce, .decline])
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts([host]))
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let controller = UIHostingController(rootView: CompanionGrantRequestActions(request: request, store: store, showsOpenChat: false)
                .dynamicTypeSize(typeSize))
            let size = controller.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, 320)
            XCTAssertGreaterThan(size.height, 132, "Full interruption review and three tappable choices need vertical space")
        }
        host.controlEpoch = "new-epoch"
        XCTAssertNil(host.appUpdateApproval)
    }

    func testRequestAndEachApprovalChoiceUseOneStoreFlowWithoutNeedsYouNavigation() async throws {
        for mode in [Optional<AnnexUpdateMode>.some(.now), .some(.whenIdle), .none] {
            let service = CompanionPreviewService()
            service.showsAppUpdate = true
            let store = CompanionStore(service: service)
            store.start()
            defer { store.stop() }
            try await wait { store.hosts.first?.canRequestAppUpdate == true }
            let hostID = try XCTUnwrap(store.hosts.first?.id)
            await store.requestAppUpdate(hostID: hostID)
            try await wait { store.hosts.first?.appUpdateApproval != nil }
            let request = try XCTUnwrap(store.hosts.first?.appUpdateApproval)
            XCTAssertEqual(request.update?.version, "1.1.0")
            XCTAssertEqual(request.update?.workingAgents.first?.name, "River")
            await store.answer(request, with: mode == nil ? .decline : .allowOnce, updateMode: mode)
            let expected: AnnexAppUpdate.Request.State = mode == nil ? .cancelled : mode == .now ? .restarting : .waitingForIdle
            try await wait { store.hosts.first?.appUpdate?.request?.state == expected }
            XCTAssertEqual(store.hosts.first?.appUpdate?.request?.state,
                           mode == nil ? .cancelled : mode == .now ? .restarting : .waitingForIdle)
        }

    }

    func testCheckingFlowsIntoLiveDownloadAndReadyInTheHostedViewWithoutCreatingAnApproval() async throws {
        let service = CompanionPreviewService()
        service.showsAppUpdate = true
        service.appUpdateInitialState = AnnexAppUpdate.State.none
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop() }
        try await wait { store.hosts.first?.appUpdate?.state == AnnexAppUpdate.State.none }
        let host = try XCTUnwrap(store.hosts.first)
        XCTAssertTrue(host.canCheckAppUpdate)
        let checking = Task { await store.checkAppUpdate(hostID: host.id) }
        try await wait { store.appUpdateChecksInFlight.contains(host.id) }
        let controller = UIHostingController(rootView: CompanionAppUpdateView(store: store, hostID: host.id))
        XCTAssertGreaterThan(controller.sizeThatFits(in: CGSize(width: 320, height: 874)).height, 44)
        for _ in 0..<300 {
            if store.hosts.first?.appUpdate?.state == .downloading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.hosts.first?.appUpdate?.state, .downloading)
        XCTAssertTrue(store.appUpdateChecksInFlight.contains(host.id))
        XCTAssertNil(store.hosts.first?.appUpdateApproval)
        await checking.value
        XCTAssertEqual(store.hosts.first?.appUpdate?.state, .ready)
        XCTAssertEqual(store.hosts.first?.appUpdate?.downloadProgress, 100)
        XCTAssertTrue(store.appUpdateChecksInFlight.isEmpty)
        XCTAssertNil(store.hosts.first?.appUpdateApproval)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The synthetic desktop did not publish its update state")
        throw AnnexTransportError.disconnected
    }
}
