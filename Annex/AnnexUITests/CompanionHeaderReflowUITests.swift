import XCTest

/// #554: with a long name while a reply streams and the transcript scrolls, the header must not reflow. The name
/// stays centred between the side items and the trailing actions pill stays on screen, at every sampled tick.
@MainActor final class CompanionHeaderReflowUITests: ReliableUITestCase {
    private struct Frames { let identity: CGRect; let actions: CGRect; let leading: CGRect? }

    /// One accessibility snapshot per sample, so a sample is a single moment rather than several queries apart.
    private func frames(_ app: XCUIApplication, leadingID: String?) -> Frames? {
        guard let root = try? app.snapshot() else { return nil }
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

    private func sampleReflow(_ flags: [String], name: String) {
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
        var scrolled = 0
        while Date().timeIntervalSince(started) < 14 {
            // Scroll the transcript mid-stream, as on the phone.
            if scrolled < 2, Date().timeIntervalSince(started) > Double(4 + 4 * scrolled) {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrolled == 0 ? 0.35 : 0.65))
                start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.5, dy: scrolled == 0 ? 0.65 : 0.35)))
                scrolled += 1
            }
            guard let f = frames(app, leadingID: leadingID) else { continue }
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
        print("HEADER_REFLOW \(name) samples=\(samples) violations=\(violations.count)")
        violations.prefix(20).forEach { print("HEADER_REFLOW \(name) \($0)") }
        let report = XCTAttachment(string: violations.joined(separator: "\n"))
        report.name = "554 reflow samples \(name)"; report.lifetime = .keepAlways; add(report)
        let settled = XCTAttachment(screenshot: app.screenshot())
        settled.name = "554 after stream \(name)"; settled.lifetime = .keepAlways; add(settled)
        XCTAssertGreaterThan(samples, 10, "\(name): too few header samples to judge")
        XCTAssertTrue(violations.isEmpty, "\(name): header reflowed in \(violations.count) of \(samples) samples; first: \(violations.first ?? "")")
    }

    func testOrchestratorNameWithBackDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name", "--companion-header-pushed"], name: "orchestrator back")
    }
    func testOrchestratorNameWithLeadingItemDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-orchestrator-name"], name: "orchestrator leading")
    }
    func testLongNameWithBackDoesNotReflowWhileStreaming() {
        sampleReflow(["--companion-header-long-name", "--companion-header-pushed"], name: "long back")
    }
}
