#if DEBUG
import SwiftUI
import UIKit
import ClubhouseTransport

/// Deterministic, offline lifetime probe. Run only in a disposable simulator, without XCTest injection.
/// The private task-local modes deliberately reproduce #218; `cycles` installs no task-local scope.
struct CompanionDeinitProbe: View {
    var body: some View {
        Text("Offline deinit probe")
            .onAppear { DispatchQueue.main.async { CompanionDeinitProbeDriver.start() } }
    }
}

@MainActor private enum CompanionDeinitProbeDriver {
    @TaskLocal static var marker: Int = 0
    private static var started = false
    private static var window: UIWindow?
    private static var controller: UIHostingController<AnyView>?
    private static var store: CompanionStore?
    private static var preferences: CompanionPreferences?
    private static var hosts: [CompanionHost] = []
    private static var cycle = 0
    private static var stage = 0
    static func start() {
        guard !started else { return }; started = true
        let args = ProcessInfo.processInfo.arguments
        let kind = args.drop(while: { $0 != "--deinit-probe" }).dropFirst().first ?? "cycles"
        let local = args.contains("--deinit-private-scope")
        let annex = args.contains("--deinit-annex-scope")
        report("begin kind=\(kind) privateScope=\(local) annexScope=\(annex) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        if kind == "cycles" { nextStage(); return }
        let release = {
            switch kind {
            case "queue": releaseQueue()
            case "expansion": releaseExpansion()
            case "part": releasePart()
            case "holder": releaseHolder()
            default: fatalError("Unknown deinit probe")
            }
        }
        if local { $marker.withValue(1, operation: release) }
        else if annex { AnnexTelemetry.$current.withValue(AnnexTelemetry.shared.begin(.navigation), operation: release) }
        else { release() }
        report("passed kind=\(kind)"); exit(0)
    }
    @inline(never) private static func releaseQueue() {
        let value = CompanionDecisionQueue { _ in }; _ = value.isPending("fixture"); withExtendedLifetime(value) {}
    }
    @inline(never) private static func releasePart() {
        let value = CompanionPartExpansion(); _ = value.isOpen(for: "fixture"); withExtendedLifetime(value) {}
    }
    @inline(never) private static func releaseExpansion() {
        let value = CompanionTranscriptExpansion(); _ = value.part(messageID: "fixture", index: 0); withExtendedLifetime(value) {}
    }
    @inline(never) private static func releaseHolder() {
        let value = CompanionStateLifetime { CompanionDecisionQueue { _ in } }; _ = value.value; withExtendedLifetime(value) {}
    }
    private static func nextStage() {
        report("cycle=\(cycle) stage=\(stage)")
        switch stage {
        case 0:
            let service = CompanionPreviewService(showsDispatcher: true)
            let next = CompanionStore(service: service)
            hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true)
            next.apply(.hosts(hosts)); store = next
            preferences = CompanionPreferences(defaults: UserDefaults(suiteName: "deinit-probe")!)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let w = UIWindow(windowScene: scene)
            let c = UIHostingController(rootView: AnyView(CompanionRootView(store: next, preferences: preferences!, onPair: {}, onSettings: {}, isPreview: true)))
            w.rootViewController = c; w.makeKeyAndVisible(); window = w; controller = c
        case 1: store!.selection = CompanionPreviewService.dispatcherTarget
        case 2:
            hosts[0].connection = .offline
            store!.apply(.resyncRequired(hostID: hosts[0].id)); store!.apply(.hosts(hosts))
        case 3:
            hosts[0].connection = .synchronizing; store!.apply(.hosts(hosts))
            hosts[0].connection = .connected; store!.apply(.hosts(hosts))
        case 4:
            store!.selection = nil
            for _ in 0..<30 {
                controller!.rootView = AnyView(CompanionRootView(store: store!, preferences: preferences!, onPair: {}, onSettings: {}, isPreview: true))
            }
        default:
            window?.isHidden = true; window?.rootViewController = nil
            controller = nil; window = nil; store = nil; preferences = nil
            cycle += 1; stage = -1
            if cycle == 5 { report("passed cycles=5"); exit(0) }
        }
        stage += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nextStage() }
    }
    private static func report(_ text: String) {
        print("DEINIT_PROBE \(text) main=\(Thread.isMainThread) currentTask=\(withUnsafeCurrentTask { $0 != nil }) annexScope=\(AnnexTelemetry.current != nil)")
        fflush(stdout)
    }
}
#endif
