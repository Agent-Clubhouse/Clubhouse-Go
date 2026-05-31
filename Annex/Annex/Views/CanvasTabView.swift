import SwiftUI

/// How the Canvas tab should present itself for a given number of available
/// canvases. Kept as a pure, view-independent decision so it can be unit-tested
/// and reused by every entry point (GH #87).
enum CanvasPresentation: Equatable {
    /// No canvases available — show the empty state.
    case empty
    /// Exactly one canvas — render it directly ("go straight in").
    case single
    /// More than one canvas — present a selector first.
    case selector

    /// Decide presentation from the number of available canvas entries.
    static func mode(canvasCount: Int) -> CanvasPresentation {
        switch canvasCount {
        case ..<1: return .empty
        case 1: return .single
        default: return .selector
        }
    }
}

/// A single selectable canvas entry. `key` is stable across reloads so it can
/// drive navigation selection.
struct CanvasEntry: Identifiable, Hashable {
    let key: String
    let label: String
    let projectId: String
    let instance: ServerInstance
    let canvas: CanvasState

    var id: String { key }

    static func == (lhs: CanvasEntry, rhs: CanvasEntry) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct CanvasTabView: View {
    @Environment(AppStore.self) private var store
    @State private var expandedView: CanvasView?

    private var canvasEntries: [CanvasEntry] {
        store.allCanvasStates.flatMap { entry -> [CanvasEntry] in
            let tabs = entry.canvas.allCanvasTabs ?? [CanvasTab(id: entry.canvas.canvasId, name: entry.canvas.name ?? "Canvas")]
            let project = entry.instance.projects.first { $0.id == entry.projectId }
            let projectLabel = project?.label ?? entry.projectId
            return tabs.map { tab in
                let key = "\(entry.instance.id.value):\(entry.projectId):\(tab.id)"
                return CanvasEntry(key: key, label: "\(projectLabel) — \(tab.name)", projectId: entry.projectId, instance: entry.instance, canvas: entry.canvas)
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Canvas")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: CanvasEntry.self) { entry in
                    canvasRenderer(for: entry)
                        .navigationTitle(entry.label)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .fullScreenCover(item: $expandedView) { view in
                    CanvasFullScreenView(
                        canvasView: view,
                        instance: canvasEntries.first { $0.canvas.views.contains(view) }?.instance,
                        theme: store.theme
                    )
                }
        }
    }

    /// Drive the tab's presentation purely from how many canvases exist, so the
    /// selector is reached from every entry point when there's more than one.
    @ViewBuilder
    private var content: some View {
        switch CanvasPresentation.mode(canvasCount: canvasEntries.count) {
        case .empty:
            emptyState
        case .single:
            if let entry = canvasEntries.first {
                canvasRenderer(for: entry)
            }
        case .selector:
            canvasSelector
        }
    }

    private func canvasRenderer(for entry: CanvasEntry) -> some View {
        CanvasRendererView(
            canvas: entry.canvas,
            instance: entry.instance,
            theme: store.theme,
            expandedView: $expandedView
        )
    }

    /// List of all available canvases shown when more than one exists, so the
    /// user explicitly chooses which to open instead of being dropped into the
    /// first one (GH #87).
    private var canvasSelector: some View {
        List(canvasEntries) { entry in
            NavigationLink(value: entry) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(store.theme.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label)
                            .font(.body.weight(.medium))
                        Text("\(entry.canvas.views.count) item\(entry.canvas.views.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(store.theme.surface0Color.opacity(0.5))
            .accessibilityIdentifier("canvas-selector-row-\(entry.key)")
        }
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(store.theme.subtext0Color)
            Text("No Canvases")
                .font(.title3.weight(.medium))
            Text("Canvases from connected Clubhouse instances will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas Renderer (pannable/zoomable)

struct CanvasRendererView: View {
    let canvas: CanvasState
    let instance: ServerInstance
    let theme: ThemeColors
    @Binding var expandedView: CanvasView?

    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var didInitialFit = false

    /// Canvas nodes that should be rendered. Group-project nodes are dropped
    /// because their detail view isn't functional on mobile (GH #91).
    private var visibleViews: [CanvasView] {
        canvas.views.filter { !$0.isGroupProject }
    }

    /// Server positions adjusted so node frames don't overlap on the smaller
    /// mobile viewport (GH #88). Computed once per layout from the visible views.
    private var resolvedPositions: [String: CanvasViewPosition] {
        CanvasLayout.resolvePositions(for: visibleViews)
    }

    private func position(for view: CanvasView) -> CanvasViewPosition {
        resolvedPositions[view.id] ?? view.position
    }

    var body: some View {
        GeometryReader { geo in
            let totalOffset = CGSize(
                width: panOffset.width + CGFloat(canvas.viewport.panX) * zoom,
                height: panOffset.height + CGFloat(canvas.viewport.panY) * zoom
            )

            ZStack {
                theme.crustColor.ignoresSafeArea()

                ForEach(sortedViews) { view in
                    let pos = position(for: view)
                    CanvasPlaceholderView(
                        canvasView: view,
                        instance: instance,
                        theme: theme,
                        zoom: zoom
                    )
                    .onTapGesture {
                        expandedView = view
                    }
                    .position(
                        x: CGFloat(pos.x) * zoom + totalOffset.width + geo.size.width / 2,
                        y: CGFloat(pos.y) * zoom + totalOffset.height + geo.size.height / 2
                    )
                }

                // Canvas controls overlay
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        CanvasControlsView(
                            onRecenter: { recenter() },
                            onSizeToFit: { sizeToFit(in: geo.size) },
                            theme: theme
                        )
                        .padding(12)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .gesture(panGesture)
            .gesture(zoomGesture)
            .onAppear {
                // Scale the desktop-sized layout to fit the mobile viewport on
                // first display rather than starting at 1:1 desktop zoom (#88).
                guard !didInitialFit else { return }
                didInitialFit = true
                sizeToFit(in: geo.size, animated: false)
            }
        }
    }

    private func recenter() {
        withAnimation(.easeInOut(duration: 0.3)) {
            panOffset = .zero
            lastPanOffset = .zero
            zoom = 1.0
            lastZoom = 1.0
        }
    }

    private func sizeToFit(in size: CGSize, animated: Bool = true) {
        let views = visibleViews
        guard !views.isEmpty else { return }

        // Calculate bounding box of all views, using the collision-adjusted
        // positions so the fit matches what's actually rendered (#88).
        let positions = resolvedPositions
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity

        for view in views {
            let center = positions[view.id] ?? view.position
            let left = center.x - view.size.width / 2
            let right = center.x + view.size.width / 2
            let top = center.y - view.size.height / 2
            let bottom = center.y + view.size.height / 2
            minX = min(minX, left)
            minY = min(minY, top)
            maxX = max(maxX, right)
            maxY = max(maxY, bottom)
        }

        let contentWidth = maxX - minX
        let contentHeight = maxY - minY
        guard contentWidth > 0, contentHeight > 0 else { return }

        let padding: CGFloat = 40
        let availableWidth = size.width - padding * 2
        let availableHeight = size.height - padding * 2

        let fitZoom = min(
            availableWidth / CGFloat(contentWidth),
            availableHeight / CGFloat(contentHeight),
            2.0
        )
        let clampedZoom = max(0.25, fitZoom)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        let apply = {
            zoom = clampedZoom
            lastZoom = clampedZoom
            panOffset = CGSize(
                width: -CGFloat(centerX) * clampedZoom - CGFloat(canvas.viewport.panX) * clampedZoom,
                height: -CGFloat(centerY) * clampedZoom - CGFloat(canvas.viewport.panY) * clampedZoom
            )
            lastPanOffset = panOffset
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { apply() }
        } else {
            apply()
        }
    }

    private var sortedViews: [CanvasView] {
        visibleViews.sorted { ($0.zIndex ?? 0) < ($1.zIndex ?? 0) }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                panOffset = CGSize(
                    width: lastPanOffset.width + value.translation.width,
                    height: lastPanOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastPanOffset = panOffset
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = max(0.25, min(2.0, lastZoom * value.magnification))
            }
            .onEnded { _ in
                lastZoom = zoom
            }
    }
}

// MARK: - Compact Placeholder (shown on canvas)

struct CanvasPlaceholderView: View {
    let canvasView: CanvasView
    let instance: ServerInstance
    let theme: ThemeColors
    let zoom: CGFloat

    private var agent: DurableAgent? {
        guard let agentId = canvasView.agentId else { return nil }
        return instance.durableAgent(byId: agentId)
    }

    var body: some View {
        let w = CGFloat(canvasView.size.width) * zoom
        let h = CGFloat(canvasView.size.height) * zoom
        let placeholderSize = min(w, h) * 0.6

        VStack(spacing: 4 * zoom) {
            Group {
                switch canvasView.type {
                case .agent:
                    if let agent {
                        AgentAvatarView(
                            color: agent.color ?? "gray",
                            status: agent.status,
                            state: agent.detailedStatus?.state,
                            name: agent.name,
                            iconData: instance.agentIcons[agent.id],
                            size: placeholderSize
                        )
                    } else {
                        placeholderIcon("person.circle.fill", size: placeholderSize)
                    }

                case .anchor:
                    placeholderIcon("mappin.circle.fill", size: placeholderSize)

                case .plugin:
                    placeholderIcon("puzzlepiece.fill", size: placeholderSize)

                case .zone:
                    EmptyView()
                }
            }

            if zoom > 0.5 {
                Text(canvasView.displayLabel)
                    .font(.system(size: max(9, 11 * zoom), weight: .medium))
                    .foregroundStyle(theme.textColor)
                    .lineLimit(1)
            }
        }
        .frame(width: w, height: h)
        .background(
            RoundedRectangle(cornerRadius: 10 * zoom)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 10 * zoom)
                        .strokeBorder(borderColor, lineWidth: canvasView.type == .zone ? 1 : 1.5)
                )
        )
        // Subtle "tap to view" affordance on agent nodes (#89): a small chevron
        // badge in the corner hints that the node opens a detail view on tap.
        // Overlaid (not in the layout stack) so it doesn't affect node sizing.
        .overlay(alignment: .bottomTrailing) {
            if canvasView.type == .agent, agent != nil, zoom > 0.45 {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: max(10, 13 * zoom)))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.crustColor, theme.accentColor)
                    .padding(4 * zoom)
                    .accessibilityLabel("Tap to view agent")
            }
        }
        .contentShape(Rectangle())
    }

    private func placeholderIcon(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.6))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
    }

