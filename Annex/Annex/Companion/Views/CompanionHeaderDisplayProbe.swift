#if DEBUG
import SwiftUI
import UIKit
import QuartzCore

/// Opt-in header-fixture instrumentation. No layout correction, result override,
/// private AX API or telemetry setting. One native display callback reads all
/// intended public automation frames synchronously on the application's main actor.
struct CompanionHeaderDisplayProbe: UIViewRepresentable {
    let beginStream: () -> Void
    let streaming: Bool
    func makeUIView(context: Context) -> HeaderProbeButton {
        let button = HeaderProbeButton(frame: .zero)
        button.beginStream = beginStream
        button.streaming = streaming
        return button
    }
    func updateUIView(_ uiView: HeaderProbeButton, context: Context) {
        uiView.beginStream = beginStream; uiView.streaming = streaming
    }
    static func dismantleUIView(_ uiView: HeaderProbeButton, coordinator: ()) {
        uiView.stop(); uiView.beginStream = nil
    }

    struct Control: Codable {
        let identifier: String
        let label: String
        let rect: [Double]
    }
    struct Record: Codable {
        let sequence: Int
        let timestamp: Double
        let captureStarted: Double
        let captureEnded: Double
        let status: String
        let streaming: Bool
        let controls: [String: Control]
        let matchCounts: [String: Int]
        let duplicateNodes: Int
        let scanLimited: Bool
    }
    struct Payload: Codable {
        let version: Int
        let session: String
        let readUptime: Double
        let phase: String
        let latest: Record?
        let records: [Record]?
        let dropped: Int
    }

    @MainActor final class HeaderProbeButton: UIButton {
        private let session = UUID().uuidString
        var beginStream: (() -> Void)?
        var streaming = false
        private var recording = false
        private var link: CADisplayLink?
        private var records: [Record] = []
        private var lastTimestamp = -Double.infinity
        private var sequence = 0
        private var dropped = 0
        private var exported: [Record]?
        private let capacity = 30_000

