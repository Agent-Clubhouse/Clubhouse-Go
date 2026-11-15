import SwiftUI
import XCTest
import Darwin
@testable import ClubhouseGo

/// Component-level timing probe; the app's animated navigation is covered separately by UI tests.
@MainActor final class CompanionWakeFocusTests: XCTestCase {
    @MainActor @Observable final class Presentation {
        nonisolated deinit {}
        var showing = false
    }

    private struct SheetHost: View {
        @Bindable var presentation: Presentation
        let store: CompanionStore
        let project: CompanionProjectTarget
        let appeared: () -> Void

        var body: some View {
            Text("Wake presentation host")
                .sheet(isPresented: $presentation.showing) {
                    CompanionWakeSheet(store: store, project: project, onWake: { _, _ in })
                        .onAppear(perform: appeared)
                }
        }
    }

    @MainActor private final class Host: UIHostingController<SheetHost> {
        var appeared: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
            appeared = nil
        }
    }

    private func findInput(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView { return view }
        return view.subviews.lazy.compactMap { self.findInput(in: $0) }.first
    }

    func testBlockedStdoutNeverDelaysWakeDiagnosticProducers() async throws {
        let trace = CompanionDiagnosticTrace(wake: true, automaticallyStart: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let input = UITextView()
        input.accessibilityIdentifier = "wake-message"
        controller.view.addSubview(input)
        window.makeKeyAndVisible()
        defer {
            CompanionWakeFocusDiagnostics.end()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let readFD = descriptors[0], writeFD = descriptors[1]
        let savedStdout = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedStdout, 0)
        defer {
            XCTAssertEqual(dup2(savedStdout, STDOUT_FILENO), STDOUT_FILENO)
            Darwin.close(savedStdout)
            Darwin.close(writeFD)
            Darwin.close(readFD)
        }
        let flags = fcntl(writeFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(writeFD, F_SETFL, flags | O_NONBLOCK), 0)
        let fill = [UInt8](repeating: 120, count: 4096)
        while fill.withUnsafeBytes({ Darwin.write(writeFD, $0.baseAddress, $0.count) }) > 0 {}
        XCTAssertEqual(errno, EAGAIN)
        XCTAssertEqual(fcntl(writeFD, F_SETFL, flags & ~O_NONBLOCK), 0)
        XCTAssertEqual(fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK), 0)
        XCTAssertEqual(dup2(writeFD, STDOUT_FILENO), STDOUT_FILENO)
        let rescued = DispatchGroup()
        rescued.enter()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while Darwin.read(readFD, &bytes, bytes.count) > 0 {}
            rescued.leave()
        }
        let started = ContinuousClock.now
        CompanionWakeFocusDiagnostics.begin(trace: trace)
        CompanionWakeFocusDiagnostics.snapshot(.focusRequested(true))
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 500, width: 400, height: 300)])
        for _ in 0..<70 { CompanionWakeFocusDiagnostics.snapshot(.focusChanged(true)) }
        CompanionWakeFocusDiagnostics.end()
        let duration = started.duration(to: .now)
        let buffered = trace.snapshot.buffered
        await trace.drain()
        XCTAssertEqual(dup2(savedStdout, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertLessThan(duration, .milliseconds(250), "Blocked stdout must not stall Wake appearance or native focus/keyboard producers")
        XCTAssertEqual(buffered, 64, "The per-presentation sample cap remains enforced")
        XCTAssertEqual(trace.snapshot.outputAvailable, false, "A pipe has no independent PTY; never fall back to blocking stdout")
        XCTAssertEqual(trace.snapshot.dropped, 64)
        XCTAssertEqual(trace.snapshot.written, 0)
        await withCheckedContinuation { continuation in
            rescued.notify(queue: .global()) { continuation.resume() }
        }
        await trace.stop()
    }

    func testNativeEditingRecordRetainsOnlyClosedMetadata() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = url.path
        let trace = CompanionDiagnosticTrace(wake: true, automaticallyStart: false,
            openOutput: { Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NONBLOCK | O_CLOEXEC, 0o600) })
        defer { try? FileManager.default.removeItem(at: url) }
        let input = UITextView()
        input.accessibilityIdentifier = "wake-message"
        input.text = "Private draft must not enter diagnostics"
        CompanionWakeFocusDiagnostics.begin(trace: trace)
        NotificationCenter.default.post(name: UITextView.textDidBeginEditingNotification, object: input)
        CompanionWakeFocusDiagnostics.end()
        await trace.drain()
        await trace.stop()
        let data = try Data(contentsOf: url)
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(output.contains(input.text))
        let records = try output.split(separator: "\n").map { line in
            let json = try XCTUnwrap(String(line).data(using: .utf8))
            let payload = json.dropFirst("WAKE_FOCUS ".utf8.count)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any])
        }
        let editing = try XCTUnwrap(records.first {
            let event = $0["event"] as? [String: Any]
            let notification = event?["notification"] as? [String: Any]
            return notification?["_0"] as? String == "viewBegan"
        })
        let captured = try XCTUnwrap(editing["eventInput"] as? [String: Any])
        XCTAssertEqual(captured["kind"] as? String, "textView")
        XCTAssertEqual(captured["wakeIdentifier"] as? Bool, true)
        XCTAssertEqual(captured["inWindow"] as? Bool, false)
        XCTAssertEqual(captured["firstResponder"] as? Bool, false)
        XCTAssertEqual(Set(captured.keys), ["kind", "wakeIdentifier", "inWindow", "firstResponder", "hidden", "frame"])
        XCTAssertEqual(trace.snapshot.dropped, 0)
        XCTAssertEqual(trace.snapshot.written, records.count)
    }

    func testNativeAutofocusDuringNormalAndSlowSheetPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for speed: Float in [1, 0.1] {
            let store = CompanionStore(service: CompanionPreviewService())
            store.apply(.hosts(CompanionPreviewService.hosts(now: .now)))
            let target = CompanionPreviewService.target
            let project = CompanionProjectTarget(hostID: target.hostID, projectID: target.projectID)
            let presentation = Presentation()
            let appeared = expectation(description: "Production Wake sheet appeared")
            let mounted = expectation(description: "Presenter finished appearing")
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.layer.speed = speed
            let controller = Host(rootView: SheetHost(presentation: presentation, store: store, project: project,
                appeared: { appeared.fulfill() }))
            controller.appeared = { mounted.fulfill() }
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.layer.speed = 1
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
                store.shutdown()
            }
            await fulfillment(of: [mounted], timeout: 5)
            let started = ContinuousClock.now
            presentation.showing = true
            await fulfillment(of: [appeared], timeout: 15)
            let sheet = try XCTUnwrap(controller.presentedViewController)
            let input = try XCTUnwrap(findInput(in: sheet.view))
            print("WAKE_COMPONENT speed=\(speed) event=appeared elapsed=\(started.duration(to: .now)) inWindow=\(input.window === window) firstResponder=\(input.isFirstResponder) presenting=\(sheet.isBeingPresented) transitionDuration=\(sheet.transitionCoordinator?.transitionDuration ?? 0)")
            await fulfillment(of: [
                expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: input),
                expectation(for: NSPredicate { _, _ in !sheet.isBeingPresented }, evaluatedWith: sheet)
            ], timeout: 15)
            let elapsed = started.duration(to: .now)
            print("WAKE_COMPONENT speed=\(speed) event=presented elapsed=\(elapsed) inWindow=\(input.window === window) firstResponder=\(input.isFirstResponder)")
            XCTAssertTrue(input.window === window)
            XCTAssertTrue(input.isFirstResponder)
            if speed < 1 {
                XCTAssertGreaterThan(elapsed, .seconds(2), "The slow scenario must actually slow presentation")
            }
            presentation.showing = false
            await fulfillment(of: [
                expectation(for: NSPredicate { _, _ in controller.presentedViewController == nil }, evaluatedWith: controller)
            ], timeout: 15)
        }
    }
}
