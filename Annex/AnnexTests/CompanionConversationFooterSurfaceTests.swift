import XCTest
import SwiftUI
@testable import ClubhouseGo

/// #533: the composer footer's scroll container reaches under the keyboard and tab bar. It must not host
/// system scroll-edge effects, which paint a band from its top edge that doesn't match the chat surface.
@MainActor final class CompanionConversationFooterSurfaceTests: XCTestCase {
    func testFooterScrollContainerHostsNoEdgeEffectsWithKeyboardDownAndUp() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        let hosts = CompanionPreviewService.hosts(now: .now, dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        let items: [CompanionTimelineItem] = (0..<64).map {
            .message(.init(id: "history-\($0)", role: .assistant, text: "A fixture message long enough to fill the transcript."))
        }
        store.apply(.timeline(target, items: items, sequence: 5_000, reset: true, sessionID: "fixture"))
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let appeared = expectation(description: "The conversation has appeared")
        let controller = UIHostingController(rootView: NavigationStack {
            CompanionConversationView(store: store, agent: agent)
                .onAppear { appeared.fulfill() }
        }.environment(\.scenePhase, .active))
        window.frame = scene.screen.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        await fulfillment(of: [appeared], timeout: 10)
        controller.view.layoutIfNeeded()

        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { $0 is UITextView ? [] : [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        // The footer container is the nearest scroll view enclosing the native draft (itself a UITextView).
        func footer(of input: UITextView) -> UIScrollView? {
            sequence(first: input.superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        }
        func assertNoEdgeEffects(_ state: String) throws {
            let input = try XCTUnwrap(find(window), "\(state): the composer's native draft")
            let footer = try XCTUnwrap(footer(of: input), "\(state): the footer scroll container")
            XCTAssertGreaterThan(scrollViews(window).count, 1, "\(state): the transcript is a separate scroll view")
            for (edge, effect) in [("top", footer.topEdgeEffect), ("bottom", footer.bottomEdgeEffect),
                                   ("left", footer.leftEdgeEffect), ("right", footer.rightEdgeEffect)] {
                XCTAssertTrue(effect.isHidden, "\(state): the footer hosts no \(edge) scroll-edge effect")
            }
        }

        try assertNoEdgeEffects("keyboard down")
        let input = try XCTUnwrap(find(window))
        let keyboardShown = expectation(forNotification: UIResponder.keyboardDidShowNotification, object: nil)
        XCTAssertTrue(input.becomeFirstResponder())
        await fulfillment(of: [keyboardShown], timeout: 10)
        controller.view.layoutIfNeeded()
        try assertNoEdgeEffects("keyboard up")
        let keyboardHidden = expectation(forNotification: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertTrue(input.resignFirstResponder())
        await fulfillment(of: [keyboardHidden], timeout: 10)
        controller.view.layoutIfNeeded()
        try assertNoEdgeEffects("keyboard dismissed")
    }
}
