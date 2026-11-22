import XCTest

/// #554: with a long name while a reply streams and the transcript scrolls, the header must not reflow. The name
/// stays centred between the side items and the trailing actions pill stays on screen, at every sampled tick.
///
/// Each sample is one accessibility snapshot, about every 70–90ms on the iOS 26.0 simulator, so a reflow shorter
/// than that can slip between samples. Nothing is sampled while a disturbance (drag, push, background) runs; a
/// sample with the name or actions missing counts as a violation, except within 1s after a disturbance.
@MainActor final class CompanionHeaderReflowUITests: ReliableUITestCase {
    private struct Frames { let identity: CGRect; let actions: CGRect; let leading: CGRect? }

    private struct SampleCosts { var queries = 0; var querySeconds = 0.0; var walkSeconds = 0.0 }

    /// Walk one immutable snapshot; never combine frames from separate element queries.
    private func frames(in root: XCUIElementSnapshot, leadingID: String?) -> Frames? {
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
        return Frames(identity: identity, actions: actions, leading: leadingID.flatMap { found[$0] } ?? back)
    }

    /// The real identity, actions and fixture/Back item are toolbar descendants.
    /// `.element` requires a unique navigation bar; a failed/missing query is still
    /// a missing sample, never cached geometry or a whole-app fallback.
    private func frames(_ app: XCUIApplication, leadingID: String?, costs: inout SampleCosts) -> Frames? {
        costs.queries += 1
        let started = ProcessInfo.processInfo.systemUptime
        let root = try? app.navigationBars.element.snapshot()
        let captured = ProcessInfo.processInfo.systemUptime
        costs.querySeconds += captured - started
        guard let root, root.elementType == .navigationBar else { return nil }
        let result = frames(in: root, leadingID: leadingID)
        costs.walkSeconds += ProcessInfo.processInfo.systemUptime - captured
        return result
    }

    /// Outside the observation window, check the scope against one full captured
    /// hierarchy. Both walks use that SAME immutable tree and exact screen frames.
    /// This also fails if another bar or a matching item outside the bar appears.
    private func scopeMatches(in root: XCUIElementSnapshot, leadingID: String?) -> Bool {
        var bars: [XCUIElementSnapshot] = []
        var outside = false
        func walk(_ node: XCUIElementSnapshot, insideBar: Bool) {
            let inside = insideBar || node.elementType == .navigationBar
            if node.elementType == .navigationBar { bars.append(node) }
            let target = ["companion-chat-header", "companion-chat-header-actions"].contains(node.identifier)
                || node.identifier == leadingID
                || (leadingID == nil && node.elementType == .button && node.label == "Back")
            if target && !inside { outside = true }
            node.children.forEach { walk($0, insideBar: inside) }
        }
        walk(root, insideBar: false)
        guard !outside, bars.count == 1, let whole = frames(in: root, leadingID: leadingID),
              let scoped = frames(in: bars[0], leadingID: leadingID) else { return false }
        return whole.identity == scoped.identity && whole.actions == scoped.actions && whole.leading == scoped.leading
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
        var costs = SampleCosts()
        var violations: [String] = []
        let started = Date()
        var scrolled = 0 // disturbances so far
        var missing = 0, seenFull = false
        var graceUntil = Date.distantPast
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
                        // A back-swipe that's released early, so the chat stays.
                        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
                    } else {
                        app.navigationBars.buttons["Back"].firstMatch.tap()
                        let open = app.buttons["header-fixture-open-chat"]
                        if open.waitForExistence(timeout: 5) { open.tap() }
                        _ = app.buttons["companion-chat-header"].waitForExistence(timeout: 5)
                    }
                case .background:
                    XCUIDevice.shared.press(.home)
                    app.activate()
                    _ = app.buttons["companion-chat-header"].waitForExistence(timeout: 10)
                }
                scrolled += 1
                graceUntil = Date().addingTimeInterval(1)
            }
            guard let f = frames(app, leadingID: leadingID, costs: &costs) else {
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
        print("HEADER_SAMPLER \(name) queries=\(costs.queries) querySeconds=\(costs.querySeconds) walkSeconds=\(costs.walkSeconds)")
        print("HEADER_REFLOW \(name) samples=\(samples) missing=\(missing) violations=\(violations.count)")
        violations.prefix(20).forEach { print("HEADER_REFLOW \(name) \($0)") }
        let report = XCTAttachment(string: violations.joined(separator: "\n"))
        report.name = "554 reflow samples \(name)"; report.lifetime = .keepAlways; add(report)
        let settled = XCTAttachment(screenshot: app.screenshot())
        settled.name = "554 after stream \(name)"; settled.lifetime = .keepAlways; add(settled)
        XCTAssertGreaterThanOrEqual(samples, 100, "\(name): too few header samples to judge")
        XCTAssertEqual(missing, 0, "\(name): the name or actions pill was missing in \(missing) samples")
        XCTAssertTrue(violations.isEmpty, "\(name): header reflowed in \(violations.count) of \(samples) samples; first: \(violations.first ?? "")")
        let auditStarted = ProcessInfo.processInfo.systemUptime
        if let whole = try? app.snapshot() {
            let matches = scopeMatches(in: whole, leadingID: leadingID)
            print("HEADER_SCOPE \(name) sameTreeMatch=\(matches)")
            XCTAssertTrue(matches, "Header sampler must cover the same items/frames as the whole app snapshot")
        } else {
            XCTFail("Could not audit header sampler scope")
        }
        print("HEADER_SCOPE \(name) auditSeconds=\(ProcessInfo.processInfo.systemUptime - auditStarted)")
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
