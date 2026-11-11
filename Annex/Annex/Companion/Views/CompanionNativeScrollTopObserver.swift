import SwiftUI
import UIKit

/// UIKit asks before its native animation starts, earlier than SwiftUI's first offset sample.
struct CompanionNativeScrollTopObserver: UIViewRepresentable {
    let requested: @MainActor () -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.requested = requested
        view.connect()
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.disconnect()
        view.requested = nil
    }

    final class Anchor: UIView, UIScrollViewDelegate {
        var requested: (@MainActor () -> Void)?
        private weak var scrollView: UIScrollView?
        private weak var originalDelegate: (any UIScrollViewDelegate)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { disconnect() } else { connect() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
        }

        func connect() {
            guard window != nil else { disconnect(); return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    if scrollView !== scroll { disconnect(); scrollView = scroll }
                    if scroll.delegate !== self {
                        originalDelegate = scroll.delegate
                        scroll.delegate = self
                    }
                    return
                }
                ancestor = view.superview
            }
            disconnect()
        }

        func disconnect() {
            if scrollView?.delegate === self { scrollView?.delegate = originalDelegate }
            scrollView = nil
            originalDelegate = nil
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            let allowed = originalDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
            if allowed, scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 1 { requested?() }
            return allowed
        }
    }
}
