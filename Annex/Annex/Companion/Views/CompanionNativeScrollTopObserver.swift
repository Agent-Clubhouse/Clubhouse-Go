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

        func scrollViewDidScroll(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidScroll?(scrollView) }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidZoom?(scrollView) }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { originalDelegate?.scrollViewWillBeginDragging?(scrollView) }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                      targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            originalDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        }
        func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) { originalDelegate?.scrollViewWillBeginDecelerating?(scrollView) }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidEndDecelerating?(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidEndScrollingAnimation?(scrollView) }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { originalDelegate?.viewForZooming?(in: scrollView) }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            originalDelegate?.scrollViewWillBeginZooming?(scrollView, with: view)
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            originalDelegate?.scrollViewDidEndZooming?(scrollView, with: view, atScale: scale)
        }
        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidScrollToTop?(scrollView) }
        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidChangeAdjustedContentInset?(scrollView) }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            let allowed = originalDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
            if allowed, scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 1 { requested?() }
            return allowed
        }
    }
}
