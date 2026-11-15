import SwiftUI
import XCTest
@testable import ClubhouseGo

/// Component-level timing probe; the app's animated navigation is covered separately by UI tests.
@MainActor final class CompanionWakeFocusTests: XCTestCase {
    @MainActor @Observable final class Presentation {
        nonisolated deinit {}
        var showing = false
    }

    private struct SheetHost: View {
        @Bindable var presentation: Presentation
        let store: CompanionStore
        let project: CompanionProjectTarget
        let appeared: () -> Void

        var body: some View {
            Text("Wake presentation host")
                .sheet(isPresented: $presentation.showing) {
                    CompanionWakeSheet(store: store, project: project, onWake: { _, _ in })
                        .onAppear(perform: appeared)
                }
        }
    }

    @MainActor private final class Host: UIHostingController<SheetHost> {
        var appeared: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
            appeared = nil
        }
    }

    private func findInput(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView { return view }
        return view.subviews.lazy.compactMap { self.findInput(in: $0) }.first
    }

    func testNativeAutofocusDuringNormalAndSlowSheetPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for speed: Float in [1, 0.1] {
            let store = CompanionStore(service: CompanionPreviewService())
            store.apply(.hosts(CompanionPreviewService.hosts(now: .now)))
            let target = CompanionPreviewService.target
            let project = CompanionProjectTarget(hostID: target.hostID, projectID: target.projectID)
            let presentation = Presentation()
            let appeared = expectation(description: "Production Wake sheet appeared")
            let mounted = expectation(description: "Presenter finished appearing")
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.layer.speed = speed
            let controller = Host(rootView: SheetHost(presentation: presentation, store: store, project: project,
                appeared: { appeared.fulfill() }))
            controller.appeared = { mounted.fulfill() }
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.layer.speed = 1
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
                store.shutdown()
            }
            await fulfillment(of: [mounted], timeout: 5)
            let started = ContinuousClock.now
            presentation.showing = true
            await fulfillment(of: [appeared], timeout: 15)
            let sheet = try XCTUnwrap(controller.presentedViewController)
            let input = try XCTUnwrap(findInput(in: sheet.view))
            print("WAKE_COMPONENT speed=\(speed) event=appeared elapsed=\(started.duration(to: .now)) inWindow=\(input.window === window) firstResponder=\(input.isFirstResponder) presenting=\(sheet.isBeingPresented) transitionDuration=\(sheet.transitionCoordinator?.transitionDuration ?? 0)")
            await fulfillment(of: [
                expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: input),
                expectation(for: NSPredicate { _, _ in !sheet.isBeingPresented }, evaluatedWith: sheet)
            ], timeout: 15)
            let elapsed = started.duration(to: .now)
            print("WAKE_COMPONENT speed=\(speed) event=presented elapsed=\(elapsed) inWindow=\(input.window === window) firstResponder=\(input.isFirstResponder)")
            XCTAssertTrue(input.window === window)
            XCTAssertTrue(input.isFirstResponder)
            if speed < 1 {
                XCTAssertGreaterThan(elapsed, .seconds(2), "The slow scenario must actually slow presentation")
            }
            presentation.showing = false
            await fulfillment(of: [
                expectation(for: NSPredicate { _, _ in controller.presentedViewController == nil }, evaluatedWith: controller)
            ], timeout: 15)
        }
    }
}
