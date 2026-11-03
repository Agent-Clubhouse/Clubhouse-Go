// Offline, opt-in Release profiling fixture. Never included in an app target.
import SwiftUI
import UIKit
import os
import ClubhouseTransport

@main struct ClubhouseGoApp: App {
    var body: some Scene { WindowGroup { NavigationStack {
        CompanionConversationView(store: TypingProfile.store, agent: TypingProfile.agent)
    }.task { await TypingProfile.run() } } }
}

@MainActor enum TypingProfile {
    static let service = CompanionPreviewService(showsDispatcher: true)
    static let store = CompanionStore(service: service)
    static let target = CompanionPreviewService.dispatcherTarget
    static let agent = CompanionPreviewService.hosts(now: .now, dispatcher: true)[0].dispatcher!.agent!
    static var bodyCount = 0
    static var timelineCount = 0
    static var display: CADisplayLink?
    static let displayTarget = DisplayTarget()
    static var gaps: [Double] = []
    static var lastFrame: Double = 0
    static let signposter = OSSignposter(subsystem: "com.clubhouse.go.profile", category: .pointsOfInterest)
    static var didRun = false
    static func bodyPass() { bodyCount += 1 }
    static func timelinePass() { timelineCount += 1 }
    static func run() async {
        guard !didRun else { return }; didRun = true
        store.apply(.hosts(CompanionPreviewService.hosts(now: .now, dispatcher: true)))
        await store.load(target)
        let items: [CompanionTimelineItem] = (1...128).map { i in
            if i % 4 == 0 { return .message(.init(id: "history-\(i)", role: .user,
                text: "[FROM:River] Update", source: "mcp", routed: [.init(sender: .init(agentID: "river", name: "River"), text: i % 16 == 0 ? String(repeating: "Long **folded** delivery.\n\n", count: 100) : "Routed update.")])) }
            return .message(.init(id: "history-\(i)", role: i % 2 == 0 ? .assistant : .user,
                text: "A short **formatted** chat message."))
        }
        store.apply(.timeline(target, items: items, sequence: 5_000, reset: true, sessionID: "fixture"))
        try? await Task.sleep(for: .seconds(10))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
              let input = find(window) else { print("TYPING_PROFILE missingInput=1"); return }
        input.becomeFirstResponder()
        try? await Task.sleep(for: .seconds(2))
        display = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.frame(_:)))
        display?.add(to: .main, forMode: .common)
        AnnexTelemetry.shared.setEnabled(true)
        var sequence = 5_000
        let staggered = ProcessInfo.processInfo.arguments.contains("--staggered")
        for phase in 0..<4 {
            store.drafts[target] = ""
            try? await Task.sleep(for: .seconds(1))
            _ = AnnexTelemetry.shared.drainSummaries()
            bodyCount = 0; timelineCount = 0; gaps = []; lastFrame = 0
            var insertion: [Double] = [], scheduling: [Double] = []
            let state = signposter.beginInterval("TypingPhase", "phase=\(phase)")
            let started = ProcessInfo.processInfo.systemUptime
            let typing = phase == 1 || phase == 3, streaming = phase >= 2
            let streamingTask: Task<Void, Never>? = streaming && staggered ? Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(62))
                for tick in 0..<50 {
                    sequence += 1
                    store.apply(.upsert(target, .message(.init(id: "stream", role: .assistant,
                        text: String(repeating: "Streaming **reply**. ", count: tick * 2 + (phase == 3 ? 130 : 30)), isStreaming: true)), sequence: sequence))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            } : nil
            for tick in 0..<100 {
                if streaming && !staggered && tick % 2 == 0 {
                    sequence += 1
                    store.apply(.upsert(target, .message(.init(id: "stream", role: .assistant,
                        text: String(repeating: "Streaming **reply**. ", count: tick + 30), isStreaming: true)), sequence: sequence))
                }
                if typing {
                    let stamp = ProcessInfo.processInfo.systemUptime
                    let interval = signposter.beginInterval("NativeInsert")
                    input.insertText("x")
                    signposter.endInterval("NativeInsert", interval)
                    insertion.append((ProcessInfo.processInfo.systemUptime - stamp) * 1000)
                    DispatchQueue.main.async { scheduling.append((ProcessInfo.processInfo.systemUptime - stamp) * 1000) }
                }
                try? await Task.sleep(for: .milliseconds(125))
            }
            await streamingTask?.value
            signposter.endInterval("TypingPhase", state)
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            func p95(_ xs: [Double]) -> Double { let sorted = xs.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
            print("TYPING_PROFILE phase=\(phase) staggered=\(staggered ? 1 : 0) elapsedMs=\(elapsed) body=\(bodyCount) timeline=\(timelineCount) inputs=\(insertion.count) retained=\(store.conversation(for: target).items.count) draftUnits=\(store.drafts[target]?.utf16.count ?? 0) nativeUnits=\(input.text.utf16.count) insertTotalMs=\(insertion.reduce(0,+)) insertP95Ms=\(p95(insertion)) schedulingP95Ms=\(p95(scheduling)) schedulingMaxMs=\(scheduling.max() ?? 0) frameCount=\(gaps.count) gapP95Ms=\(p95(gaps)) gapMaxMs=\(gaps.max() ?? 0) gapsOver50=\(gaps.filter{$0>50}.count)")
            for summary in AnnexTelemetry.shared.drainSummaries() {
                print("TYPING_SUMMARY phase=\(phase) kind=\(summary.operation.rawValue) count=\(summary.count) totalMs=\(summary.totalMs) maxMs=\(summary.maxMs)")
            }
        }
        display?.invalidate(); display = nil
        let counter = AnnexTelemetry()
        for enabled in [false, true] {
            counter.setEnabled(enabled)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100_000 { counter.measurePerformance(.timelineBuild, messageCount: 128) {} }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            print("TYPING_OVERHEAD enabled=\(enabled ? 1 : 0) calls=100000 totalMs=\(ms) summaries=\(counter.drainSummaries().count)")
        }
        print("TYPING_PROFILE complete=1")
        fflush(nil)
    }
    static func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first }
    final class DisplayTarget: NSObject {
        @objc func frame(_ link: CADisplayLink) {
            if lastFrame > 0 { gaps.append((link.timestamp - lastFrame) * 1000) }
            lastFrame = link.timestamp
        }
    }
}
