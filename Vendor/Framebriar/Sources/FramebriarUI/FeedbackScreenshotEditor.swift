#if os(iOS)
import SwiftUI
import UIKit

/// Full-screen zoom and markup for a screenshot: pinch, pan and double-tap under Move, a freehand pen in four
/// colors, and an opaque redaction rectangle. Present it full screen. Works on its own copy: Cancel leaves the
/// caller's image alone, and Done hands back new flattened PNG bytes within the report limits. If the marks are
/// what it opened with, Done has nothing to do and calls `onCancel`. A shake is ignored while this is on screen.
///
/// **The rule for a custom composer.** To keep edits reversible, hold the source and its marks in view memory
/// only, pass them back in here, and send only the flattened bytes. On the first Send tap, drop both and make
/// the flattened bytes the new source, passing `editsAreFinal: true` from then on if there were any edits, so
/// a failed save can't bring back what was covered. Never put the source or marks in a draft, a report or a log.
public struct FeedbackScreenshotEditor: View {
    enum Tool: Hashable { case move, pen, redact }

    private let png: Data
    private let openedWith: [ScreenshotMark]
    private let editsAreFinal: Bool
    private let onDone: @MainActor (Data, [ScreenshotMark]) -> Void
    private let onCancel: @MainActor () -> Void
    @State private var image: CGImage?
    @State private var marks: [ScreenshotMark]
    @State private var tool = Tool.move
    @State private var ink = ScreenshotInk.red
    @State private var confirmClear = false
    @State private var flattening = false
    @State private var problem: String?

    /// - Parameters:
    ///   - onDone: receives the flattened PNG. Replace your copy with it and drop the original.
    ///   - onCancel: the caller's image is unchanged.
    public init(png: Data, onDone: @escaping @MainActor (Data) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.init(png: png, marks: [], onDone: { flattened, _ in onDone(flattened) }, onCancel: onCancel)
    }

    /// - Parameters:
    ///   - png: the source, which the marks are drawn on and which Clear edits goes back to.
    ///   - marks: from an earlier `onDone`, to keep editing them. They can be undone or cleared here.
    ///   - editsAreFinal: `png` already has edits flattened into it, so the wording doesn't promise the original.
    ///   - onDone: receives the flattened PNG and the marks in it. With no marks left, that's `png` re-encoded.
    ///   - onCancel: the caller's image and marks are unchanged.
    public init(png: Data, marks: [ScreenshotMark], editsAreFinal: Bool = false, onDone: @escaping @MainActor (Data, [ScreenshotMark]) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.png = png; openedWith = marks; self.editsAreFinal = editsAreFinal; self.onDone = onDone; self.onCancel = onCancel
        _marks = State(initialValue: marks)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image {
                    ScreenshotCanvas(image: image, tool: tool, ink: ink, marks: marks) { marks.append($0) }
                        .background(Color(white: 0.15)).allowsHitTesting(!flattening)
                } else {
                    Spacer()
                }
                controls
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(flattening).accessibilityIdentifier("framebriar-editor-cancel")
                }
                ToolbarItem(placement: .principal) {
                    Button("Undo") { _ = marks.popLast() }.disabled(marks.isEmpty || flattening).accessibilityIdentifier("framebriar-editor-undo")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if flattening { ProgressView() } else {
                        Button("Done") { finish() }.disabled(image == nil).accessibilityIdentifier("framebriar-editor-done")
                    }
                }
            }
        }
        .onAppear {
            ShakeWindowInspector.editorsOpen += 1
            if image == nil {
                image = ScreenshotFlattener.upright(png)
                if image == nil { problem = FeedbackDisclosure.editorCannotOpen }
            }
        }
        .onDisappear { ShakeWindowInspector.editorsOpen -= 1 }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tool", selection: $tool) {
                Text("Move").tag(Tool.move)
                Text("Pen").tag(Tool.pen)
                Text("Redact").tag(Tool.redact)
            }
            .pickerStyle(.segmented).disabled(flattening).accessibilityIdentifier("framebriar-editor-tool")
            if tool == .pen { inkPicker }
            Text(FeedbackDisclosure.editorHint(tool)).font(.caption).accessibilityIdentifier("framebriar-editor-hint")
            Button("Clear edits", role: .destructive) { confirmClear = true }
                .disabled(marks.isEmpty || flattening).accessibilityIdentifier("framebriar-editor-clear")
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("framebriar-editor-error") }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .confirmationDialog(FeedbackDisclosure.clearEditsConfirmation(editsAreFinal: editsAreFinal), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear edits", role: .destructive) { marks = [] }.accessibilityIdentifier("framebriar-editor-clear-confirm")
        }
    }

    private var inkPicker: some View {
        HStack(spacing: 16) {
            ForEach(ScreenshotInk.allCases, id: \.self) { choice in
                Button { ink = choice } label: {
                    Circle().fill(choice.color).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(Color.primary, lineWidth: ink == choice ? 2 : 0))
                }
                .buttonStyle(.plain).disabled(flattening)
                .accessibilityLabel(choice.name).accessibilityAddTraits(ink == choice ? .isSelected : [])
                .accessibilityIdentifier("framebriar-editor-ink-\(choice.name.lowercased())")
            }
        }
    }

    private func finish() {
        guard marks != openedWith else { onCancel(); return }
        flattening = true; problem = nil
        let png = png, marks = marks
        Task {
            let flattened = await Task.detached(priority: .userInitiated) { ScreenshotFlattener.flatten(png, marks: marks) }.value
            flattening = false
            if let flattened { onDone(flattened, marks) } else { problem = FeedbackDisclosure.editorCannotFinish }
        }
    }
}

