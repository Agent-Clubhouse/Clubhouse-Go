#if DEBUG
import XCTest
import SwiftUI
import Vision
@testable import ClubhouseGo

@MainActor final class CompanionManagedSpawnCapabilityTests: XCTestCase {
    func testOpenManagedSheetBlocksCreateWhenCapabilityDisappears() async throws {
        try await assertCapabilityLossBlocksCreate(selection: .blank, choice: "Blank")
    }

    func testOpenManagedTemplateSheetBlocksCreateWhenCapabilityDisappears() async throws {
        try await assertCapabilityLossBlocksCreate(selection: .template("helper"), choice: "Template")
    }

    func testProjectSwitchKeepsManagedIntentWithoutWarningDuringOptionsLoad() async throws {
        try await assertCapabilityLossBlocksCreate(selection: .template("helper"), choice: "Project switch", switchingProjects: true)
    }

    private func assertCapabilityLossBlocksCreate(selection: CompanionManagedSelection, choice: String, switchingProjects: Bool = false) async throws {
        let service = ManagedCapabilityService()
        let store = CompanionStore(service: service)
        var hosts = Array(CompanionPreviewService.hosts(now: Date()).prefix(1))
        hosts[0].canCreateManaged = true
        hosts[0].projectLinks = nil
        if switchingProjects {
            var plain = hosts[0]
            plain.id = "plain-host"
            plain.name = "Plain Mac"
            plain.canCreateManaged = false
            plain.projects = [.init(id: "plain", name: "Plain project", agents: [])]
            hosts.append(plain)
        }
        store.apply(.hosts(hosts))
        let target = CompanionProjectTarget(hostID: hosts[0].id, projectID: "clubhouse")
        XCTAssertNotNil(store.projectEntry(containing: target), "The synthetic target must be in the store before opening the sheet")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        var observed: CompanionSpawnSheet.HostedTestSeam?
        let controller = UIHostingController(rootView: CompanionSpawnSheet(store: store, initialProject: target,
            hostedTestSeam: { observed = $0 })
            .dynamicTypeSize(.large).companionTheme(.clubhouse).environment(\.colorScheme, .light))
        var completed = false
        defer {
            if !completed {
                let state = XCTAttachment(string: "reads=\(service.reads), entries=\(store.projectEntries.count), scene=\(scene.activationState.rawValue), hidden=\(window.isHidden), presented=\(presenter.presentedViewController === controller)")
                state.name = "Hosted spawn setup state: \(choice)"
                state.lifetime = .keepAlways
                add(state)
                _ = try? renderedText(window, choice: "Setup diagnostics \(choice)")
            }
            controller.dismiss(animated: false)
            service.finishPlainRead()
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKey()
            store.shutdown()
            observed = nil
        }
        let presented = expectation(description: "The actual New agent sheet finished presentation")
        presenter.present(controller, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 5)
        controller.view.layoutIfNeeded()
        try await waitUntil { observed?.optionsLoaded == true && observed?.loading == false }
        XCTAssertGreaterThan(service.reads, 0)
        try XCTUnwrap(observed).selectTemplate(selection)
        try await waitUntil { observed?.selection == selection && observed?.createDisabled == false }
        XCTAssertEqual(try XCTUnwrap(observed).selection, selection)
        XCTAssertTrue(service.requests.isEmpty)
        // #480: the initial cancelled task also reads options on merged #453.
        // Measure the settled form, then require exact transition-specific deltas.
        let initialReads = service.reads

        if switchingProjects {
            try XCTUnwrap(observed).selectProject(.init(hostID: "plain-host", projectID: "plain"))
            try await waitUntil { service.plainRead != nil && observed?.loading == true }
            XCTAssertFalse(try XCTUnwrap(observed).showsUnavailable, "A normal options load must not claim templates disappeared")
            XCTAssertTrue(try XCTUnwrap(observed).createDisabled, "Keep Create blocked during the read")
            XCTAssertFalse(try XCTUnwrap(observed).createHint.contains("no longer offers templates"))
            XCTAssertTrue(service.requests.isEmpty)
            service.finishPlainRead()
            try await waitUntil { observed?.showsUnavailable == true }
        } else {
            // Keep the same connected host/project and sheet; only managedCreate is withdrawn.
            hosts[0].canCreateManaged = false
            store.apply(.hosts(hosts))
        }
        try await Task.sleep(for: .milliseconds(250))
        scroll(window, toBottom: false)
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let current = try XCTUnwrap(observed)
        XCTAssertTrue(current.createDisabled, "The user's managed choice must never silently turn into a plain create")
        let text = try renderedText(window, choice: choice)
        XCTAssertTrue(text.contains("no longer offers templates"), "Explain why the open sheet cannot create: \(text)")
        XCTAssertTrue(text.contains("reopen"), "Give an explicit way to start a new plain flow: \(text)")
        // Invoke the exact production action even while its button is disabled.
        // This independently exercises request-construction defense in depth.
        current.create()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(service.requests.isEmpty, "No managed or plain command may be sent after capability loss")
        XCTAssertNil(store.uncertainCreateRequest)
        XCTAssertEqual(service.reads, initialReads + (switchingProjects ? 1 : 0), "Only a project switch starts a new options read after the form settles")
        completed = true
    }

    private func scroll(_ view: UIView, toBottom: Bool) {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            let offset = toBottom ? max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom) : -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
        }
        for child in view.subviews { self.scroll(child, toBottom: toBottom) }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(condition() ? true : nil, "The real hosted sheet must reach the requested state", file: file, line: line)
    }

    private func renderedText(_ window: UIWindow, choice: String) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Managed \(choice) capability withdrawn while sheet stays open"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
    }
}

@MainActor private final class ManagedCapabilityService: CompanionService {
    var reads = 0
    var requests: [CompanionCreateRequest] = []
    var plainRead: CheckedContinuation<Void, Never>?
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { throw CompanionServiceError.unavailable("Test only") }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("No sends") }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("No spawns") }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        reads += 1
        if project.hostID == "plain-host" {
            await withCheckedContinuation { plainRead = $0 }
            return .init(options: .init(), isGitRepo: true, suggestedName: "plain-agent", defaultOrchestrator: "codex-cli")
        }
        return .init(options: .init(), managed: .init(defaultOn: true, templates: [
            .init(id: "helper", name: "Helper", description: "A focused helper", builtin: true)
        ]),
                     isGitRepo: true, suggestedName: "brave-otter", defaultOrchestrator: "codex-cli", defaultModel: "default")
    }
    func finishPlainRead() {
        let pending = plainRead
        plainRead = nil
        pending?.resume()
    }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt {
        requests.append(request)
        throw CompanionServiceError.rejected("No creates in this test")
    }
}

#endif
