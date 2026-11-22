import XCTest

/// #554: with a long name while a reply streams and the transcript scrolls, the header must not reflow. The name
/// stays centred between the side items and the trailing actions pill stays on screen, at every sampled tick.
///
/// Each sample is one accessibility snapshot, about every 70–90ms on the iOS 26.0 simulator, so a reflow shorter
/// than that can slip between samples. Nothing is sampled while a disturbance (drag, push, background) runs; a
/// sample with the name or actions missing counts as a violation, except within 1s after a disturbance.
@MainActor final class CompanionHeaderReflowUITests: ReliableUITestCase {
    private struct Frames { let identity: CGRect; let actions: CGRect; let leading: CGRect? }

    /// Whole-app snapshots that a sample needed because the navigation bar alone lacked one of its elements.
    private var wholeAppSamples = 0

    /// One accessibility snapshot per sample, so a sample is a single moment rather than several queries apart.
    ///
    /// The snapshot is the navigation bar's subtree. Every header element lives there, but a whole-app snapshot also
    /// serialises the streaming transcript; on hosted runners that took 0.3–1s a sample and left 9–35 samples in
    /// the 14s window. When the bar's subtree lacks the name, the actions pill or the leading item (no bar during a
    /// transition, a second bar, a header moved elsewhere), the same sample is retaken from a whole-app snapshot,
    /// so absence still means absent from the whole app, exactly as before.
    private func frames(_ app: XCUIApplication, leadingID: String?) -> Frames? {
        if let bar = try? app.navigationBars.firstMatch.snapshot(), let f = frames(in: bar, leadingID: leadingID) { return f }
        wholeAppSamples += 1
        guard let root = try? app.snapshot() else { return nil }
        return frames(in: root, leadingID: leadingID, requireLeading: false)
    }

    private func frames(in root: XCUIElementSnapshot, leadingID: String?, requireLeading: Bool = true) -> Frames? {
        var found: [String: CGRect] = [:]
        var back: CGRect?
        func walk(_ node: XCUIElementSnapshot) {
            if ["companion-chat-header", "companion-chat-header-actions"].contains(node.identifier) || node.identifier == leadingID {
                found[node.identifier] = node.frame
            }
            if leadingID == nil, back == nil, node.elementType == .button, node.label == "Back" { back = node.frame }
            node.children.forEach(walk)
        }
        walk(root)
        guard let identity = found["companion-chat-header"], let actions = found["companion-chat-header-actions"] else { return nil }
        let leading = leadingID.flatMap { found[$0] } ?? back
        // A bar without the leading item would skip the overlap check, so only the whole app may decide it's absent.
        if requireLeading && leading == nil { return nil }
        return Frames(identity: identity, actions: actions, leading: leading)
    }