extension ScreenshotInk {
    var name: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .white: "White"
        }
    }
    var color: Color { Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255) }
}

extension FeedbackDisclosure {
    static func editorHint(_ tool: FeedbackScreenshotEditor.Tool) -> String {
        switch tool {
        case .move: editorMoveHint
        case .pen: editorPenHint
        case .redact: editorRedactHint
        }
    }
}

private struct ScreenshotCanvas: UIViewRepresentable {
    let image: CGImage
    let tool: FeedbackScreenshotEditor.Tool
    let ink: ScreenshotInk
    let marks: [ScreenshotMark]
    let onMark: @MainActor (ScreenshotMark) -> Void

    func makeUIView(context: Context) -> ScreenshotCanvasView { ScreenshotCanvasView(image: image) }
    func updateUIView(_ view: ScreenshotCanvasView, context: Context) {
        view.onMark = onMark
        view.tool = tool
        view.ink = ink
        view.marks = marks
    }
}

/// Everything inside `content` is in source pixels, so a mark's position needs no conversion and survives
/// zoom and rotation. Marks are vector layers because a bitmap the size of the image would cost hundreds of MB.
private final class ScreenshotCanvasView: UIScrollView, UIScrollViewDelegate {
    var onMark: (@MainActor (ScreenshotMark) -> Void)?
    var tool = FeedbackScreenshotEditor.Tool.move { didSet { if tool != oldValue { applyTool() } } }
    var ink = ScreenshotInk.red
    var marks: [ScreenshotMark] = [] { didSet { if marks != oldValue { redraw(); updateValue() } } }

    private let content = UIView()
    private let penLayer = CALayer(), redactionLayer = CALayer()
    private let doubleTap = UITapGestureRecognizer()
    private let draw = UILongPressGestureRecognizer()
    private var fittedTo = CGSize.zero
    private var stroke: [CGPoint] = []
    private var strokeWidth: CGFloat = 1
    private var anchor = CGPoint.zero
    private var live: CALayer?

