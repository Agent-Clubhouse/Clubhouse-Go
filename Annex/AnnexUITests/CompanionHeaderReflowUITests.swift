import XCTest

/// #554: sample the actual native accessible header frames while the real
/// gestures execute in the separate UITest process. Phase/missing grace and all
/// geometry thresholds remain the original test's; during-gesture records are
/// diagnostic and cannot count toward the100 required outside-phase samples.
@MainActor final class CompanionHeaderReflowUITests: ReliableUITestCase {
    private struct Frames { let identity: CGRect; let actions: CGRect; let leading: CGRect? }

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

    private struct ProbeControl: Codable { let identifier: String; let label: String; let rect: [Double] }
    private struct ProbeRecord: Codable {
        let sequence: Int
        let timestamp: Double
        let captureStarted: Double
        let captureEnded: Double
        let status: String
        let streaming: Bool
        let controls: [String: ProbeControl]
        let matchCounts: [String: Int]
        let duplicateNodes: Int
        let scanLimited: Bool
    }
    private struct ProbePayload: Decodable {
        let version: Int
        let session: String
        let readUptime: Double
        let phase: String
        let latest: ProbeRecord?
        let records: [ProbeRecord]?
        let dropped: Int
    }
    private struct Phase { let start: Double; let end: Double }
    private struct Inspection {
        var samples = 0, missing = 0, ambiguous = 0, duplicate = 0, invalid = 0, during = 0
        var violations: [String] = []
    }

    private func nativeFrames(_ row: ProbeRecord, leadingID: String?) -> Frames? {
        let leading = leadingID ?? "Back"
        let keys = ["companion-chat-header", "companion-chat-header-actions", leading]
        guard row.status == "ok", !row.scanLimited, Set(row.controls.keys) == Set(keys),
              keys.allSatisfy({ row.matchCounts[$0] == 1 }) else { return nil }
        func rect(_ key: String) -> CGRect? {
            guard let value = row.controls[key], value.rect.count == 4,
                  value.rect.allSatisfy(\.isFinite), value.rect[2] > 0, value.rect[3] > 0,
                  key == "Back" ? value.label == "Back" : value.identifier == key else { return nil }
            return CGRect(x: value.rect[0], y: value.rect[1], width: value.rect[2], height: value.rect[3])
        }
        guard let identity = rect(keys[0]), let actions = rect(keys[1]), let side = rect(leading) else { return nil }
        return Frames(identity: identity, actions: actions, leading: side)
    }

