import SwiftUI

/// Full identities keep equal agent names on different desktops separate.
enum CompanionHomeAnchor: Hashable {
    case summary, desktops, idle
    case attention(CompanionTarget), dispatcher(String), project(String), agent(CompanionTarget)
    case quiet(String), finished(CompanionTarget), offline(CompanionProjectTarget), cached(CompanionTarget)
}

/// Non-observable scroll bookkeeping: geometry must not rebuild Home on every scrolling pixel.
/// Owns only identifiers, rectangles and scalar flags; no views, controllers, callbacks or tasks.
@MainActor final class CompanionHomeScrollAnchorState {
    nonisolated deinit {}
    struct Bookmark {
        let id: CompanionHomeAnchor
        let alignment: UnitPoint
    }
    private(set) var bookmark: Bookmark?
    private var frames: [CompanionHomeAnchor: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var suspended = true
    private var restoring = false
    private var restoreRequested = false
    private var resumeApplied = false
    private var restorationCallbacks = 0

    #if DEBUG
    var testFrames: [CompanionHomeAnchor: CGRect] { frames }
    var testViewport: CGRect { viewport }
    var testRestoring: Bool { restoring }
    #endif

    func record(_ id: CompanionHomeAnchor, frame: CGRect) {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        frames[id] = frame
        if restoring {
            restorationCallbacks += 1
            if (restoreRequested && bookmark?.id == id && frame.intersects(viewport)) || restorationCallbacks >= 64 {
                cancelRestoration()
            }
        }
        capture()
    }

    func remove(_ id: CompanionHomeAnchor) { frames[id] = nil }

    func setViewport(_ frame: CGRect) {
        viewport = frame
        if restoring {
            restorationCallbacks += 1
            if restorationCallbacks >= 64 { cancelRestoration() }
        }
        capture()
    }

    func suspend() {
        // Geometry has already captured the last valid position. During removal it can
        // describe disappearing/top rows, so never replace the bookmark here.
        suspended = true
        resumeApplied = false
        cancelRestoration()
        frames.removeAll()
    }

    func cancelRestoration() {
        restoring = false
        restoreRequested = false
        restorationCallbacks = 0
    }

    func reset() {
        bookmark = nil
        resumeApplied = false
        cancelRestoration()
        frames.removeAll()
    }

    func resume(_ proxy: ScrollViewProxy, available: (CompanionHomeAnchor) -> Bool) {
        guard !resumeApplied, viewport.height > 0 else { return }
        resumeApplied = true
        suspended = false
        if let saved = bookmark, available(saved.id) {
            restoring = true
            restoreRequested = true
            restorationCallbacks = 0
            // A real List target, not a hierarchy walk or an assumed native offset.
            proxy.scrollTo(saved.id, anchor: saved.alignment)
        } else {
            bookmark = nil
            restoring = false
            restoreRequested = false
            proxy.scrollTo(CompanionHomeAnchor.summary, anchor: .top)
            capture()
        }
    }

    private func capture() {
        guard !suspended, !restoring, viewport.height > 0 else { return }
        let visible = frames.filter { $0.value.intersects(viewport) && $0.value.height > 0 }
        let contained = visible.filter { viewport.contains($0.value) }
        guard let first = (contained.isEmpty ? visible : contained).min(by: { $0.value.minY < $1.value.minY }) else { return }
        let remaining = viewport.height - first.value.height
        let fraction = remaining > 0 ? (first.value.minY - viewport.minY) / remaining : 0
        bookmark = .init(id: first.key, alignment: .init(x: 0.5, y: max(0, min(1, fraction))))
    }
}

private struct CompanionHomeScrollAnchorKey: EnvironmentKey {
    static let defaultValue: CompanionHomeScrollAnchorState? = nil
}

extension EnvironmentValues {
    var companionHomeScrollAnchor: CompanionHomeScrollAnchorState? {
        get { self[CompanionHomeScrollAnchorKey.self] }
        set { self[CompanionHomeScrollAnchorKey.self] = newValue }
    }
}

private struct CompanionHomeAnchorMarker: ViewModifier {
    let id: CompanionHomeAnchor
    @Environment(\.companionHomeScrollAnchor) private var state

    @ViewBuilder func body(content: Content) -> some View {
        if let state {
            content.id(id)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _, frame in state.record(id, frame: frame) }
                .onDisappear { state.remove(id) }
        } else { content }
    }
}

extension View {
    /// A no-op outside Home, including the Project page and its existing row tests.
    func companionHomeAnchor(_ id: CompanionHomeAnchor) -> some View { modifier(CompanionHomeAnchorMarker(id: id)) }
}
