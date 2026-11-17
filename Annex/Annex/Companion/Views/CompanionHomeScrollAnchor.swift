import Combine
import SwiftUI

/// Full identities keep equal agent names on different desktops separate.
enum CompanionHomeAnchor: Hashable {
    case summary, desktops, idle
    case attention(CompanionTarget), dispatcher(String), project(CompanionProjectTarget), agent(CompanionTarget)
    case quiet(String), finished(CompanionTarget), offline(CompanionProjectTarget), cached(CompanionTarget)
}

/// List must know an offscreen row's anchor from its DATA identity. A nested explicit
/// .id is only registered after that lazy row is realised. Non-Home callers keep their
/// original ForEach identifiers and hierarchy.
struct CompanionHomeForEach<Value: Identifiable, Row: View>: View {
    let values: [Value]
    let anchor: (Value) -> CompanionHomeAnchor
    let row: (Value) -> Row
    @Environment(\.companionHomeScrollAnchor) private var owner

    init(_ values: [Value], anchor: @escaping (Value) -> CompanionHomeAnchor,
         @ViewBuilder row: @escaping (Value) -> Row) {
        self.values = values; self.anchor = anchor; self.row = row
    }

    private struct Item: Identifiable {
        let id: CompanionHomeAnchor
        let index: Int
    }

    var body: some View {
        if owner != nil {
            // Keep only small IDs/indices in the identity projection, not another array
            // of by-value Hosts/ProjectGroups (#524's Debug stack constraint).
            ForEach(values.indices.map { Item(id: anchor(values[$0]), index: $0) }) { row(values[$0.index]) }
        } else {
            ForEach(values) { row($0) }
        }
    }
}

/// Quiet disclosures are singleton rows rather than elements of an existing data loop.
/// Giving that singleton a data ID also makes it addressable before its body is mounted.
struct CompanionHomeAnchorRow<Row: View>: View {
    let id: CompanionHomeAnchor
    let row: Row
    @Environment(\.companionHomeScrollAnchor) private var owner

    init(_ id: CompanionHomeAnchor, @ViewBuilder row: () -> Row) {
        self.id = id; self.row = row()
    }

    var body: some View {
        if owner != nil { ForEach([id], id: \.self) { _ in row } }
        else { row }
    }
}

/// Non-observable scroll bookkeeping: geometry must not rebuild Home on every scrolling pixel.
/// StateObject provides lazy owner lifetime only; no published fields or change notifications.
/// Owns only identifiers, rectangles and scalar flags; no views, controllers, callbacks or tasks.
@MainActor final class CompanionHomeScrollAnchorState: ObservableObject {
    nonisolated deinit {}
    struct Bookmark {
        let id: CompanionHomeAnchor
        let alignment: UnitPoint
    }
    private(set) var bookmark: Bookmark?
    private var frames: [CompanionHomeAnchor: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var presented = false
    private var resumeGeneration: UInt64 = 0
    private var suspended = true
    private var restoring = false
    private var restoreRequested = false
    private var resumeApplied = false
    private var geometry: ScrollGeometry?

    #if DEBUG
    var testFrames: [CompanionHomeAnchor: CGRect] { frames }
    var testViewport: CGRect { viewport }
    var testRestoring: Bool { restoring }
    #endif

    func record(_ id: CompanionHomeAnchor, frame: CGRect) {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        frames[id] = frame
        capture()
    }

    func remove(_ id: CompanionHomeAnchor) { frames[id] = nil }

    /// Rows use the nearest scroll view's coordinate space. Its public geometry is the
    /// only source of viewport/insets; a generic View geometry already excludes the bars.
    func setGeometry(_ value: ScrollGeometry) {
        geometry = value
        let insets = value.contentInsets
        viewport = CGRect(x: insets.leading, y: insets.top,
            width: max(0, value.containerSize.width - insets.leading - insets.trailing),
            height: max(0, value.containerSize.height - insets.top - insets.bottom))
        capture()
    }

    /// Called synchronously by the always-mounted owner, before removal/push geometry.
    func setPresented(_ value: Bool) {
        guard value != presented else { return }
        presented = value
        if !value { suspend() }
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
        resumeGeneration &+= 1
        restoring = false
        restoreRequested = false
    }

    func reset() {
        bookmark = nil
        resumeApplied = false
        cancelRestoration()
        frames.removeAll()
    }

    func resume(_ proxy: ScrollViewProxy, position: Binding<ScrollPosition>, available: (CompanionHomeAnchor) -> Bool) {
        guard presented, !resumeApplied, viewport.height > 0 else { return }
        resumeApplied = true
        suspended = false
        if let saved = bookmark, !available(saved.id) { bookmark = nil }
        restoring = true
        restoreRequested = false
        settle(proxy, position: position, generation: resumeGeneration, previous: nil,
               stableSamples: 0, corrections: 0, remaining: 60)
    }

    /// A bounded layout handshake, not a timer retained by the owner. Native List first
    /// realises the DATA id, then pixel corrections use the row's actual measured delta.
    /// Bars, lazy height estimates and row insets can change after the identity scroll.
    private func settle(_ proxy: ScrollViewProxy, position: Binding<ScrollPosition>, generation: UInt64,
                        previous: ScrollGeometry?, stableSamples: Int, corrections: Int, remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self, self.presented, self.restoring, self.resumeGeneration == generation else { return }
            guard remaining > 0 else { self.cancelRestoration(); return }
            let current = self.geometry
            let stable = current == previous ? stableSamples + 1 : 0
            var nextCorrections = corrections
            if stable >= 8, let current, self.viewport.height > 0 {
                if !self.restoreRequested {
                    self.restoreRequested = true
                    let id = self.bookmark?.id ?? .summary
                    #if DEBUG
                    CompanionHomeBuildProbe.scrollToIssued?(id)
                    #endif
                    proxy.scrollTo(id, anchor: self.bookmark?.alignment ?? .top)
                    if self.bookmark == nil { self.cancelRestoration(); return }
                    self.settle(proxy, position: position, generation: generation, previous: nil,
                                stableSamples: 0, corrections: 0, remaining: remaining - 1)
                    return
                }
                if let saved = self.bookmark, let frame = self.frames[saved.id], frame.intersects(self.viewport) {
                    let desired = self.viewport.minY + saved.alignment.y * (self.viewport.height - frame.height)
                    let delta = frame.minY - desired
                    if abs(delta) <= 1 || corrections >= 2 { self.cancelRestoration(); return }
                    // ScrollPosition's y is normalized to the inset content origin, as in
                    // the transcript's existing public-API pixel-position restoration.
                    position.wrappedValue.scrollTo(y: max(0, current.contentOffset.y + current.contentInsets.top + delta))
                    nextCorrections += 1
                    self.settle(proxy, position: position, generation: generation, previous: nil,
                                stableSamples: 0, corrections: nextCorrections, remaining: remaining - 1)
                    return
                }
            }
            self.settle(proxy, position: position, generation: generation, previous: current,
                        stableSamples: stable, corrections: nextCorrections, remaining: remaining - 1)
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
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .scrollView) }) { _, frame in state.record(id, frame: frame) }
                .onDisappear { state.remove(id) }
        } else { content }
    }
}

extension View {
    /// A no-op outside Home, including the Project page and its existing row tests.
    func companionHomeAnchor(_ id: CompanionHomeAnchor) -> some View { modifier(CompanionHomeAnchorMarker(id: id)) }
}