    /// Check an already-present route control without paying the waiter's first polling tick.
    /// A slow first query consumes the same original five-second budget; it cannot add time.
    private func existsWithinFiveSeconds(_ element: XCUIElement) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let present = element.exists
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return present || element.waitForExistence(timeout: remaining)
    }

    enum Disturbance { case scroll, pushPop, background }

    private func sampleReflow(_ flags: [String], name: String, disturbance: Disturbance = .scroll) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-header-stream"] + flags,
                            attempts: 1)
        let pushed = flags.contains("--companion-header-pushed")
        if pushed {
            let open = app.buttons["header-fixture-open-chat"]
            XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        }
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        let screen = app.frame
        let leadingID = pushed ? nil : "header-fixture-menu"
        var samples = 0
        var violations: [String] = []
        let started = Date()
        var scrolled = 0 // disturbances so far
        var missing = 0, seenFull = false
        var graceUntil = Date.distantPast
        wholeAppSamples = 0
        while Date().timeIntervalSince(started) < 14 {
            // Disturb the header twice mid-stream, as on the phone.
            if scrolled < 2, Date().timeIntervalSince(started) > Double(4 + 4 * scrolled) {
                switch disturbance {
                case .scroll:
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrolled == 0 ? 0.35 : 0.65))
                    start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset:
                        CGVector(dx: 0.5, dy: scrolled == 0 ? 0.65 : 0.35)))
                case .pushPop:
                    if scrolled == 0 {
                        // Request an early, slow back-swipe; the native route below, not velocity projection,
                        // determines whether the chat actually remained presented.
                        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                                   withVelocity: XCUIGestureVelocity(rawValue: 100), thenHoldForDuration: 0.3)
                        let chat = app.navigationBars.containing(.button, identifier: "companion-chat-header")
                        guard chat.count == 1, chat.element.buttons["Back"].exists,
                              app.buttons["companion-chat-header"].exists else {
                            let hierarchy = XCTAttachment(string: app.debugDescription)
                            hierarchy.name = "Actual route after early back-swipe"; hierarchy.lifetime = .keepAlways; add(hierarchy)
                            XCTFail("The early back-swipe must leave the actual chat route with its header and Back control")
                            return
                        }
                    } else {
                        let back = app.navigationBars.buttons["Back"].firstMatch
                        guard existsWithinFiveSeconds(back), app.buttons["companion-chat-header"].exists else {
                            XCTFail("The chat header and Back control must remain present before the second disturbance")
                            return
                        }
                        back.tap()
                        let open = app.buttons["header-fixture-open-chat"]
                        guard existsWithinFiveSeconds(open), !app.buttons["companion-chat-header"].exists else {
                            XCTFail("Back must actually return to the fixture's root route before reopening")
                            return
                        }
                        open.tap()
                        guard existsWithinFiveSeconds(app.buttons["companion-chat-header"]),
                              app.navigationBars.buttons["Back"].firstMatch.exists else {
                            XCTFail("Reopening must actually restore the pushed chat route")
                            return
                        }
                    }
                case .background:
                    XCUIDevice.shared.press(.home)
                    app.activate()
                    _ = app.buttons["companion-chat-header"].waitForExistence(timeout: 10)
                }
                scrolled += 1
                graceUntil = Date().addingTimeInterval(1)
            }
            guard let f = frames(app, leadingID: leadingID) else {
                // A missing name or actions pill is the #554 symptom itself, once the header has been seen whole.
                if seenFull, Date() > graceUntil {
                    missing += 1
                    let t = String(format: "%.2f", Date().timeIntervalSince(started))
                    violations.append("t=\(t)s name or actions missing from the header")
                }
                continue
            }
            seenFull = true
            samples += 1
            var problems: [String] = []
            if f.actions.maxX > screen.maxX + 0.5 { problems.append("actions past the right edge") }
            if f.identity.maxX + 4 > f.actions.minX { problems.append("identity overlaps actions") }
            if let leading = f.leading, f.identity.minX - 4 < leading.maxX { problems.append("identity overlaps the leading item") }
            if abs(f.identity.midX - screen.midX) > 1 { problems.append("identity off centre") }
            if !problems.isEmpty {
                let t = String(format: "%.2f", Date().timeIntervalSince(started))
                violations.append("t=\(t)s \(problems.joined(separator: ", ")) identity=\(f.identity) actions=\(f.actions) leading=\(String(describing: f.leading))")
                if violations.count == 1 {
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "554 first reflow \(name)"; shot.lifetime = .keepAlways; add(shot)
                }
            }
        }
        let sampled = Date().timeIntervalSince(started)
        print("HEADER_REFLOW \(name) samples=\(samples) missing=\(missing) violations=\(violations.count) wholeApp=\(wholeAppSamples) elapsed=\(String(format: "%.1f", sampled))s")
        violations.prefix(20).forEach { print("HEADER_REFLOW \(name) \($0)") }
        let report = XCTAttachment(string: violations.joined(separator: "\n"))
        report.name = "554 reflow samples \(name)"; report.lifetime = .keepAlways; add(report)
        let settled = XCTAttachment(screenshot: app.screenshot())
        settled.name = "554 after stream \(name)"; settled.lifetime = .keepAlways; add(settled)
        XCTAssertGreaterThanOrEqual(samples, 100, "\(name): too few header samples to judge")
        XCTAssertEqual(missing, 0, "\(name): the name or actions pill was missing in \(missing) samples")
        XCTAssertTrue(violations.isEmpty, "\(name): header reflowed in \(violations.count) of \(samples) samples; first: \(violations.first ?? "")")
    }

    func testOrchestratorNameWithBackDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name", "--companion-header-pushed"], name: "orchestrator back")
    }
    func testOrchestratorNameWithLeadingItemDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name"], name: "orchestrator leading")
    }
    func testOrchestratorNameDoesNotReflowAcrossBackSwipeAndPushWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name", "--companion-header-pushed"], name: "orchestrator push-pop",
                     disturbance: .pushPop)
    }
    func testOrchestratorNameDoesNotReflowAcrossBackgroundingWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name", "--companion-header-pushed"], name: "orchestrator background",
                     disturbance: .background)
    }
    func testLongNameWithBackDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-long-name", "--companion-header-pushed"], name: "long back")
    }
}
