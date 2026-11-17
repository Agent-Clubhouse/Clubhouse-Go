import XCTest
import Vision

@MainActor final class CompanionCombinedLinkedHomeUITests: ReliableUITestCase {
    private let arguments = ["--companion-preview", "--companion-preview-combined-linked-home"]
    private let foldID = "fold-quiet-link:combined-home"

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollUntilExists(element, in: app) && scrollTo(element, in: app))
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "536 \(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertFullOriginVisible(_ name: String, in row: XCUIElement, app: XCUIApplication) throws {
        // Hittability alone permits a partially clipped AX row. Bring the whole row
        // between navigation and tabs. Held, measured List drags avoid inertial overshoot.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists)
        let initialRowY = row.frame.minY
        var viewport = CGRect.zero
        for step in 0...8 {
            let navigation = app.navigationBars.firstMatch.frame
            let tabs = app.tabBars.firstMatch.frame
            let frame = row.frame
            viewport = CGRect(x: app.frame.minX, y: navigation.maxY, width: app.frame.width,
                              height: tabs.minY - navigation.maxY)
            let geometry: [String: Any] = [
                "step": step, "AXSize": "UICTContentSizeCategoryAccessibilityXXXL",
                "row": NSCoder.string(for: frame), "viewport": NSCoder.string(for: viewport),
                "navigation": NSCoder.string(for: navigation), "tabs": NSCoder.string(for: tabs),
                "list": NSCoder.string(for: list.frame), "hittable": row.isHittable,
                "relativeContentDisplacement": initialRowY - frame.minY,
                "absoluteScrollOffset": "Not exposed by XCUIElement"
            ]
            let data = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "536 AX5 origin geometry step \(step)"
            attachment.lifetime = .keepAlways; add(attachment)
            print("COMBINED_ORIGIN_GEOMETRY \(String(decoding: data, as: UTF8.self))")
            XCTAssertLessThanOrEqual(frame.height, viewport.height, "An oversized row is a product failure, not a scroll failure")
            if viewport.contains(frame) || step == 8 { break }
            let area = viewport.intersection(list.frame)
            XCTAssertGreaterThan(area.height, 0)
            let distance = max(-area.height * 0.4, min(area.height * 0.4, frame.midY - viewport.midY))
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: area.midX - list.frame.minX,
                                                  dy: area.midY + distance / 2 - list.frame.minY))
            let end = origin.withOffset(CGVector(dx: area.midX - list.frame.minX,
                                                dy: area.midY - distance / 2 - list.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(viewport.contains(row.frame), "The full AX row must clear navigation and the floating tab bar")
        let screenshot = app.screenshot()
        let pixels = XCTAttachment(screenshot: screenshot)
        pixels.name = "536 AX5 origin OCR pixels"; pixels.lifetime = .keepAlways; add(pixels)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage)).perform([request])
        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let expected = ["River", "Working", "Synthetic linked project task", name].map(normalized)
        var boxes: [[String: Any]] = []
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            let frame = CGRect(x: app.frame.minX + box.minX * app.frame.width,
                               y: app.frame.minY + (1 - box.maxY) * app.frame.height,
                               width: box.width * app.frame.width, height: box.height * app.frame.height)
            // Vision can merge the sibling helper chevron and avatar into a pseudo-word.
            // Attribute by the fixture's real text, then check every accepted box strictly.
            let candidate = normalized(text)
            let accepted = row.frame.intersects(frame) && !candidate.isEmpty && expected.contains { (" " + $0 + " ").contains(" " + candidate + " ") }
            boxes.append(["text": text, "normalized": candidate, "accepted": accepted,
                          "frame": NSCoder.string(for: frame)])
            return accepted ? (text, frame) : nil
        }
        let data = try JSONSerialization.data(withJSONObject: boxes, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "536 AX5 every OCR box and attribution"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(lines.contains { normalized($0.0) == "river" }, "Accepted OCR must include the row title")
        XCTAssertTrue(lines.map(\.0).joined(separator: " ").contains(name), "Pixels must show the entire machine name, with no truncation")
        XCTAssertGreaterThanOrEqual(lines.filter { name.contains($0.0) }.count, 2,
                                    "The deliberately long machine badge must wrap at AX5, rather than shrink or truncate")
        for (_, frame) in lines {
            XCTAssertTrue(row.frame.contains(frame), "Rendered text must stay inside the row")
            XCTAssertTrue(viewport.contains(frame), "Rendered text must stay inside the visible viewport")
        }
    }

    func testCombinedActiveTreesAndQuietFoldLightDarkAndXXXL() throws {
        let appearances: [(String, [String])] = [
            ("light", ["--companion-preview-light"]),
            ("dark", ["--companion-preview-dark"]),
            ("XXXL", ["--companion-preview-light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, flags) in appearances {
            let app = launchApp(arguments + flags, allowance: 360, attempts: 1)
            XCTAssertTrue(app.staticTexts["home-summary"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["home-summary"].label.contains("2 working"), "Offline cached Working cannot inflate the count")
            let river = element(app, "agent-combined-1-root")
            reveal(river, in: app)
            XCTAssertTrue(river.label.contains("River") && river.label.contains("Travel MacBook"))
            if name == "XXXL" {
                try assertFullOriginVisible("Travel MacBook with a long desktop name", in: river, app: app)
                capture(app, "full untruncated long origin and unclipped row XXXL")
            }
            let willow = element(app, "agent-combined-1-helper")
            reveal(willow, in: app)
            XCTAssertTrue(willow.label.contains("Willow") && willow.label.contains("Travel MacBook"))
            XCTAssertTrue((willow.value as? String)?.contains("Helper of River") == true)
            XCTAssertLessThan(river.frame.minY, willow.frame.minY)
            capture(app, "combined active origin badges \(name)")
            let cedar = element(app, "agent-combined-0-root")
            reveal(cedar, in: app)
            XCTAssertTrue(cedar.label.contains("Cedar") && cedar.label.contains("Studio Mac"))
            let fern = element(app, "agent-combined-0-helper")
            reveal(fern, in: app)
            XCTAssertTrue((fern.value as? String)?.contains("Helper of Cedar") == true)
            XCTAssertFalse(element(app, "project-machine-combined-0-project").exists, "Live machine subheaders no longer split the active list")
            XCTAssertFalse(element(app, "project-machine-combined-2-project").exists, "A quiet-only machine contributes to the one quiet fold")
            let fold = app.buttons[foldID]
            reveal(fold, in: app)
            XCTAssertEqual(app.buttons.matching(identifier: foldID).count, 1)
            XCTAssertTrue(fold.label.contains("1 sleeping") && fold.label.contains("3 finished quick agents"))
            XCTAssertEqual(fold.value as? String, "Collapsed")
            assertMinimumTarget(fold, "Combined quiet fold")
            capture(app, "one collapsed quiet section \(name)")
            fold.tap()
            let juniper = element(app, "agent-combined-2-sleeper")
            reveal(juniper, in: app)
            XCTAssertTrue(juniper.label.contains("Juniper") && juniper.label.contains("Archive Mac"))
            let ash = element(app, "finished-combined-2-project-finished")
            reveal(ash, in: app)
            XCTAssertTrue(ash.label.contains("Ash") && ash.label.contains("Archive Mac"))
            XCTAssertTrue(scrollUntilExists(app.buttons["finished-clear-all"], in: app))
            capture(app, "expanded quiet origins \(name)")
            app.terminate()
        }
    }

    func testSingleDesktopScopeHidesOriginAndQuietOnlyScopeKeepsItsRows() {
        let app = launchApp(arguments, attempts: 1)
        let travel = app.buttons["desktop-chip-host-combined-1"]
        XCTAssertTrue(travel.waitForExistence(timeout: 15)); travel.tap()
        let river = element(app, "agent-combined-1-root")
        reveal(river, in: app)
        XCTAssertFalse(river.label.contains("Travel MacBook"))
        XCTAssertFalse(element(app, "agent-combined-0-root").exists)
        XCTAssertTrue(app.staticTexts["home-summary"].label.contains("1 working"))
        let quietChip = app.buttons["desktop-chip-host-combined-2"]
        let chips = app.scrollViews["desktop-chips"]
        for _ in 0..<4 { if quietChip.isHittable { break }; chips.swipeLeft() }
        XCTAssertTrue(quietChip.isHittable); quietChip.tap()
        let quiet = app.buttons["fold-quiet-combined-2-project"]
        reveal(quiet, in: app)
        XCTAssertTrue(quiet.label.contains("1 sleeping") && quiet.label.contains("1 finished quick agent"))
        XCTAssertFalse(element(app, "agent-combined-1-root").exists)
        quiet.tap()
        let juniper = element(app, "agent-combined-2-sleeper")
        reveal(juniper, in: app)
        XCTAssertTrue(juniper.label.contains("Juniper"))
        XCTAssertFalse(juniper.label.contains("Archive Mac"))
        capture(app, "quiet-only single desktop scope has no redundant badges")
    }

    func testOfflineDisclosureKeepsCachedRowsNonActionable() {
        let app = launchApp(arguments, attempts: 1)
        let offline = app.buttons["project-machine-combined-3-project"]
        reveal(offline, in: app)
        XCTAssertTrue(offline.label.contains("Offline Mac not connected · 1 agent"))
        let cached = element(app, "cached-agent-combined-3-project-root")
        XCTAssertFalse(cached.exists)
        offline.tap()
        XCTAssertTrue(scrollUntilExists(cached, in: app) && scrollTo(cached, in: app))
        XCTAssertTrue(cached.label.contains("cached on Offline Mac"))
        XCTAssertFalse(cached.isEnabled)
        XCTAssertFalse(element(app, "agent-combined-3-root").exists)
        capture(app, "offline cached disclosure remains separate and non-actionable")
    }

    func testSameMachineLinkedCopiesKeepProjectOriginsInAllAndStudioScope() {
        let app = launchApp(["--companion-preview", "--companion-preview-linked-projects",
                             "--companion-preview-linked-projects-same-machine"], attempts: 1)
        let studio = element(app, "agent-preview-studio-cedar")
        let docs = element(app, "agent-preview-studio-docs-agent")
        reveal(studio, in: app)
        XCTAssertTrue(studio.label.contains("Studio Mac · Clubhouse"))
        reveal(docs, in: app)
        XCTAssertTrue(docs.label.contains("Studio Mac · Docs"))
        capture(app, "same-machine linked copies retain project origin in All")
        let chip = app.buttons["desktop-chip-host-preview-studio"]
        XCTAssertTrue(scrollTo(chip, in: app, up: false)); chip.tap()
        XCTAssertTrue(chip.isSelected)
        reveal(studio, in: app)
        XCTAssertTrue(studio.label.contains("Studio Mac · Clubhouse"), "Machine scope does not make project origin redundant")
        reveal(docs, in: app)
        XCTAssertTrue(docs.label.contains("Studio Mac · Docs"))
        XCTAssertFalse(element(app, "agent-preview-laptop-river").exists)
        let fold = app.buttons["fold-quiet-link:preview-linked-clubhouse"]
        reveal(fold, in: app); fold.tap()
        let sleeping = element(app, "agent-preview-studio-juniper")
        reveal(sleeping, in: app)
        XCTAssertTrue(sleeping.label.contains("Studio Mac · Clubhouse"), "Expanded quiet rows keep the same project attribution")
        capture(app, "same-machine scope retains project origins in active and quiet rows")
    }

    func testDismissThenClearAffectOnlyRetainedRunsAcrossMachines() {
        let app = launchApp(arguments, attempts: 1)
        let fold = app.buttons[foldID]
        reveal(fold, in: app); fold.tap()
        let maple = element(app, "finished-combined-0-project-finished")
        reveal(maple, in: app)
        maple.swipeLeft()
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5)); dismiss.tap()
        XCTAssertTrue(maple.waitForNonExistence(timeout: 5))
        let birch = element(app, "finished-combined-1-project-finished")
        XCTAssertTrue(scrollUntilExists(birch, in: app))
        let clear = app.buttons["finished-clear-all"]
        reveal(clear, in: app); clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        XCTAssertFalse(birch.exists)
        XCTAssertFalse(element(app, "finished-combined-2-project-finished").exists)
        let juniper = element(app, "agent-combined-2-sleeper")
        reveal(juniper, in: app)
        XCTAssertTrue(juniper.label.contains("Archive Mac"), "Clearing finished history keeps the sleeping agent and its origin")
        capture(app, "one quiet fold keeps sleeping rows after Dismiss and Clear")
    }
}
