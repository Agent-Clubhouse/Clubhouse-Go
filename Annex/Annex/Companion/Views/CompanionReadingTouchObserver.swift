import SwiftUI
import UIKit

/// Observes the first touch without claiming it or delaying links, selection, menus or scrolling.
/// The restore task must yield before UIKit's scroll recognizer has recognized a drag.
struct CompanionReadingTouchObserver: UIViewRepresentable {
    let touched: @MainActor () -> Void
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) { view.touched = touched }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.disconnect() }

    final class Anchor: UIView {
        var touched: (@MainActor () -> Void)?
        private let press = ReadingOpeningTouch()
        private weak var observedWindow: UIWindow?
        override init(frame: CGRect) {
            super.init(frame: frame)
            press.anchor = self
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            disconnect()
            if let window { observedWindow = window; window.addGestureRecognizer(press) }
        }
        func disconnect() { observedWindow?.removeGestureRecognizer(press); observedWindow = nil }
        func touchBegan(at point: CGPoint) {
            // The composer is a sibling outside this transcript's bounds.
            if bounds.contains(point) { touched?() }
        }
    }
}

private final class ReadingOpeningTouch: UIGestureRecognizer {
    weak var anchor: CompanionReadingTouchObserver.Anchor?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let anchor { anchor.touchBegan(at: touch.location(in: anchor)) }
        state = .failed
    }
}
