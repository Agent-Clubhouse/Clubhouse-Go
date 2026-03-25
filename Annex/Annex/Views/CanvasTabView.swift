import SwiftUI

struct CanvasTabView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedCanvasKey: String?

    private var canvasEntries: [(key: String, label: String, projectId: String, canvas: CanvasState)] {
        store.allCanvasStates.flatMap { entry in
            let tabs = entry.canvas.allCanvasTabs ?? [CanvasTab(id: entry.canvas.canvasId, name: entry.canvas.name ?? "Canvas")]
            let project = entry.instance.projects.first { $0.id == entry.projectId }
            let projectLabel = project?.label ?? entry.projectId
            return tabs.map { tab in
                let key = "\(entry.instance.id.value):\(entry.projectId):\(tab.id)"
                return (key: key, label: "\(projectLabel) — \(tab.name)", projectId: entry.projectId, canvas: entry.canvas)
            }
        }
    }

    private var selectedCanvas: CanvasState? {
        guard let key = selectedCanvasKey else { return canvasEntries.first?.canvas }
        return canvasEntries.first { $0.key == key }?.canvas
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if canvasEntries.isEmpty {
                    emptyState
                } else {
                    if canvasEntries.count > 1 {
                        canvasPicker
                    }
                    if let canvas = selectedCanvas {
                        CanvasRendererView(canvas: canvas, theme: store.theme)
                    }
                }
            }
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    @ViewBuilder
    private var canvasPicker: some View {
        Picker("Canvas", selection: Binding(
            get: { selectedCanvasKey ?? canvasEntries.first?.key ?? "" },
            set: { selectedCanvasKey = $0 }
        )) {
            ForEach(canvasEntries, id: \.key) { entry in
                Text(entry.label).tag(entry.key)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct CanvasRendererView: View {
    let canvas: CanvasState
    let theme: ThemeColors

    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let totalOffset = CGSize(
                width: panOffset.width + CGFloat(canvas.viewport.panX) * zoom,
                height: panOffset.height + CGFloat(canvas.viewport.panY) * zoom
            )

            ZStack(alignment: .topLeading) {
                // Background
                theme.baseColor.ignoresSafeArea()

                // Canvas views
                ForEach(sortedViews) { view in
                    CanvasNodeView(canvasView: view, theme: theme)
                        .position(
                            x: CGFloat(view.position.x) * zoom + totalOffset.width + geo.size.width / 2,
                            y: CGFloat(view.position.y) * zoom + totalOffset.height + geo.size.height / 2
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .gesture(panGesture)
            .gesture(zoomGesture)
        }
    }

    private var sortedViews: [CanvasView] {
        canvas.views.sorted { ($0.zIndex ?? 0) < ($1.zIndex ?? 0) }
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

struct CanvasNodeView: View {
    let canvasView: CanvasView
    let theme: ThemeColors

    var body: some View {
        let w = CGFloat(canvasView.size.width)
        let h = CGFloat(canvasView.size.height)

        VStack(spacing: 4) {
            icon
                .font(.system(size: 14))
                .foregroundStyle(theme.subtext1Color)

            Text(canvasView.displayLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.textColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(width: w, height: h)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch canvasView.type {
        case .agent:
            Image(systemName: "person.circle")
        case .anchor:
            Image(systemName: "mappin.circle")
        case .plugin:
            Image(systemName: "puzzlepiece")
        case .zone:
            Image(systemName: "rectangle.dashed")
        }
    }

    private var backgroundColor: Color {
        switch canvasView.type {
        case .agent: return theme.surface1Color.opacity(0.8)
        case .anchor: return theme.surface0Color.opacity(0.6)
        case .plugin: return theme.surface1Color.opacity(0.7)
        case .zone: return theme.surface0Color.opacity(0.3)
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

#Preview {
    let store = AppStore()
    store.loadMockData()
    return CanvasTabView()
        .environment(store)
}