        override init(frame: CGRect) {
            super.init(frame: frame)
            setImage(UIImage(systemName: "waveform"), for: .normal)
            backgroundColor = .systemOrange
            layer.cornerRadius = 8
            accessibilityIdentifier = "header-display-probe"
            accessibilityLabel = "Start header display stream"
            addTarget(self, action: #selector(exportRecords), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError("Header fixture creates the probe programmatically") }

        override var accessibilityValue: String? {
            get {
                let payload = Payload(version: 1, session: session, readUptime: ProcessInfo.processInfo.systemUptime,
                                      phase: exported != nil ? "exported" : (recording ? "recording" : "ready"), latest: records.last, records: exported, dropped: dropped)
                guard let data = try? JSONEncoder().encode(payload) else { return "HEADER_PROBE_ENCODING_FAILED" }
                return String(data: data, encoding: .utf8)
            }
            set {} // Native getter only; the explicit fixture button exports records.
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil, exported == nil else { return }
            let next = CADisplayLink(target: TickTarget(owner: self), selector: #selector(TickTarget.tick(_:)))
            link = next
            next.add(to: .main, forMode: .common)
        }
        func stop() { link?.invalidate(); link = nil }
        @objc private func exportRecords() {
            if !recording {
                recording = true
                records.removeAll(keepingCapacity: true)
                sequence = 0; dropped = 0; lastTimestamp = -.infinity
                beginStream?()
                accessibilityLabel = "Export header display frames"
            } else {
                exported = records
                stop()
            }
        }

        fileprivate func capture(_ timestamp: Double) {
            guard recording, exported == nil else { return }
            guard records.count < capacity else { dropped += 1; stop(); return }
            sequence += 1
            let captureStarted = ProcessInfo.processInfo.systemUptime
            let duplicate = !timestamp.isFinite || timestamp <= lastTimestamp
            lastTimestamp = max(lastTimestamp, timestamp)
            var matches: [String: [Control]] = [:]
            var duplicates = 0
            var limited = false
            var visited = Set<ObjectIdentifier>()
            var nodes = 0
            let leadingID = ProcessInfo.processInfo.arguments.contains("--companion-header-pushed") ? nil : "header-fixture-menu"
            let intended = ["companion-chat-header", "companion-chat-header-actions"] + (leadingID.map { [$0] } ?? [])

            func walk(_ node: NSObject, depth: Int) {
                guard depth < 40, nodes < 5_000 else { limited = true; return }
                guard visited.insert(ObjectIdentifier(node)).inserted else { duplicates += 1; return }
                nodes += 1
                if node.accessibilityElementsHidden { return }
                if let view = node as? UIView, view.isHidden || view.alpha <= 0 { return }
                let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                let label = node.accessibilityLabel ?? ""
                let isBack = leadingID == nil && label == "Back" && node.accessibilityTraits.contains(.button)
                if intended.contains(identifier) || isBack {
                    let rect = node.accessibilityFrame
                    let key = isBack ? "Back" : identifier
                    matches[key, default: []].append(Control(identifier: identifier, label: label,
                        rect: [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]))
                }
                if let children = node.automationElements ?? node.accessibilityElements {
                    for case let child as NSObject in children { walk(child, depth: depth + 1) }
                } else {
                    let count = node.accessibilityElementCount()
                    if count != NSNotFound && count > 0 {
                        if count > 2_048 { limited = true }
                        else {
                            for index in 0..<count {
                                if let child = node.accessibilityElement(at: index) as? NSObject { walk(child, depth: depth + 1) }
                            }
                        }
                    }
                }
                if let view = node as? UIView { view.subviews.forEach { walk($0, depth: depth + 1) } }
            }
            // Physical traversal finds the real visible bars. Public automation
            // containers then expose native/virtual accessible toolbar controls.
            var bars: [UINavigationBar] = []
            func findBars(_ view: UIView, depth: Int) {
                guard depth < 40 else { limited = true; return }
                guard !view.isHidden, view.alpha > 0, !view.accessibilityElementsHidden else { return }
                if let bar = view as? UINavigationBar { bars.append(bar); return }
                view.subviews.forEach { findBars($0, depth: depth + 1) }
            }
            if let window { findBars(window, depth: 0) }
            if bars.count == 1 { walk(bars[0], depth: 0) }
            let keys = intended + (leadingID == nil ? ["Back"] : [])
            let counts = Dictionary(uniqueKeysWithValues: keys.map { ($0, matches[$0]?.count ?? 0) })
            var controls: [String: Control] = [:]
            for key in keys where counts[key] == 1 { controls[key] = matches[key]![0] }
            let finite = controls.values.allSatisfy { $0.rect.allSatisfy(\.isFinite) && $0.rect[2] > 0 && $0.rect[3] > 0 }
            let status: String
            if duplicate { status = "duplicateTimestamp" }
            else if UIApplication.shared.applicationState != .active { status = "inactive" }
            else if limited { status = "scanLimited" }
            else if bars.count > 1 || counts.values.contains(where: { $0 > 1 }) { status = "ambiguous" }
            else if bars.count != 1 || counts.values.contains(0) { status = "missing" }
            else if !finite { status = "invalidFrame" }
            else { status = "ok" }
            // Non-finite JSON cannot be exported. Keep its explicit invalid status,
            // never substitute old geometry or credit it as a valid sample.
            records.append(Record(sequence: sequence, timestamp: timestamp.isFinite ? timestamp : 0,
                                  captureStarted: captureStarted, captureEnded: ProcessInfo.processInfo.systemUptime, status: status, streaming: streaming,
                                  controls: finite ? controls : [:], matchCounts: counts,
                                  duplicateNodes: duplicates, scanLimited: limited))
        }
    }
    @MainActor private final class TickTarget: NSObject {
        weak var owner: HeaderProbeButton?
        init(owner: HeaderProbeButton) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.capture(link.timestamp)
        }
    }
}
#endif
