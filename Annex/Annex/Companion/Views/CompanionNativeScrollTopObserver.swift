import SwiftUI
import UIKit
import QuartzCore

/// UIKit asks before its native animation starts, earlier than SwiftUI's first offset sample.
struct CompanionNativeScrollTopObserver: UIViewRepresentable {
    let requested: @MainActor () -> Void
    let pending: @MainActor () -> Bool
    let repaired: @MainActor () -> Void
    let geometryChanged: @MainActor (CompanionScrollMetrics) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.requested = requested
        view.pending = pending
        view.repaired = repaired
        view.geometryChanged = geometryChanged
        if !pending() { view.stopNativeTopCheck() }
        view.connect()
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.disconnect()
        view.requested = nil
        view.pending = nil
        view.repaired = nil
        view.geometryChanged = nil
    }

    final class Anchor: UIView, UIScrollViewDelegate {
        var requested: (@MainActor () -> Void)?
        var pending: (@MainActor () -> Bool)?
        var repaired: (@MainActor () -> Void)?
        var geometryChanged: (@MainActor (CompanionScrollMetrics) -> Void)?
        private weak var scrollView: UIScrollView?
        private weak var originalDelegate: (any UIScrollViewDelegate)?
        private var displayLink: CADisplayLink?
        private var nativeStartOffset: CGFloat = 0
        private var nativeStartedAt: CFTimeInterval = 0

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
                    reportGeometry(scroll)
                    return
                }
                ancestor = view.superview
            }
            disconnect()
        }

        func disconnect() {
            stopNativeTopCheck()
            if scrollView?.delegate === self { scrollView?.delegate = originalDelegate }
            scrollView = nil
            originalDelegate = nil
        }

        private func reportGeometry(_ scroll: UIScrollView) {
            geometryChanged?(.init(offset: scroll.contentOffset.y, contentHeight: scroll.contentSize.height,
                containerHeight: scroll.bounds.height, topInset: scroll.adjustedContentInset.top,
                bottomInset: scroll.adjustedContentInset.bottom))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportGeometry(scrollView)
            originalDelegate?.scrollViewDidScroll?(scrollView)
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidZoom?(scrollView) }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            stopNativeTopCheck()
            originalDelegate?.scrollViewWillBeginDragging?(scrollView)
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                      targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            originalDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        }
        func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) { originalDelegate?.scrollViewWillBeginDecelerating?(scrollView) }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { originalDelegate?.scrollViewDidEndDecelerating?(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidEndScrollingAnimation?(scrollView)
            completeNativeTopIfNeeded(scrollView)
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { originalDelegate?.viewForZooming?(in: scrollView) }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            originalDelegate?.scrollViewWillBeginZooming?(scrollView, with: view)
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            originalDelegate?.scrollViewDidEndZooming?(scrollView, with: view, atScale: scale)
        }
        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidScrollToTop?(scrollView)
            completeNativeTopIfNeeded(scrollView)
        }
        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            reportGeometry(scrollView)
            originalDelegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            let allowed = originalDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
            if allowed, scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 1 {
                requested?()
                beginNativeTopCheck(scrollView)
            }
            return allowed
        }

        private func beginNativeTopCheck(_ scrollView: UIScrollView) {
            stopNativeTopCheck()
            guard pending?() == true else { return }
            nativeStartOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            nativeStartedAt = CACurrentMediaTime()
            let link = CADisplayLink(target: FrameTarget(anchor: self), selector: #selector(FrameTarget.tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stopNativeTopCheck() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func sampleNativeTop(_ link: CADisplayLink) {
            guard let scrollView, window != nil, pending?() == true,
                  !scrollView.isTracking, !scrollView.isDragging else { stopNativeTopCheck(); return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            guard offset > 1 else { stopNativeTopCheck(); return }
            guard link.duration > 0, link.timestamp - nativeStartedAt >= 2 * link.duration else { return }
            if offset >= nativeStartOffset - 1 || !scrollView.isScrollAnimating {
                completeNativeTopIfNeeded(scrollView)
            }
        }

        private func completeNativeTopIfNeeded(_ scroll: UIScrollView) {
            guard displayLink != nil, scroll === scrollView else { return }
            guard pending?() == true, !scroll.isTracking, !scroll.isDragging else { stopNativeTopCheck(); return }
            guard scroll.contentOffset.y + scroll.adjustedContentInset.top > 1 else { stopNativeTopCheck(); return }
            // Consume the repair before scrolling: delegate callbacks can be synchronous.
            stopNativeTopCheck()
            repaired?()
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        }
    }

    @MainActor private final class FrameTarget: NSObject {
        weak var anchor: Anchor?
        init(anchor: Anchor) { self.anchor = anchor; super.init() }
        @objc func tick(_ link: CADisplayLink) {
            guard let anchor else { link.invalidate(); return }
            anchor.sampleNativeTop(link)
        }
    }
}