    private var iconColor: Color {
        switch canvasView.type {
        case .agent: return theme.accentColor
        case .anchor: return theme.subtext1Color
        case .plugin: return theme.linkColor
        case .zone: return theme.subtext0Color
        }
    }

    private var backgroundColor: Color {
        switch canvasView.type {
        case .agent: return theme.surface1Color.opacity(0.8)
        case .anchor: return theme.surface0Color.opacity(0.6)
        case .plugin: return theme.surface1Color.opacity(0.7)
        case .zone: return theme.surface0Color.opacity(0.15)
        }
    }

    private var borderColor: Color {
        switch canvasView.type {
        case .agent: return theme.accentColor.opacity(0.5)
        case .anchor: return theme.subtext0Color.opacity(0.3)
        case .plugin: return theme.linkColor.opacity(0.4)
        case .zone: return theme.subtext0Color.opacity(0.2)
        }
    }
}

// MARK: - Full-Screen View (shown on tap)

struct CanvasFullScreenView: View {
    let canvasView: CanvasView
    let instance: ServerInstance?
    let theme: ThemeColors
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var agent: DurableAgent? {
        guard let agentId = canvasView.agentId, let instance else { return nil }
        return instance.durableAgent(byId: agentId)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch canvasView.type {
                case .agent:
                    if let agent {
                        AgentDetailView(agent: agent)
                    } else {
                        placeholderContent(icon: "person.circle", label: canvasView.displayLabel)
                    }

                case .anchor:
                    placeholderContent(icon: "mappin.circle", label: canvasView.displayLabel)

                case .plugin:
                    pluginContent

                case .zone:
                    placeholderContent(icon: "rectangle.dashed", label: canvasView.displayLabel)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pluginContent: some View {
        // Group-project nodes are filtered out of the canvas (GH #91), so they
        // never reach this detail view. Remaining plugin nodes show a generic
        // placeholder.
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "puzzlepiece.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(theme.linkColor)
            Text(canvasView.displayLabel)
                .font(.title3.weight(.medium))
            if let widgetType = canvasView.pluginWidgetType {
                Text("Plugin: \(widgetType)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.baseColor)
    }

    private func placeholderContent(icon: String, label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(theme.subtext0Color)
            Text(label)
                .font(.title3.weight(.medium))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.baseColor)
    }
}

// MARK: - Canvas Controls

private struct CanvasControlsView: View {
    let onRecenter: () -> Void
    let onSizeToFit: () -> Void
    let theme: ThemeColors

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSizeToFit) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
            }
            .help("Size to Fit")

            Button(action: onRecenter) {
                Image(systemName: "scope")
                    .font(.system(size: 14, weight: .medium))
            }
            .help("Recenter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(theme.surface1Color.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        )
        .foregroundStyle(theme.textColor)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return CanvasTabView()
        .environment(store)
}