    /// Cross-transport equality only, never an epsilon in the geometry oracles.
    /// Corresponding finite edges may differ by at most four representable steps.
    private func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let raw = [lhs.origin.x, lhs.origin.y, lhs.width, lhs.height, rhs.origin.x, rhs.origin.y, rhs.width, rhs.height]
        guard raw.allSatisfy(\.isFinite), lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
        return [(lhs.minX, rhs.minX), (lhs.minY, rhs.minY), (lhs.maxX, rhs.maxX), (lhs.maxY, rhs.maxY)].allSatisfy {
            $0.0.isFinite && $0.1.isFinite && abs($0.0 - $0.1) <= max($0.0.ulp, $0.1.ulp) * 4
        }
    }

    private func crossCheck(_ app: XCUIApplication, leadingID: String?, session: String? = nil) -> ProbePayload? {
        let before = ProcessInfo.processInfo.systemUptime
        guard let root = try? app.snapshot() else { XCTFail("SDK header cross-check requires a fresh whole-app snapshot"); return nil }
        let after = ProcessInfo.processInfo.systemUptime
        var values: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == "header-display-probe", let value = node.value as? String { values.append(value) }
            node.children.forEach(walk)
        }
        walk(root)
        guard values.count == 1, let data = values[0].data(using: .utf8),
              let payload = try? JSONDecoder().decode(ProbePayload.self, from: data),
              payload.version == 1, payload.dropped == 0,
              payload.phase == (session == nil ? "recording" : "exported"),
              payload.readUptime.isFinite, payload.readUptime >= before, payload.readUptime <= after,
              session == nil || payload.session == session,
              let native = payload.latest, let local = nativeFrames(native, leadingID: leadingID),
              let sdk = frames(in: root, leadingID: leadingID), let sdkLeading = sdk.leading, let nativeLeading = local.leading,
              scopeMatches(in: root, leadingID: leadingID),
              sameFrame(local.identity, sdk.identity), sameFrame(local.actions, sdk.actions), sameFrame(nativeLeading, sdkLeading) else {
            XCTFail("Native display sampler must match the SDK's current control identities/frames and monotonic clock; payload=\(values.first?.prefix(2000) ?? "missing")")
            return nil
        }
        print("HEADER_SCOPE SDK session=\(payload.session) read=\(payload.readUptime) bracket=\(before)..\(after) display=\(native.timestamp) identity=\(sdk.identity) actions=\(sdk.actions) leading=\(sdkLeading)")
        return payload
    }

    /// Geometry/missing semantics are the original sampler's. Records captured
    /// during a native disturbance are reported, but cannot count toward100 or
    /// change its original blind-phase/grace policy.
    private func inspect(_ records: [ProbeRecord], start: Double, end: Double, phases: [Phase],
                         screen: CGRect, leadingID: String?) -> Inspection {
        var result = Inspection()
        var seenFull = false
        var previousTimestamp = -Double.infinity
        var previousSequence = 0
        for row in records {
            guard row.timestamp.isFinite, row.captureStarted.isFinite, row.captureEnded.isFinite,
                  row.captureEnded >= row.captureStarted, row.sequence > previousSequence else {
                result.invalid += 1; continue
            }
            previousSequence = row.sequence
            let distinct = row.timestamp > previousTimestamp && row.status != "duplicateTimestamp"
            previousTimestamp = max(previousTimestamp, row.timestamp)
            guard row.captureStarted >= start, row.captureEnded < end else { continue }
            if phases.contains(where: { row.captureStarted < $0.end && row.captureEnded > $0.start }) {
                result.during += 1; continue
            }
            guard distinct else { result.duplicate += 1; continue }
            guard row.streaming else { result.invalid += 1; continue }
            if row.status == "ambiguous" { result.ambiguous += 1 }
            if row.status == "scanLimited" || row.status == "invalidFrame" { result.invalid += 1 }
            let grace = phases.filter { $0.end <= row.captureStarted }.last.map { $0.end + 1 } ?? -Double.infinity
            guard let f = nativeFrames(row, leadingID: leadingID) else {
                if seenFull, row.captureStarted > grace { result.missing += 1 }
                continue
            }
            seenFull = true
            result.samples += 1
            var problems: [String] = []
            if f.actions.maxX > screen.maxX + 0.5 { problems.append("actions past the right edge") }
            if f.identity.maxX + 4 > f.actions.minX { problems.append("identity overlaps actions") }
            if let leading = f.leading, f.identity.minX - 4 < leading.maxX { problems.append("identity overlaps the leading item") }
            if abs(f.identity.midX - screen.midX) > 1 { problems.append("identity off centre") }
            if !problems.isEmpty {
                result.violations.append("t=\(row.captureStarted-start)s display=\(row.timestamp) \(problems.joined(separator: ", ")) identity=\(f.identity) actions=\(f.actions) leading=\(String(describing: f.leading))")
            }
        }
        return result
    }

    enum Disturbance { case scroll, pushPop, background }

    private func sampleReflow(_ flags: [String], name: String, disturbance: Disturbance = .scroll) {
        let app = launchApp(["--companion-preview", "--companion-preview-header-fixture", "--companion-header-stream", "--companion-header-display-probe"] + flags,
                            attempts: 1)
        let pushed = flags.contains("--companion-header-pushed")
        if pushed {
            let open = app.buttons["header-fixture-open-chat"]
            XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        }
        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 10))
        let screen = app.frame
        let leadingID = pushed ? nil : "header-fixture-menu"
        let probe = app.buttons["header-display-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        probe.tap() // One explicit fixture action starts the unchanged20s synthetic stream.
        guard let initial = crossCheck(app, leadingID: leadingID) else { return }
        XCTAssertTrue(initial.latest?.streaming == true, "The original20s stream must be active before observation")
        let started = Date()
        let windowStart = ProcessInfo.processInfo.systemUptime
        var scrolled = 0
        var phases: [Phase] = []
        while Date().timeIntervalSince(started) < 14 {
            if scrolled < 2, Date().timeIntervalSince(started) > Double(4 + 4 * scrolled) {
                let phaseStart = ProcessInfo.processInfo.systemUptime
                switch disturbance {
                case .scroll:
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrolled == 0 ? 0.35 : 0.65))
                    start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset:
                        CGVector(dx: 0.5, dy: scrolled == 0 ? 0.65 : 0.35)))
                case .pushPop:
                    if scrolled == 0 {
                        // A slow, held partial swipe releases without the fast flick
                        // that actually popped the route in the original hosted trace.
                        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                                   withVelocity: .slow, thenHoldForDuration: 0.2)
                        XCTAssertTrue(app.buttons["companion-chat-header"].exists, "The partial back swipe must cancel and leave chat visible")
                    } else {
                        app.navigationBars.buttons["Back"].firstMatch.tap()
                        let open = app.buttons["header-fixture-open-chat"]
                        XCTAssertTrue(open.waitForExistence(timeout: 5), "The separate native Back tap must reach the fixture root")
                        open.tap()
                        XCTAssertTrue(app.buttons["companion-chat-header"].waitForExistence(timeout: 5))
                    }
                case .background:
                    XCUIDevice.shared.press(.home)
                    app.activate()
                    _ = app.buttons["companion-chat-header"].waitForExistence(timeout: 10)
                }
                phases.append(Phase(start: phaseStart, end: ProcessInfo.processInfo.systemUptime))
                scrolled += 1
            }
            // Only the independent app display callback samples geometry. Yielding
            // this test driver cannot duplicate, pause or credit a native sample.
            Thread.sleep(forTimeInterval: 0.01)
        }
        let windowEnd = windowStart + 14
        // An explicit fixture action freezes the original records AFTER the window.
        // No getter mutates capture state or drains a buffer during SDK lookup.
        probe.tap()
        guard let payload = crossCheck(app, leadingID: leadingID, session: initial.session), let records = payload.records else {
            XCTFail("The fixture must export its original display records"); return
        }
        let result = inspect(records, start: windowStart, end: windowEnd, phases: phases, screen: screen, leadingID: leadingID)
        print("HEADER_DISPLAY \(name) window=\(windowStart)..\(windowEnd) nativeRecords=\(records.count) duringDisturbance=\(result.during) samples=\(result.samples) missing=\(result.missing) ambiguous=\(result.ambiguous) duplicate=\(result.duplicate) invalid=\(result.invalid) violations=\(result.violations.count)")
        result.violations.prefix(20).forEach { print("HEADER_REFLOW \(name) \($0)") }
        guard let phaseData = try? JSONEncoder().encode(phases.map { [$0.start, $0.end] }),
              let recordData = try? JSONEncoder().encode(records), let recordText = String(data: recordData, encoding: .utf8) else {
            XCTFail("Original native frame/phase evidence must encode"); return
        }
        let original = XCTAttachment(data: phaseData, uniformTypeIdentifier: "public.json")
        original.name = "554 native disturbance intervals \(name)"; original.lifetime = .keepAlways; add(original)
        let recordAttachment = XCTAttachment(string: recordText)
        recordAttachment.name = "554 original native display records \(name)"; recordAttachment.lifetime = .keepAlways; add(recordAttachment)
        let report = XCTAttachment(string: result.violations.joined(separator: "\n"))
        report.name = "554 reflow samples \(name)"; report.lifetime = .keepAlways; add(report)
        let settled = XCTAttachment(screenshot: app.screenshot())
        settled.name = "554 after stream \(name)"; settled.lifetime = .keepAlways; add(settled)
        if !result.violations.isEmpty {
            let diagnostic = XCTAttachment(screenshot: app.screenshot())
            diagnostic.name = "554 post-window diagnostic; first reflow time in records \(name)"
            diagnostic.lifetime = .keepAlways; add(diagnostic)
        }
        XCTAssertEqual(scrolled, 2, "Both original native disturbances must execute")
        XCTAssertEqual(result.invalid, 0, "Native display records must be finite, ordered and complete")
        XCTAssertEqual(result.ambiguous, 0, "Intended header controls must be unambiguous")
        XCTAssertEqual(result.duplicate, 0, "A repeated display timestamp cannot count as another sample")
        XCTAssertGreaterThanOrEqual(result.samples, 100, "\(name): too few header samples to judge")
        XCTAssertEqual(result.missing, 0, "\(name): the name or actions pill was missing in \(result.missing) samples")
        XCTAssertTrue(result.violations.isEmpty, "\(name): header reflowed in \(result.violations.count) of \(result.samples) samples; first: \(result.violations.first ?? "")")
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
