import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

private enum DeinitTestLocal { @TaskLocal static var marker = 0 }

/// No OS/runtime guard: CI exercises the same no-current-task release on its installed runtime.
@MainActor final class CompanionDeinitTests: XCTestCase {
    func testRealHoldersReleaseInsideSynchronousTaskLocalWithoutACurrentTask() async {
        print("DEINIT_REGRESSION runtime=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        await withCheckedContinuation { done in
            DispatchQueue.main.async {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
                DeinitTestLocal.$marker.withValue(1) {
                    for _ in 0..<100 {
                        Self.releaseHolders()
                    }
                }
                let source = AnnexTelemetry(); source.setEnabled(true)
                AnnexTelemetry.$current.withValue(source.begin(.navigation)) { Self.releaseHolders() }
                done.resume()
            }
        }
    }

    func testRuntimeWithProviderFlowReleasesInsideTaskLocalWithoutACurrentTask() async {
        await withCheckedContinuation { done in
            DispatchQueue.main.async {
                XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
                DeinitTestLocal.$marker.withValue(1) {
                    Self.releaseHolders(includeProviderFlow: true)
                }
                done.resume()
            }
        }
    }

    func testQAPopulatedStoreOutlivesRuntimeThenReleasesWithoutACurrentTask() async throws {
        var runtime: CompanionRuntime? = CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false)
        var retainedStore = runtime?.store
        weak var previousRuntime = runtime
        weak var previousPresenter = runtime?.feedbackPresenter
        _ = retainedStore?.providerFlow(for: .init(hostID: "qa", projectID: "qa", agentID: "qa"))
        runtime = nil
        for _ in 0..<500 {
            if previousPresenter == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(previousRuntime)
        XCTAssertNil(previousPresenter, "Runtime's MainActor teardown must have completed")
        XCTAssertNotNil(retainedStore)
        await withCheckedContinuation { done in
            DispatchQueue.main.async {
                XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
                print("QA_RETAINED_STORE runtimeReleased=\(previousRuntime == nil) teardownCompleted=\(previousPresenter == nil)")
                DeinitTestLocal.$marker.withValue(1) { retainedStore = nil }
                print("QA_RETAINED_STORE completed")
                done.resume()
            }
        }
    }

    @inline(never) private static func releaseHolders(includeProviderFlow: Bool = false) {
        let queue = CompanionDecisionQueue { _ in }
        let transcript = CompanionTranscriptExpansion()
        let part = transcript.part(messageID: "fixture", index: 0)
        let holder = CompanionStateLifetime { queue }
        XCTAssertTrue(holder.value === queue)
        XCTAssertTrue(part.isOpen(for: "fixture"))
        let bookmark = CompanionReadingBookmark()
        bookmark.position.offset = 123
        bookmark.viewport.frames = ["fixture": 0...100]
        let viewport = CompanionReadingViewport()
        viewport.metrics = .init(offset: 1, contentHeight: 100, containerHeight: 50)
        let projection = CompanionTimelineProjection()
        XCTAssertEqual(projection.rows(for: .init(items: [.notice(id: "fixture", text: "fixture")])).count, 1)
        let service = CompanionLiveService()
        let lifecycle = CompanionLifecycle { active in
            if active { await service.resume() }
            else { await service.suspend() }
        }
        let runtime = CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false)
        if includeProviderFlow {
            let target = CompanionTarget(hostID: "qa", projectID: "qa", agentID: "qa")
            _ = runtime.store.providerFlow(for: target)
            _ = runtime.store.timelineProjection(for: target).rows(for: .init(items: [.notice(id: "qa", text: "qa")]))
            runtime.store.readingBookmark(for: target).viewport.frames = ["qa": 0...100]
            _ = runtime.store.transcriptExpansion(for: target).part(messageID: "qa", index: 0)
        }
        withExtendedLifetime((holder, queue, transcript, part, bookmark, viewport, projection, lifecycle, runtime)) {}
    }

    func testRenderedLifetimeDoesNotConstructDiscardedValues() {
        var count = 0
        let make = { count += 1; return count }
        let controller = UIHostingController(rootView: DeinitLifetimeView(make: make))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        for _ in 0..<20 {
            controller.rootView = DeinitLifetimeView(make: make)
            controller.view.layoutIfNeeded()
        }
        XCTAssertEqual(count, 1)
    }
}

@MainActor private struct DeinitLifetimeView: View {
    @State private var lifetime: CompanionStateLifetime<Int>
    init(make: @escaping () -> Int) { _lifetime = State(initialValue: CompanionStateLifetime(make)) }
    var body: some View { Text("Value \(lifetime.value)") }
}
