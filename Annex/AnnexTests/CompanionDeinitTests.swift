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

    @inline(never) private static func releaseHolders() {
        let queue = CompanionDecisionQueue { _ in }
        let transcript = CompanionTranscriptExpansion()
        let part = transcript.part(messageID: "fixture", index: 0)
        let holder = CompanionStateLifetime { queue }
        XCTAssertTrue(holder.value === queue)
        XCTAssertTrue(part.isOpen(for: "fixture"))
        withExtendedLifetime((holder, queue, transcript, part)) {}
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
