import XCTest

@MainActor
final class CompanionAgentTreeUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-helper-tree"]
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// Passive evidence only; a launch-return marker does not establish behavior coverage.
    private func milestone(_ caseID: String, _ phase: String, since start: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTContext.runActivity(named: "AgentTree \(caseID) — \(phase); elapsed=\(elapsed)s") { _ in }
    }
    /// Home-only measured navigation; six total movements, no existence waits or action rescue.
    private func revealHomeTreeControl(_ app: XCUIApplication, id: String,
                                       file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let cedarID = "helpers-toggle-preview-studio-cedar"
        let projectID = "open-project-preview-studio-clubhouse"
        let headerID = "project-preview-studio-clubhouse"
        func finite(_ r: CGRect) -> Bool {
            [r.minX, r.minY, r.width, r.height, r.maxX, r.maxY].allSatisfy { $0.isFinite }
                && r.width > 0 && r.height > 0
        }
        func note(_ text: String) {
            XCTContext.runActivity(named: "Home navigation \(id): \(text)") { _ in }
        }
        func reject(_ reason: String) {
            note("FAIL: \(reason)")
            shot(app, "Home navigation \(id) failure — \(reason)")
            let attachment = XCTAttachment(data: Data(app.debugDescription.utf8.prefix(65_536)),
                                           uniformTypeIdentifier: "public.plain-text")
            attachment.name = "Home navigation failure public hierarchy (capped; later retrieval)"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTFail(reason, file: file, line: line)
        }
        struct Snapshot {
            let collection: XCUIElement
            let appFrame: CGRect
            let clip: CGRect
            let targetFrame: CGRect?
            let ready: Bool
            let guideID: String
            let guideFrame: CGRect
        }
        // Source identifies this header and Cedar with the same host/project. Native AX flattens
        // Section headers/rows into sibling Cells; this does not assert a native Section ancestor.
        func guide(_ guideID: String, collection: XCUIElement, phase: String) -> CGRect? {
            if guideID == headerID {
                let globalHeaders = app.staticTexts.matching(identifier: headerID)
                let headers = collection.staticTexts.matching(identifier: headerID)
                let globalLinks = app.buttons.matching(identifier: projectID)
                let links = collection.buttons.matching(identifier: projectID)
                let cells = collection.cells.containing(.staticText, identifier: headerID)
                let counts = [globalHeaders.count, headers.count, globalLinks.count, links.count, cells.count]
                note("\(phase) header counts global/local/linkGlobal/linkLocal/cell=\(counts)")
                guard counts == [1, 1, 1, 1, 1] else {
                    reject("Unique source-identified Clubhouse header/link/Cell required"); return nil
                }
                let header = headers.element(boundBy: 0)
                let cell = cells.element(boundBy: 0)
                let nestedLinks = header.buttons.matching(identifier: projectID)
                let nestedCount = nestedLinks.count
                note("\(phase) nested project link count=\(nestedCount)")
                guard nestedCount == 1 else { reject("Clubhouse link must belong to its exact header"); return nil }
                let link = nestedLinks.element(boundBy: 0)
                let h = header.frame, c = cell.frame, l = link.frame
                let valid = finite(h) && finite(c) && finite(l)
                let containment = c.contains(h) && h.contains(l)
                let label = link.label
                note("\(phase) header=\(h) cell=\(c) link=\(l) finite=\(valid) containment=\(containment) label=\(label)")
                guard valid && containment && label == "Open Clubhouse" else {
                    reject("Clubhouse header geometry/label is unsupported"); return nil
                }
                return h
            }
            let global = app.buttons.matching(identifier: guideID)
            let local = collection.buttons.matching(identifier: guideID)
            let globalAny = app.descendants(matching: .any).matching(identifier: guideID)
            let localAny = collection.descendants(matching: .any).matching(identifier: guideID)
            let counts = [global.count, globalAny.count, local.count, localAny.count]
            note("\(phase) same-guide \(guideID) globalButton/globalAny/localButton/localAny counts=\(counts)")
            guard guideID == id && counts == [1, 1, 1, 1] else {
                reject("The same measured target guide must remain unique in Home"); return nil
            }
            let frame = local.element(boundBy: 0).frame
            note("\(phase) same-guide \(guideID) frame=\(frame) finite=\(finite(frame))")
            guard finite(frame) else { reject("Same-guide frame must remain finite"); return nil }
            return frame
        }
        func read(_ phase: String) -> Snapshot? {
            let collections = app.collectionViews
            let windows = app.windows
            let navs = app.navigationBars
            let homeNavs = navs.matching(identifier: "Clubhouse")
            let tabs = app.tabBars
            let targets = app.buttons.matching(identifier: id)
            let counts = [collections.count, windows.count, navs.count, homeNavs.count, tabs.count, targets.count]
            note("\(phase) collection/window/nav/HomeNav/tab/target counts=\(counts)")
            guard counts.prefix(5).allSatisfy({ $0 == 1 }) else {
                reject("Unique Home collection/window/navigation/tab required"); return nil
            }
            let collection = collections.element(boundBy: 0)
            let tab = tabs.element(boundBy: 0)
            let homeButtons = tab.buttons.matching(identifier: "Home")
            let homeCount = homeButtons.count
            note("\(phase) Home tab button count=\(homeCount)")
            guard homeCount == 1 else { reject("Unique Home tab required"); return nil }
            let homeSelected = homeButtons.element(boundBy: 0).isSelected
            let a = app.frame, w = windows.element(boundBy: 0).frame
            let c = collection.frame, n = homeNavs.element(boundBy: 0).frame, t = tab.frame
            let valid = [a, w, c, n, t].allSatisfy(finite)
            let window = w.intersection(a)
            let chromeValid = valid && finite(window) && window.contains(n) && window.contains(t) && n.maxY < t.minY
            note("\(phase) app=\(a) window=\(w) intersection=\(window) collection=\(c) nav=\(n) tab=\(t) finite=\(valid) chrome=\(chromeValid) HomeSelected=\(homeSelected)")
            guard homeSelected && chromeValid else { reject("Unsupported actual Home window/chrome"); return nil }
            let navToTab = CGRect(x: window.minX, y: n.maxY, width: window.width, height: t.minY - n.maxY)
            let clip = c.intersection(window).intersection(navToTab)
            note("\(phase) navToTab=\(navToTab) clip=\(clip) finite=\(finite(clip))")
            guard finite(clip) else { reject("A finite positive nav-to-tab collection clip is required"); return nil }
            let local = collection.buttons.matching(identifier: id)
            let localCount = local.count
            let globalAnyCount = app.descendants(matching: .any).matching(identifier: id).count
            let localAnyCount = collection.descendants(matching: .any).matching(identifier: id).count
            let targetCounts = [counts[5], globalAnyCount, localCount, localAnyCount]
            note("\(phase) target globalButton/globalAny/localButton/localAny counts=\(targetCounts)")
            guard targetCounts.allSatisfy({ $0 == counts[5] }) && counts[5] <= 1 else {
                reject("Target any-role and Button counts must agree uniquely in app and Home collection"); return nil
            }
            if counts[5] == 1 {
                let target = local.element(boundBy: 0)
                let frame = target.frame
                let exists = target.exists, hittable = target.isHittable
                let validTarget = finite(frame)
                let contained = validTarget && clip.contains(frame)
                note("\(phase) target=\(frame) finite=\(validTarget) exists=\(exists) wholeClip=\(contained) hittable=\(hittable)")
                guard exists && validTarget else { reject("Existing target requires a finite actual frame"); return nil }
                if contained && !hittable { reject("Contained-but-unhittable target has no navigation rescue"); return nil }
                return Snapshot(collection: collection, appFrame: a, clip: clip, targetFrame: frame,
                                ready: contained && hittable, guideID: id, guideFrame: frame)
            }
            guard id == cedarID else { reject("Only absent Cedar may use the exact source-identified header witness"); return nil }
            guard let header = guide(headerID, collection: collection, phase: phase) else { return nil }
            let below = header.maxY > clip.maxY && header.minY >= clip.minY
            note("\(phase) absent Cedar prerequisite headerBelowClip=\(below) headerWholeClip=\(clip.contains(header))")
            guard below else { reject("Absent Cedar requires measured below-clip header overflow; no onward search"); return nil }
            return Snapshot(collection: collection, appFrame: a, clip: clip, targetFrame: nil,
                            ready: false, guideID: headerID, guideFrame: header)
        }
        func overflow(_ frame: CGRect, _ clip: CGRect) -> CGFloat {
            max(clip.minY - frame.minY, 0) + max(frame.maxY - clip.maxY, 0)
        }
        guard id == cedarID || id == projectID else { reject("Unsupported Home navigation target"); return false }
        checkTimeLeft("measured Home navigation \(id)", file: file, line: line)
        guard var current = read("initial") else { return false }
        if current.ready { return true }
        for movement in 1...6 {
            checkTimeLeft("measured Home navigation \(id) movement \(movement)/6", file: file, line: line)
            let clip = current.clip, frame = current.guideFrame
            let horizontal = frame.minX >= clip.minX && frame.maxX <= clip.maxX
            let heightFits = frame.height <= clip.height
            let above = frame.minY < clip.minY && frame.maxY <= clip.maxY
            let below = frame.maxY > clip.maxY && frame.minY >= clip.minY
            let beforeOverflow = overflow(frame, clip)
            note("movement \(movement) guide=\(current.guideID) frame=\(frame) clip=\(clip) horizontal=\(horizontal) heightFits=\(heightFits) above=\(above) below=\(below) overflow=\(beforeOverflow)")
            guard horizontal && heightFits && (above != below) && beforeOverflow > 0 else {
                reject("Guide must fit horizontally/vertically with one measured vertical overflow"); return false
            }
            // At most one quarter of the currently visible collection height; include only
            // available interior clearance, never an assumed row distance or full-app fling.
            let interior = clip.insetBy(dx: 12, dy: 12)
            let clearance = min(CGFloat(12), (clip.height - frame.height) / 2)
            let distance = min(beforeOverflow + clearance, min(clip.height / 4, interior.height - 2))
            let direction: CGFloat = below ? 1 : -1
            let start = CGPoint(x: interior.midX, y: interior.midY + direction * distance / 2)
            let end = CGPoint(x: interior.midX, y: interior.midY - direction * distance / 2)
            let endpointDistance = hypot(end.x - start.x, end.y - start.y)
            let velocity = endpointDistance / CGFloat(1) // nominal one-second movement, not a delivery guarantee
            let pointsFinite = [start.x, start.y, end.x, end.y, distance, velocity].allSatisfy { $0.isFinite }
            let safePoints = finite(interior) && pointsFinite && distance > 0 && velocity > 0
                && interior.contains(start) && interior.contains(end) && clip.contains(start) && clip.contains(end)
            note("movement \(movement) interior=\(interior) clearance=\(clearance) distance=\(distance) start=\(start) end=\(end) velocity=\(velocity) finite=\(pointsFinite) safePoints=\(safePoints)")
            guard safePoints else { reject("No supported measured short-drag endpoints"); return false }
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let from = origin.withOffset(CGVector(dx: start.x - current.appFrame.minX, dy: start.y - current.appFrame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - current.appFrame.minX, dy: end.y - current.appFrame.minY))
            shot(app, "Home navigation \(id) movement \(movement) original before")
            from.press(forDuration: 0.05, thenDragTo: to,
                       withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0.2)
            shot(app, "Home navigation \(id) movement \(movement) original after")
            guard let after = read("after movement \(movement)") else { return false }
            if after.ready {
                note("movement \(movement) success: fresh unique whole-clip hittable target=\(String(describing: after.targetFrame))")
                return true
            }
            guard let sameGuide = guide(current.guideID, collection: after.collection,
                                        phase: "progress after movement \(movement)") else { return false }
            let displacement = (frame.midY - sameGuide.midY) * direction
            let afterOverflow = overflow(sameGuide, after.clip)
            let movedCorrectly = displacement.isFinite && displacement > 0
            let reducedOverflow = afterOverflow.isFinite && afterOverflow < beforeOverflow
            note("movement \(movement) progress sameGuide=\(current.guideID) oldFrame=\(frame) newFrame=\(sameGuide) oldClip=\(clip) newClip=\(after.clip) displacement=\(displacement) oldOverflow=\(beforeOverflow) newOverflow=\(afterOverflow) moved=\(movedCorrectly) reduced=\(reducedOverflow)")
            guard movedCorrectly && reducedOverflow else {
                reject("Same guide must actually move correctly and reduce overflow under fresh chrome"); return false
            }
            current = after
        }
        reject("Six total measured movements exhausted without a whole-clip hittable target")
        return false
    }
    func testNestedRowsCollapseRollupRelaunchAndNeedsYouNavigation() {
        let caseID = #function
        let started = ProcessInfo.processInfo.systemUptime
        milestone(caseID, "initial launch starting", since: started)
        let app = launchApp(arguments, attempts: 1)
        milestone(caseID, "initial launch returned", since: started)
        let parent = element(app, "helpers-toggle-preview-studio-cedar")
        let child = element(app, "helpers-toggle-preview-studio-river")
        let nested = element(app, "agent-preview-studio-juniper")
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Expanded")
        XCTAssertGreaterThanOrEqual(parent.frame.width, 44)
        XCTAssertGreaterThanOrEqual(parent.frame.height, 44)
        XCTAssertTrue(child.exists && nested.exists, "An awake helper keeps sleeping Cedar out of the sleeping fold")
        XCTAssertTrue(scrollTo(nested, in: app))
        XCTAssertEqual(nested.value as? String, "Helper of River")
        XCTAssertGreaterThan(app.staticTexts["Juniper"].firstMatch.frame.minX, app.staticTexts["Cedar"].firstMatch.frame.minX)
        milestone(caseID, "initial tree assertions completed", since: started)
        shot(app, "Home nested helpers expanded")
        parent.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 5))
        XCTAssertFalse(nested.exists)
        XCTAssertEqual(parent.value as? String, "Collapsed")
        let row = element(app, "agent-preview-studio-cedar")
        XCTAssertTrue(app.staticTexts["Cedar"].firstMatch.exists, "The rollup leaves the agent name readable")
        XCTAssertTrue(row.label.contains("2 helpers") && row.label.localizedCaseInsensitiveContains("needs you"), row.label)
        shot(app, "Home collapsed parent with helper rollup")

        let sleeping = element(app, "fold-sleeping-preview-studio-clubhouse")
        let moss = element(app, "agent-preview-studio-moss")
        expandFold(sleeping, revealing: moss, in: app)
        let finished = element(app, "fold-finished-preview-studio-clubhouse")
        let quick = element(app, "agent-preview-studio-quick-willow")
        expandFold(finished, revealing: quick, in: app)
        milestone(caseID, "intentional preference relaunch starting", since: started)
        app.terminate()
        app.launchArguments = arguments + ["--ui-testing-fast", "--companion-preview-keep-preferences"]
        app.launch()
        milestone(caseID, "intentional preference relaunch returned", since: started)
        XCTAssertTrue(revealHomeTreeControl(app, id: "helpers-toggle-preview-studio-cedar"))
        XCTAssertEqual(parent.value as? String, "Collapsed")
        XCTAssertFalse(child.exists)
        XCTAssertTrue(scrollUntilExists(moss, in: app))
        XCTAssertTrue(scrollUntilExists(quick, in: app))
        milestone(caseID, "persisted tree assertions completed", since: started)

        // Needs you is a flat destination and still opens River while Cedar is folded.
        let river = element(app, "agent-preview-studio-river")
        let composer = element(app, "companion-composer")
        XCTAssertTrue(scrollTo(river, in: app, up: false))
        tapVisibleRow(river, in: app, until: composer)
        XCTAssertTrue(app.navigationBars["River"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scrollUntilExists(parent, in: app) && scrollTo(parent, in: app))
        XCTAssertEqual(parent.value as? String, "Collapsed", "Direct navigation preserves disclosure")
        milestone(caseID, "all behavior assertions completed", since: started)
    }
    func testProjectUsesSameTreeAndCrossProjectCaption() {
        let caseID = #function
        let started = ProcessInfo.processInfo.systemUptime
        milestone(caseID, "initial launch starting", since: started)
        let app = launchApp(arguments, attempts: 1)
        milestone(caseID, "initial launch returned", since: started)
        let project = element(app, "open-project-preview-studio-clubhouse")
        let toggle = element(app, "helpers-toggle-preview-studio-cedar")
        XCTAssertTrue(revealHomeTreeControl(app, id: "open-project-preview-studio-clubhouse"))
        waitAndTap(project, until: element(app, "project-new-agent"))
        XCTAssertTrue(scrollUntilExists(toggle, in: app) && scrollTo(toggle, in: app))
        XCTAssertTrue(element(app, "agent-preview-studio-juniper").exists)
        milestone(caseID, "initial project tree assertions completed", since: started)
        shot(app, "Project nested helpers expanded")
        toggle.tap()
        XCTAssertTrue(element(app, "helpers-toggle-preview-studio-river").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "agent-preview-studio-cedar").label.contains("2 helpers"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed", "Home and project share disclosure")
        app.tabBars.buttons["Agents"].tap()
        let maple = element(app, "agent-preview-studio-maple")
        XCTAssertTrue(scrollUntilExists(maple, in: app) && scrollTo(maple, in: app))
        XCTAssertTrue(maple.label.contains("Helper of Cedar in Clubhouse"), maple.label)
        milestone(caseID, "all behavior assertions completed", since: started)
    }
}