    init(image: CGImage) {
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        bouncesZoom = true
        let picture = UIImageView(image: UIImage(cgImage: image, scale: 1, orientation: .up))
        content.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        picture.frame = content.bounds
        content.addSubview(picture)
        penLayer.frame = content.bounds; redactionLayer.frame = content.bounds
        content.layer.addSublayer(penLayer); content.layer.addSublayer(redactionLayer)
        addSubview(content)
        contentSize = content.bounds.size

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(toggleZoom(_:)))
        addGestureRecognizer(doubleTap)
        draw.minimumPressDuration = 0
        draw.allowableMovement = .greatestFiniteMagnitude
        draw.addTarget(self, action: #selector(drawing(_:)))
        addGestureRecognizer(draw)

        isAccessibilityElement = true
        accessibilityIdentifier = "framebriar-editor-canvas"
        accessibilityLabel = "Screenshot"
        applyTool(); updateValue()
    }
    required init?(coder: NSCoder) { nil }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center(); updateValue() }

    /// A new size (first layout or rotation) refits, keeping any zoom the user chose.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != fittedTo else { return }
        let wasFitted = fittedTo == .zero || zoomScale <= minimumZoomScale + 0.0001
        fittedTo = bounds.size
        let fit = min(bounds.width / content.bounds.width, bounds.height / content.bounds.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 8, 4)
        zoomScale = wasFitted ? fit : min(max(zoomScale, fit), maximumZoomScale)
        center()
        contentOffset = CGPoint(x: min(max(contentOffset.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width)),
                                y: min(max(contentOffset.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height)))
        updateValue()
    }

    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    /// Only Move pans and zooms and only the other tools draw, so the two never compete for a touch.
    private func applyTool() {
        let moving = tool == .move
        isScrollEnabled = moving
        pinchGestureRecognizer?.isEnabled = moving
        doubleTap.isEnabled = moving
        draw.isEnabled = !moving
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale + 0.0001 else { setZoomScale(minimumZoomScale, animated: true); return }
        // Fill the short side, which is what makes a tall screenshot readable.
        let fill = max(bounds.width / content.bounds.width, bounds.height / content.bounds.height)
        let scale = min(maximumZoomScale, max(fill, minimumZoomScale * 2.5))
        let at = gesture.location(in: content)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func drawing(_ gesture: UILongPressGestureRecognizer) {
        let at = gesture.location(in: content)
        let point = CGPoint(x: min(max(at.x, 0), content.bounds.width), y: min(max(at.y, 0), content.bounds.height))
        switch gesture.state {
        case .began:
            anchor = point; stroke = [point]
            strokeWidth = ScreenshotFlattener.penWidth(zoomScale: zoomScale, fitScale: minimumZoomScale)
            updateLive(point)
        case .changed:
            if let last = stroke.last, hypot(point.x - last.x, point.y - last.y) >= 1 / zoomScale { stroke.append(point) }
            updateLive(point)
        case .ended:
            clearLive()
            if tool == .pen {
                onMark?(.pen(points: stroke, width: strokeWidth, ink: ink))
            } else if tool == .redact {
                let rect = rectangle(to: point)
                // A stray tap isn't a redaction. Two points on screen is thin enough to cover a line of text at any zoom.
                if rect.width * zoomScale >= 2, rect.height * zoomScale >= 2 { onMark?(.redaction(rect)) }
            }
        default:
            clearLive()
        }
    }

    private func rectangle(to point: CGPoint) -> CGRect {
        CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
    }
    private func updateLive(_ point: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        live?.removeFromSuperlayer()
        let layer = tool == .pen ? Self.layer(for: .pen(points: stroke, width: strokeWidth, ink: ink)) : Self.layer(for: .redaction(rectangle(to: point)), in: content.bounds.size)
        (tool == .pen ? penLayer : redactionLayer).addSublayer(layer)
        live = layer
    }
    private func clearLive() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        live?.removeFromSuperlayer(); live = nil
    }

    /// Pen below redactions, the same order the flattener uses, so what's shown is what's sent.
    private func redraw() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        penLayer.sublayers = nil; redactionLayer.sublayers = nil
        for mark in marks {
            let layer = Self.layer(for: mark, in: content.bounds.size)
            if case .pen = mark { penLayer.addSublayer(layer) } else { redactionLayer.addSublayer(layer) }
        }
    }
    private static func layer(for mark: ScreenshotMark, in size: CGSize = .zero) -> CALayer {
        switch mark {
        case .pen(let points, let width, let ink):
            let path = UIBezierPath()
            if let first = points.first {
                path.move(to: first)
                if points.count == 1 { path.addLine(to: first) }
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            let shape = CAShapeLayer()
            shape.path = path.cgPath; shape.fillColor = nil; shape.strokeColor = UIColor(red: CGFloat(ink.rgb.red) / 255, green: CGFloat(ink.rgb.green) / 255, blue: CGFloat(ink.rgb.blue) / 255, alpha: 1).cgColor
            shape.lineWidth = width; shape.lineCap = .round; shape.lineJoin = .round
            return shape
        case .redaction(let rect):
            let layer = CALayer()
            layer.backgroundColor = UIColor.black.cgColor
            layer.frame = ScreenshotFlattener.coveredPixels(rect, width: Int(size.width), height: Int(size.height)) ?? .zero
            return layer
        }
    }

    private func updateValue() {
        let percent = minimumZoomScale > 0 ? Int((zoomScale / minimumZoomScale * 100).rounded()) : 100
        accessibilityValue = "\(marks.count) \(marks.count == 1 ? "mark" : "marks"), \(percent)% zoom"
    }
}
#endif
