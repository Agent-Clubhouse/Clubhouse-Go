import XCTest

/// Clubhouse Go against a real Clubhouse desktop: `scripts/e2e-live.sh` (nightly in `.github/workflows/e2e-nightly.yml`).
///
/// The script launches the desktop as an isolated fixture (loopback-only, ephemeral Annex, a disposable profile) with
/// its scripted fake Claude CLI, so every reply is deterministic and no model is called. The fixture has one git
/// project with two sleeping chat agents, Echo (project folder) and Builder (own worktree). Each test launches the app
/// with the fixture's in-memory invitation, which pairs it for that session only.
///
/// The fake CLI's scripted turns: `hello` streams "Hello"; `tool` asks to run `ls` and replies `allowed:…` or
/// `denied:…`; `ask` asks "Which DB?"; a message with images replies
/// `echo:<text>|…|images:<n>:<types>`.
///
/// Tests share the desktop and run in order (`test0…` before `test1…`), but each one copes with what an earlier one
/// left, so a retry or `--only` run still works.
@MainActor
final class CompanionLiveE2ETests: ReliableUITestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var echoID: String { env["CLUBHOUSE_E2E_ECHO_AGENT"] ?? "" }
    private var builderID: String { env["CLUBHOUSE_E2E_BUILDER_AGENT"] ?? "" }
    private var projectName: String { env["CLUBHOUSE_E2E_PROJECT"] ?? "Phone Fixture" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(env["CLUBHOUSE_RUN_LIVE_E2E"] == "1" && env["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil,
                          "Run through scripts/e2e-live.sh, which launches the desktop fixture")
    }

    // MARK: - Helpers

    /// Launches the app paired, in memory, with the fixture desktop, and waits for its project.
    private func launchPaired(_ extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let invitation = ["CLUBHOUSE_COMPANION_TEST_INVITATION": env["CLUBHOUSE_COMPANION_TEST_INVITATION"] ?? ""]
        let launched = launchApp(extra, environment: invitation, allowance: 300, file: file, line: line)
        // An inactive project folds into the idle section.
        let listed = any(launched).matching(NSPredicate(format: "(identifier BEGINSWITH 'open-project-' AND label == %@) OR identifier == 'idle-projects-fold'",
                                                        "Open \(projectName)")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 60),
                      "Pairing with the fixture desktop must list its project", file: file, line: line)
        return launched
    }

    private func any(_ app: XCUIApplication) -> XCUIElementQuery { app.descendants(matching: .any) }
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { any(app).matching(identifier: identifier).firstMatch }
    private func element(_ app: XCUIApplication, idSuffix suffix: String) -> XCUIElement {
        any(app).matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch
    }
    private func projectHeader(_ app: XCUIApplication) -> XCUIElement {
        any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'open-project-' AND label == %@", "Open \(projectName)")).firstMatch
    }
    private func projectMenu(_ app: XCUIApplication) -> XCUIElement {
        any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'project-menu-' AND label == %@", "\(projectName) options")).firstMatch
    }
    private func agentRow(_ app: XCUIApplication, _ agentID: String) -> XCUIElement { element(app, idSuffix: "-\(agentID)") }
    private func text(_ app: XCUIApplication, beginsWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
    private func composer(_ app: XCUIApplication) -> XCUIElement { element(app, "companion-composer") }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens Home's idle section if an earlier test left the project inactive.
    private func revealProject(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let idle = element(app, "idle-projects-fold")
        if !projectHeader(app).exists && idle.exists { tapToExpand(idle, file: file, line: line) }
        XCTAssertTrue(projectHeader(app).waitForExistence(timeout: 10), "The project must be on Home", file: file, line: line)
    }

    /// Shows an agent's row on Home, opening the project's sleeping fold when it's in there.
    private func revealAgent(_ app: XCUIApplication, _ agentID: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        revealProject(app, file: file, line: line)
        let row = agentRow(app, agentID)
        if row.waitForExistence(timeout: 3) { scrollTo(row, in: app, file: file, line: line); return row }
        let fold = any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'fold-sleeping-'")).firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 10), "The agent must be on Home or in the sleeping fold", file: file, line: line)
        expandFold(fold, revealing: row, in: app, file: file, line: line)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The agent's row must show", file: file, line: line)
        return row
    }

    /// Opens an agent's chat from Home and wakes it with a new session if it sleeps, so the composer can send.
    private func openAwakeChat(_ app: XCUIApplication, _ agentID: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = revealAgent(app, agentID, file: file, line: line)
        let composer = composer(app)
        waitAndTap(row, until: composer, timeout: 15, "Selecting the agent must open its chat", file: file, line: line)
        let fresh = app.buttons["companion-wake-newSession"], wake = app.buttons["companion-wake"]
        if fresh.waitForExistence(timeout: 5) { fresh.tap() } else if wake.exists { wake.tap() }
        XCTAssertTrue(fresh.waitForNonExistence(timeout: 30) && wake.waitForNonExistence(timeout: 30),
                      "The desktop must wake the agent", file: file, line: line)
        // A request an earlier, failed attempt left waiting would hold the next turn.
        let leftover = app.buttons["Deny"]
        if leftover.waitForExistence(timeout: 3) { leftover.tap(); _ = leftover.waitForNonExistence(timeout: 15) }
    }

    /// Types into the composer and sends once the desktop says the agent can take a message.
    private func send(_ app: XCUIApplication, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = composer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15), file: file, line: line)
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["companion-send"]
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 30), "Send must enable for a live agent", file: file, line: line)
        send.tap()
    }

    /// Selects a text field's contents and types over them.
    private func replaceText(_ app: XCUIApplication, in field: XCUIElement, with text: String) {
        field.tap()
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue + text)
    }

    /// Waits until `query` has more than `count` matches.
    private func waitForMore(_ query: XCUIElementQuery, than count: Int, timeout: TimeInterval = 30) -> Bool {
        query.element(boundBy: count).waitForExistence(timeout: timeout)
    }

    private func backToHome(_ app: XCUIApplication) {
        let newAgent = app.navigationBars.buttons["New agent"]
        for _ in 0..<4 where !newAgent.exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            _ = newAgent.waitForExistence(timeout: 3)
        }
    }

    /// Requests desktop actions through the owned fixture. Replies carry an id so a stale reply cannot pass a retry.
    @discardableResult
    private func dispatcherFixture(_ op: String, _ fields: [String: Any] = [:],
                                   file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["CLUBHOUSE_E2E_FIXTURE_DIR"]))
        let id = UUID().uuidString
        var request = fields
        request["op"] = op; request["id"] = id
        try JSONSerialization.data(withJSONObject: request).write(to: dir.appending(path: "dispatcher-request.json"), options: .atomic)
        let done = dir.appending(path: "dispatcher-done.json")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let data = try? Data(contentsOf: done), let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == id {
                XCTAssertNil(reply["error"], "Fixture \(op): \(reply["error"] ?? "")", file: file, line: line)
                return reply["result"] ?? NSNull()
            }
            sleep(1)
        }
        XCTFail("Fixture \(op) did not answer", file: file, line: line)
        return NSNull()
    }

    private func dispatcherRow(_ app: XCUIApplication) -> XCUIElement {
        any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'dispatcher-row-' AND NOT identifier BEGINSWITH 'dispatcher-row-pending-'")).firstMatch
    }

    private func dispatcherSwitch(_ app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'dispatcher-enabled-'")).firstMatch
    }

    private func openDispatcherSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Agent settings"]
        waitAndTap(app.navigationBars.buttons["Conversation actions"], until: settings, timeout: 10)
        waitAndTap(settings, until: element(app, "agent-settings-model"), timeout: 15)
    }

    /// Toggle once and wait for the authoritative setting, without retrying the gesture.
    private func setSwitch(_ control: XCUIElement, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: 20), file: file, line: line)
        if (control.value as? String == "1") != on {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(waitFor(control, NSPredicate(format: "value == %@", on ? "1" : "0"), timeout: 30), file: file, line: line)
    }

    // MARK: - Tests

    /// Pairing, the catalog with the desktop's status words, and a foreground reconnect.
    func test1PairingCatalogAndReconnect() {
        let app = launchPaired()
        let builder = revealAgent(app, builderID)
        XCTAssertTrue(builder.label.contains("Builder"), builder.label)
        XCTAssertTrue(agentRow(app, echoID).exists, "Both fixture agents are listed")
        screenshot(app, "Home paired with the fixture desktop")

        openAwakeChat(app, echoID)
        send(app, "hello")
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 30), "The desktop must stream the CLI's reply")
        backToHome(app)
        let echo = revealAgent(app, echoID)
        let done = NSPredicate(format: "label CONTAINS 'Done'")
        XCTAssertTrue(waitFor(echo, done, timeout: 30), "An awake agent between turns reads Done, as on the desktop: \(echo.label)")
        XCTAssertTrue(builder.label.contains("Sleeping") || !builder.exists, "Builder still sleeps: \(builder.label)")

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        openAwakeChat(app, echoID)
        // The fake's replies reuse message ids, so count a fresh approval round trip instead of a second "Hello".
        let denials = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'denied:'"))
        let before = denials.count
        send(app, "tool")
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 30), "Coming back to the foreground must reconnect and stream a new request")
        deny.tap()
        XCTAssertTrue(waitForMore(denials, than: before), "The answer must reach the desktop after the reconnect")
        screenshot(app, "Chat after a foreground reconnect")
    }

    /// Chat streaming, then approvals: Deny, Allow, Always allow, and a structured question.
    func test2ChatStreamApprovalsAndQuestion() {
        let app = launchPaired()
        openAwakeChat(app, echoID)
        send(app, "hello")
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 30), "The streamed reply must arrive")

        let denials = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'denied:'"))
        let allowed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'allowed:'"))
        let rules = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'allowed:' AND label CONTAINS 'addRules'"))
        let deny = app.buttons["Deny"], allow = app.buttons["Allow"]

        var before = denials.count
        send(app, "tool")
        XCTAssertTrue(deny.waitForExistence(timeout: 30), "The desktop's permission request must show")
        screenshot(app, "Live approval")
        deny.tap()
        XCTAssertTrue(waitForMore(denials, than: before), "Deny must reach the CLI")

        before = allowed.count
        let rulesBefore = rules.count
        send(app, "tool")
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Allow is offered")
        allow.tap()
        XCTAssertTrue(waitForMore(allowed, than: before), "Allow must reach the CLI")
        XCTAssertEqual(rules.count, rulesBefore, "Allow once adds no rule")

        send(app, "tool")
        let always = app.buttons["companion-approval-option-allow_always"]
        XCTAssertTrue(always.waitForExistence(timeout: 30), "Allow and don't ask again is offered for the CLI's suggested rule")
        scrollTo(always, in: app, maxSwipes: 3)
        always.tap()
        // The phone may confirm a persistent rule first.
        let confirm = app.buttons.matching(NSPredicate(format: "(label == 'Always allow' OR label BEGINSWITH 'Allow and don') AND NOT (identifier BEGINSWITH 'companion-approval-option')")).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        XCTAssertTrue(waitForMore(rules, than: rulesBefore), "Always allow must send the rule to the CLI")
        screenshot(app, "Always allow reached the CLI")

        send(app, "ask")
        let sqlite = app.buttons["SQLite"]
        XCTAssertTrue(sqlite.waitForExistence(timeout: 30), "The structured question must arrive")
        scrollTo(sqlite, in: app, maxSwipes: 3)
        sqlite.tap()
        let answers = app.buttons["Send answers"]
        scrollTo(answers, in: app, maxSwipes: 3)
        answers.tap()
        let answered = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'answers:' AND label CONTAINS 'SQLite'")).firstMatch
        XCTAssertTrue(answered.waitForExistence(timeout: 30), "The answer must reach the CLI")
    }

    /// An image picked on the phone is uploaded, attached to the message, and reaches the CLI.
    func test3ImageUploadReachesTheCLI() {
        let app = launchPaired(["--companion-sample-images"])
        openAwakeChat(app, echoID)
        let attach = app.buttons["companion-attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15), "The desktop advertises image attachments")
        XCTAssertTrue(attach.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        attach.tap()
        XCTAssertTrue(app.images.matching(identifier: "companion-attachment-thumbnail").firstMatch.waitForExistence(timeout: 10))
        send(app, "picture")
        let echoed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'echo:picture' AND label CONTAINS 'images:1:image/png'")).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 30), "The CLI must receive the uploaded image")
        XCTAssertTrue(app.buttons.matching(identifier: "companion-message-image").firstMatch.exists, "The sent message shows its image")
        screenshot(app, "Image upload echoed by the CLI")
    }

    /// The composer's model and level menus switch the live session.
    func test4ModelAndLevelSwitch() {
        let app = launchPaired()
        openAwakeChat(app, echoID)
        send(app, "hello")
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 30), "A first turn reports the session's model")

        let model = element(app, "companion-model-menu")
        XCTAssertTrue(model.waitForExistence(timeout: 15), "The desktop offers model switching")
        let haiku = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Haiku'")).firstMatch
        waitAndTap(model, until: haiku, timeout: 10, "The session's models are offered")
        haiku.tap()
        XCTAssertTrue(waitFor(model, NSPredicate(format: "label CONTAINS 'Haiku'"), timeout: 30), "The chip shows the new model: \(model.label)")

        let level = element(app, "companion-level-menu")
        XCTAssertTrue(level.waitForExistence(timeout: 10), "The desktop offers level switching")
        let plan = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plan'")).firstMatch
        waitAndTap(level, until: plan, timeout: 10, "The live levels are offered")
        plan.tap()
        let header = element(app, "companion-chat-header")
        XCTAssertTrue(waitFor(header, NSPredicate(format: "label CONTAINS 'Plan'"), timeout: 30), "The header shows the new level: \(header.label)")
        screenshot(app, "Model and level switched")

        // Back to Ask first, so later tests still get permission prompts.
        let ask = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ask first'")).firstMatch
        waitAndTap(level, until: ask, timeout: 10)
        ask.tap()
        XCTAssertTrue(waitFor(header, NSPredicate(format: "label CONTAINS 'Ask first'"), timeout: 30))
    }

    /// New agent creates a durable agent on the desktop, and its settings change there.
    func test5CreateDurableAgentAndSettings() {
        let app = launchPaired()
        let name = "phone-\(Int(Date().timeIntervalSince1970) % 100000)"
        let newAgent = app.navigationBars.buttons["New agent"]
        let nameField = element(app, "new-agent-name")
        waitAndTap(newAgent, until: nameField, timeout: 15, "The desktop's create options must load")
        replaceText(app, in: nameField, with: name)
        let worktree = app.switches["new-agent-worktree"]
        if scrollUntilExists(worktree, in: app, maxSwipes: 4, wait: 0.5), worktree.value as? String == "1" {
            scrollTo(worktree, in: app)
            worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let create = app.buttons["new-agent-create"]
        XCTAssertTrue(create.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        create.tap()
        let created = element(app, "companion-created-agent")
        XCTAssertTrue(created.waitForExistence(timeout: 30), "The desktop must create the agent")
        screenshot(app, "Durable agent created on the desktop")
        let sheet = app.navigationBars["New agent"]
        for close in [app.buttons["Done"], sheet.buttons["Cancel"]] where sheet.exists && close.exists { close.tap() }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "The New agent sheet closes")
        backToHome(app)
        revealProject(app)

        // The desktop's snapshot lists it, asleep; its settings open from the row and change on the desktop.
        func row(_ label: String) -> XCUIElement {
            any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'agent-' AND label BEGINSWITH %@", "\(label),")).firstMatch
        }
        let fold = any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'fold-sleeping-'")).firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 20))
        expandFold(fold, revealing: row(name), in: app)
        XCTAssertTrue(row(name).waitForExistence(timeout: 20), "Home lists the new agent from the desktop")
        let settings = app.buttons["Agent settings"]
        longPressUntilMenu(row(name), shows: settings, "The new agent's menu offers its settings")
        let nameSetting = app.textFields["agent-settings-name"]
        waitAndTap(settings, until: nameSetting, timeout: 15, "The desktop's agent settings must load")
        XCTAssertEqual(nameSetting.value as? String, name)
        XCTAssertTrue(nameSetting.isEnabled, "A sleeping agent's settings can change")
        replaceText(app, in: nameSetting, with: "\(name)-renamed\n")
        XCTAssertTrue(waitFor(nameSetting, NSPredicate(format: "value == %@", "\(name)-renamed"), timeout: 20))
        element(app, "agent-color-amber").tap()
        XCTAssertTrue(waitFor(element(app, "agent-color-amber"), NSPredicate(format: "selected == true"), timeout: 20),
                      "The desktop must apply the new colour")
        XCTAssertFalse(element(app, "agent-settings-error").exists, "The desktop accepted every change")
        screenshot(app, "New agent's settings")
        waitAndTap(app.buttons["Done"], untilGone: nameSetting)
        if !row("\(name)-renamed").waitForExistence(timeout: 20) { expandFold(fold, revealing: row("\(name)-renamed"), in: app) }
        XCTAssertTrue(row("\(name)-renamed").waitForExistence(timeout: 20), "Home shows the name the desktop now has")
    }

    /// Pinning and marking a project inactive go to the desktop, so a fresh pairing sees them. It runs first, while every
    /// agent sleeps: Home never folds a project with an awake agent into the idle section, and the phone can't put one
    /// to sleep. A later run (`--only`, a retry) still checks the desktop's mark through the menu.
    func test0ProjectPinAndIdleSync() {
        var app = launchPaired()
        revealProject(app)
        let menu = projectMenu(app)
        scrollTo(menu, in: app)
        // A failed earlier attempt may have left it inactive.
        let markActive = app.buttons["Mark active"]
        let anyItem = app.buttons.matching(NSPredicate(format: "label IN {'Pin project', 'Unpin project'}")).firstMatch
        waitAndTap(menu, until: anyItem, timeout: 10, "The project menu opens")
        if markActive.exists {
            markActive.tap()
            XCTAssertTrue(element(app, "idle-projects-fold").waitForNonExistence(timeout: 20))
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            XCTAssertTrue(anyItem.waitForNonExistence(timeout: 5))
        }
        let pin = app.buttons["Pin project"], unpin = app.buttons["Unpin project"]
        let either = app.buttons.matching(NSPredicate(format: "label IN {'Pin project', 'Unpin project'}")).firstMatch
        waitAndTap(menu, until: either, timeout: 10, "The project menu offers pinning")
        if unpin.exists { unpin.tap(); waitAndTap(menu, until: pin, timeout: 10) }
        pin.tap()
        waitAndTap(projectMenu(app), until: unpin, timeout: 15, "The desktop must apply the pin")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()  // close the menu
        XCTAssertTrue(unpin.waitForNonExistence(timeout: 5))
        // Relaunching pairs again from scratch, so only the desktop can remember the pin.
        app.terminate()
        app = launchPaired()
        waitAndTap(projectMenu(app), until: app.buttons["Unpin project"], timeout: 10, "The desktop must keep the pin")
        screenshot(app, "Pin kept by the desktop")
        app.buttons["Unpin project"].tap()

        waitAndTap(projectMenu(app), until: app.buttons["Mark inactive"], timeout: 10, "An unpinned active project can be marked inactive")
        // Awake agents show as rows on Home; sleeping ones are folded away.
        let awake = any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'agent-'")).firstMatch.exists
        app.buttons["Mark inactive"].tap()
        let idleFold = element(app, "idle-projects-fold")
        if !awake { XCTAssertTrue(idleFold.waitForExistence(timeout: 20), "An inactive project folds into the idle section") }
        app.terminate()
        app = launchPaired()
        let fold = element(app, "idle-projects-fold")
        if !awake { XCTAssertTrue(fold.waitForExistence(timeout: 20), "The desktop must keep the inactive mark") }
        revealProject(app)
        waitAndTap(projectMenu(app), until: app.buttons["Mark active"], timeout: 10, "The desktop must keep the inactive mark")
        screenshot(app, "Inactive mark kept by the desktop")
        app.buttons["Mark active"].tap()
        XCTAssertTrue(fold.waitForNonExistence(timeout: 20), "Mark active brings the project back")
        waitAndTap(projectMenu(app), until: app.buttons["Mark inactive"], timeout: 10, "The desktop must clear the mark")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }

    /// A quick agent started from the phone finishes on the desktop and shows under "Finished, waiting on you",
    /// where Dismiss removes it on the desktop. Its task is the fake CLI's `crash`, which exits at once. It runs last.
    func test7FinishedQuickAgent() {
        let app = launchPaired()
        let newAgent = app.navigationBars.buttons["New agent"]
        let kind = element(app, "new-agent-kind")
        waitAndTap(newAgent, until: kind, timeout: 15)
        kind.buttons["Quick"].tap()
        let task = app.textFields["Agent task"].exists ? app.textFields["Agent task"] : app.textViews["Agent task"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        task.typeText("crash")
        app.buttons["Start agent"].tap()
        XCTAssertTrue(kind.waitForNonExistence(timeout: 30), "The desktop must start the quick agent")
        backToHome(app)

        revealProject(app)
        let header = projectHeader(app)
        scrollTo(header, in: app)
        waitAndTap(header, until: app.buttons["project-terminal"], timeout: 15, "The project page opens")
        let finished = any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'finished-' AND label CONTAINS 'crash'")).firstMatch
        XCTAssertTrue(scrollUntilExists(finished, in: app, maxSwipes: 6, wait: 10), "The finished quick agent must be listed from the desktop")
        screenshot(app, "Finished quick agent")
        scrollTo(finished, in: app)
        finished.swipeLeft()
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(finished.waitForNonExistence(timeout: 20), "Dismiss must clear it on the desktop")
    }

    /// Terminals: the project root shell and Builder's worktree shell spawn, echo, resize with rotation, and close.
    func test6ProjectAndAgentTerminals() {
        let app = launchPaired()
        let output = element(app, "terminal-output")
        func waitForOutput(_ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(waitFor(output, NSPredicate(format: "value CONTAINS %@", text), timeout: timeout),
                          "The terminal must show \"\(text)\"; it shows \(String(describing: output.value))", file: file, line: line)
        }

        revealProject(app)
        let header = projectHeader(app)
        scrollTo(header, in: app)
        let terminal = app.buttons["project-terminal"]
        waitAndTap(header, until: terminal, timeout: 15)
        waitAndTap(terminal, until: output, timeout: 20, "The desktop must spawn the project shell")
        app.typeText("echo phone-$((6*7))\n")
        waitForOutput("phone-42")
        // Short markers: a long line wraps at the phone's width.
        app.typeText("echo \"dir=$(basename \"$PWD\")\"\n")
        waitForOutput("dir=\(projectName)")
        app.typeText("stty size\n")
        sleep(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = waitFor(app.windows.firstMatch, NSPredicate(format: "frame.size.width > frame.size.height"), timeout: 10)
        sleep(2)
        app.typeText("stty size\n")
        let resized = waitFor(output, NSPredicate { value, _ in
            guard let text = (value as? XCUIElement)?.value as? String else { return false }
            let sizes = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.range(of: #"^\d+ \d+$"#, options: .regularExpression) != nil }
            return sizes.count >= 2 && sizes[0] != sizes[sizes.count - 1]
        }, timeout: 20)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(resized, "Rotating must resize the desktop's pty: \(String(describing: output.value))")
        screenshot(app, "Project terminal")
        waitAndTap(app.buttons["terminal-done"], untilGone: output, timeout: 10, "Done closes the shell")

        backToHome(app)
        let builder = revealAgent(app, builderID)
        let agentTerminal = app.buttons["Terminal"]
        longPressUntilMenu(builder, shows: agentTerminal, "Builder's menu offers its shell")
        waitAndTap(agentTerminal, until: output, timeout: 20, "The desktop must spawn the agent's shell")
        app.typeText("echo \"dir=$(basename \"$PWD\")\"\n")
        waitForOutput("dir=Builder")
        app.typeText("echo \"br=$(git branch --show-current)\"\n")
        waitForOutput("br=Builder/standby")
        screenshot(app, "Agent worktree terminal")
        waitAndTap(app.buttons["terminal-done"], untilGone: output, timeout: 10)
    }

    /// An agent awake when the phone went to the background, put to sleep on the desktop meanwhile, reads Sleeping
    /// when the phone comes back, on Home, without opening its chat.
    func test8AgentThatSleptWhileAwayReadsSleepingAfterForeground() throws {
        let fixtureDir = try XCTUnwrap(env["CLUBHOUSE_E2E_FIXTURE_DIR"], "Run through scripts/e2e-live.sh, which passes the fixture folder")
        let app = launchPaired()
        openAwakeChat(app, echoID)
        send(app, "hello")
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 30), "The desktop must stream the CLI's reply")
        backToHome(app)
        let echo = revealAgent(app, echoID)
        XCTAssertTrue(waitFor(echo, NSPredicate(format: "label CONTAINS 'Done'"), timeout: 30), "Echo is awake between turns: \(echo.label)")

        XCUIDevice.shared.press(.home)
        let done = URL(fileURLWithPath: fixtureDir).appending(path: "sleep-done")
        try? FileManager.default.removeItem(at: done)
        try echoID.write(to: URL(fileURLWithPath: fixtureDir).appending(path: "sleep-request"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { sleep(1) }
        let answer = (try? String(contentsOf: done, encoding: .utf8)) ?? "no answer"
        XCTAssertTrue(answer.contains("ok"), "The fixture desktop must put Echo to sleep: \(answer)")
        sleep(2)

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let row = revealAgent(app, echoID)
        XCTAssertTrue(waitFor(row, NSPredicate(format: "label CONTAINS 'Sleeping'"), timeout: 30),
                      "An agent that slept while the phone was away must read Sleeping after it comes back: \(row.label)")
        screenshot(app, "Home after an agent slept while the phone was away")
    }
    /// Runs after the existing tests: the Dispatcher is disabled until this point so test0's idle rules still hold.
    func test9aDispatcherPhoneSwitchDesktopChangesAndReplay() throws {
        try dispatcherFixture("setEnabled", ["enabled": false])
        let app = launchPaired()
        let row = dispatcherRow(app)
        XCTAssertFalse(row.exists)
        let toggle = dispatcherSwitch(app)
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 15)
        XCTAssertTrue(toggle.isEnabled, "The fixture must seed both the experimental flag and New layout")
        setSwitch(toggle, on: true)
        let state = try XCTUnwrap(try dispatcherFixture("state") as? [String: Any])
        XCTAssertEqual(state["enabled"] as? Bool, true, "The phone command must change the desktop")
        setSwitch(toggle, on: false)
        XCTAssertEqual((try dispatcherFixture("state") as? [String: Any])?["enabled"] as? Bool, false)
        waitAndTap(app.buttons["Done"], untilGone: toggle)
        XCTAssertFalse(row.exists)

        // A change made on desktop while connected must arrive without reopening or refreshing Home.
        try dispatcherFixture("setEnabled", ["enabled": true])
        XCTAssertTrue(row.waitForExistence(timeout: 30), "dispatcher:changed and its snapshot must add the row")
        XCTAssertLessThan(row.frame.minY, projectHeader(app).frame.minY, "Dispatcher is pinned above projects")
        screenshot(app, "Dispatcher enabled on desktop while phone connected")
        try dispatcherFixture("setEnabled", ["enabled": false])
        XCTAssertTrue(row.waitForNonExistence(timeout: 30))

        XCUIDevice.shared.press(.home)
        sleep(3)
        try dispatcherFixture("setEnabled", ["enabled": true])
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The background change must catch up after reconnect")
        let frames = try XCTUnwrap(try dispatcherFixture("wire") as? [[String: Any]])
        let changes = frames.enumerated().filter { $0.element["type"] as? String == "dispatcher:changed" && $0.element["replayed"] as? Bool != true }
        XCTAssertGreaterThanOrEqual(changes.count, 5, "Observe both phone and desktop changes on the real wire")
        for change in changes {
            let enabled = (change.element["payload"] as? [String: Any])?["enabled"] as? Bool
            XCTAssertTrue(frames.dropFirst(change.offset + 1).contains { frame in
                guard frame["type"] as? String == "snapshot", frame["replayed"] as? Bool != true,
                      let payload = frame["payload"] as? [String: Any] else { return false }
                return enabled == (payload["dispatcher"] is [String: Any])
            }, "Every change must be followed by the corresponding real snapshot")
        }
        XCTAssertTrue(frames.contains { $0["type"] as? String == "dispatcher:changed" && $0["replayed"] as? Bool == true },
                      "The actual desktop replay buffer must retain Dispatcher changes")
        screenshot(app, "Dispatcher after phone reconnect")
    }

    func test9bDispatcherChatSettingsSleepWakeAndResume() throws {
        let state = try XCTUnwrap(try dispatcherFixture("setEnabled", ["enabled": true]) as? [String: Any])
        let id = try XCTUnwrap(state["agentId"] as? String)
        let app = launchPaired()
        let row = dispatcherRow(app)
        waitAndTap(row, until: composer(app), timeout: 20)
        let wake = app.buttons["companion-wake"]
        if wake.waitForExistence(timeout: 3) { wake.tap() }
        XCTAssertTrue(wake.waitForNonExistence(timeout: 30))
        send(app, "hello")
        XCTAssertTrue(app.staticTexts["Hello"].waitForExistence(timeout: 30), "Dispatcher must stream the scripted CLI reply")
        XCTAssertTrue(element(app, "companion-chat-header").label.contains("/ Dispatcher"))
        openDispatcherSettings(app)
        for field in ["orchestrator", "model", "runtime", "auto-sleep", "free-agent-mode"] {
            let control = element(app, "agent-settings-\(field)")
            XCTAssertTrue(scrollUntilExists(control, in: app, maxSwipes: 5), "Dispatcher exposes \(field)")
            XCTAssertTrue(control.isEnabled, "Dispatcher \(field) is editable even while awake")
        }
        for field in ["name", "emoji", "persona", "orchestrate"] {
            XCTAssertFalse(element(app, "agent-settings-\(field)").exists, "Dispatcher \(field) is locked")
        }
        let response = try XCTUnwrap(try dispatcherFixture("settings", ["agentId": id]) as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        let body = try XCTUnwrap(response["body"] as? [String: Any])
        let settings = try XCTUnwrap(body["settings"] as? [String: Any])
        for field in ["orchestrator", "model", "runtime", "freeAgentMode", "idleSleep"] {
            XCTAssertEqual((settings[field] as? [String: Any])?["editable"] as? String, "always", field)
        }
        for field in ["name", "color", "emoji", "persona", "clubhouseMode"] {
            XCTAssertEqual((settings[field] as? [String: Any])?["editable"] as? String, "never", field)
        }
        screenshot(app, "Real Dispatcher settings while awake")
        waitAndTap(app.buttons["Done"], untilGone: element(app, "agent-settings-model"))
        // There is no phone Sleep action. Stop through the desktop's real mobile command, as a desktop stop would.
        let stop = try XCTUnwrap(try dispatcherFixture("command", ["fields": ["type": "agent.stop", "agentId": id]]) as? [String: Any])
        XCTAssertEqual(stop["status"] as? Int, 200)
        XCTAssertTrue(wake.waitForExistence(timeout: 30), "The phone sees the Dispatcher sleep")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(wake.waitForExistence(timeout: 30))
        XCTAssertTrue(wake.label.contains("Resume"), "A Dispatcher with a saved session offers resume: \(wake.label)")
        wake.tap()
        XCTAssertTrue(wake.waitForNonExistence(timeout: 30))
        send(app, "dispatcher resumed")
        XCTAssertTrue(text(app, beginsWith: "echo:dispatcher resumed").waitForExistence(timeout: 30), "Sending works after reconnect and resume")
        screenshot(app, "Dispatcher resumed after phone reconnect")
    }

    func test9cAgentDispatcherSwitchesAndRealMCPDelivery() throws {
        let state = try XCTUnwrap(try dispatcherFixture("setEnabled", ["enabled": true]) as? [String: Any])
        let id = try XCTUnwrap(state["agentId"] as? String)
        let app = launchPaired()
        // Start Dispatcher when running this test alone; the fake wrapper records its bridge credentials.
        waitAndTap(dispatcherRow(app), until: composer(app), timeout: 20)
        if app.buttons["companion-wake"].waitForExistence(timeout: 3) { app.buttons["companion-wake"].tap() }
        XCTAssertTrue(app.buttons["companion-wake"].waitForNonExistence(timeout: 30))
        backToHome(app)
        let row = revealAgent(app, echoID)
        let settingsAction = app.buttons["Agent settings"]
        longPressUntilMenu(row, shows: settingsAction)
        let orchestrate = app.switches["agent-settings-orchestrate"]
        waitAndTap(settingsAction, until: element(app, "agent-settings-name"), timeout: 15)
        XCTAssertTrue(scrollUntilExists(orchestrate, in: app, maxSwipes: 6))
        scrollTo(orchestrate, in: app)
        setSwitch(orchestrate, on: true)
        let connect = app.switches["agent-settings-orchestrate-dispatcher"]
        XCTAssertTrue(scrollUntilExists(connect, in: app, maxSwipes: 5))
        scrollTo(connect, in: app)
        setSwitch(connect, on: false)
        var policy = try XCTUnwrap(try dispatcherFixture("policy") as? [String: Any])
        XCTAssertEqual((policy["policy"] as? [String: Any])?["connectToDispatcher"] as? Bool, false)
        setSwitch(connect, on: true)
        policy = try XCTUnwrap(try dispatcherFixture("policy") as? [String: Any])
        XCTAssertEqual((policy["policy"] as? [String: Any])?["connectToDispatcher"] as? Bool, true)
        XCTAssertTrue((policy["bindings"] as? [[String: Any]])?.contains { $0["agentId"] as? String == id && $0["targetId"] as? String == echoID } == true)
        // Reset Echo asleep so wake_agent really starts it, then let the real Dispatcher tool drive its lifecycle.
        waitAndTap(app.buttons["Done"], untilGone: orchestrate)
        try dispatcherFixture("command", ["fields": ["type": "agent.stop", "agentId": echoID]])
        try dispatcherFixture("mcp", ["agentId": id, "target": "echo", "tool": "wake_agent", "args": ["message": "PHONE_DISPATCHER_WAKE"]])
        let awake = revealAgent(app, echoID)
        XCTAssertTrue(waitFor(awake, NSPredicate(format: "NOT label CONTAINS 'Sleeping'"), timeout: 30))
        try dispatcherFixture("mcp", ["agentId": id, "target": "echo", "tool": "send_message", "args": ["message": "PHONE_DISPATCHER_DELIVERY", "task_id": "phone-live-dispatcher"]])
        waitAndTap(awake, until: composer(app), timeout: 15)
        let delivered = text(app, beginsWith: "PHONE_DISPATCHER_DELIVERY")
        XCTAssertTrue(delivered.waitForExistence(timeout: 30), "Real MCP send_message text must reach phone")
        let caption = any(app).matching(NSPredicate(format: "identifier == 'companion-message-source' AND label CONTAINS 'From Dispatcher'")).firstMatch
        XCTAssertTrue(caption.exists, "Real MCP message is captioned with its sender")
        screenshot(app, "Real MCP delivery from Dispatcher")
        let frames = try XCTUnwrap(try dispatcherFixture("wire") as? [[String: Any]])
        let deliveredEvent = try XCTUnwrap(frames.compactMap { frame -> [String: Any]? in
            guard let payload = frame["payload"] as? [String: Any], let event = payload["event"] as? [String: Any],
                  let data = event["data"] as? [String: Any], data["source"] as? String == "mcp",
                  String(describing: data["content"]).contains("PHONE_DISPATCHER_DELIVERY") else { return nil }
            return data
        }.first, "The delivered message must be a real MCP user_message on the wire")
        if let routed = deliveredEvent["routed"] as? [[String: Any]] {
            XCTAssertEqual(routed.first?["text"] as? String, "PHONE_DISPATCHER_DELIVERY")
            XCTAssertEqual((routed.first?["sender"] as? [String: Any])?["name"] as? String, "Dispatcher")
        }

        backToHome(app)
        try dispatcherFixture("mcp", ["agentId": id, "target": "echo", "tool": "sleep_agent", "args": ["force": true]])
        let asleep = revealAgent(app, echoID)
        XCTAssertTrue(waitFor(asleep, NSPredicate(format: "label CONTAINS 'Sleeping'"), timeout: 30))
        longPressUntilMenu(asleep, shows: settingsAction)
        waitAndTap(settingsAction, until: element(app, "agent-settings-name"), timeout: 15)
        scrollTo(orchestrate, in: app)
        setSwitch(orchestrate, on: false)
        XCTAssertEqual(((try dispatcherFixture("policy") as? [String: Any])?["policy"] as? [String: Any])?["orchestrate"] as? Bool, false)
        setSwitch(orchestrate, on: true)
        waitAndTap(app.buttons["Done"], untilGone: orchestrate)
        // Contract-only MCP-off checks; the phone's disabled-switch UX awaits its separate PR.
        try dispatcherFixture("mcpEnabled", ["enabled": false])
        let disabled = try XCTUnwrap(try dispatcherFixture("settings", ["agentId": echoID]) as? [String: Any])
        let disabledBody = try XCTUnwrap(disabled["body"] as? [String: Any])
        XCTAssertEqual((disabledBody["orchestration"] as? [String: Any])?["mcpEnabled"] as? Bool, false)
        for field in ["orchestrate", "connectToDispatcher", "crossProjectHelpers"] {
            let refused = try XCTUnwrap(try dispatcherFixture("command", ["fields": ["type": "agent.update", "agentId": echoID,
                "orchestration": [field: true]]]) as? [String: Any])
            XCTAssertEqual(refused["status"] as? Int, 409)
            XCTAssertTrue(String(describing: refused["body"]).contains("mcp_off"))
        }
        try dispatcherFixture("mcpEnabled", ["enabled": true])
        // Dispatcher off rejects writes even if an older settings sheet still offered Connect.
        try dispatcherFixture("setEnabled", ["enabled": false])
        let refusal = try XCTUnwrap(try dispatcherFixture("command", ["fields": ["type": "agent.update", "agentId": echoID, "orchestration": ["connectToDispatcher": true]]]) as? [String: Any])
        XCTAssertEqual(refusal["status"] as? Int, 409)
        XCTAssertTrue(String(describing: refusal["body"]).contains("dispatcher_off"))
        try dispatcherFixture("flag", ["enabled": false])
        let flagRefusal = try XCTUnwrap(try dispatcherFixture("command", ["fields": ["type": "dispatcher.setEnabled", "enabled": true]]) as? [String: Any])
        XCTAssertEqual(flagRefusal["status"] as? Int, 409)
        XCTAssertTrue(String(describing: flagRefusal["body"]).contains("dispatcher_flag_off"))
        let toggle = dispatcherSwitch(app)
        waitAndTap(app.buttons["Settings"], until: toggle, timeout: 15)
        XCTAssertFalse(toggle.isEnabled, "The phone cannot turn on the desktop's experimental flag")
        let note = any(app).matching(NSPredicate(format: "identifier BEGINSWITH 'dispatcher-enabled-note-'")).firstMatch
        XCTAssertTrue(note.label.contains("Experimental"), note.label)
        try dispatcherFixture("flag", ["enabled": true])
        XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        waitAndTap(app.buttons["Done"], untilGone: toggle)
    }

    func test9dDispatcherSettingsSaveAndLockedFieldsRefuse() throws {
        let state = try XCTUnwrap(try dispatcherFixture("setEnabled", ["enabled": true]) as? [String: Any])
        let id = try XCTUnwrap(state["agentId"] as? String)
        let app = launchPaired()
        waitAndTap(dispatcherRow(app), until: composer(app), timeout: 20)
        openDispatcherSettings(app)
        func pick(_ field: String, _ option: String) {
            let control = element(app, "agent-settings-\(field)")
            scrollTo(control, in: app)
            let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", option)).firstMatch
            waitAndTap(control, until: choice, timeout: 10)
            choice.tap()
            XCTAssertTrue(choice.waitForNonExistence(timeout: 15))
        }
        pick("model", "Haiku")
        pick("runtime", "Chat")
        pick("auto-sleep", "After 15 min idle")
        let free = app.switches["agent-settings-free-agent-mode"]
        scrollTo(free, in: app)
        setSwitch(free, on: false)
        let saved = try XCTUnwrap(try dispatcherFixture("state") as? [String: Any])
        let config = try XCTUnwrap(saved["config"] as? [String: Any])
        XCTAssertTrue((config["model"] as? String)?.contains("haiku") == true, "The phone model choice persists on desktop")
        XCTAssertEqual(config["runtimeMode"] as? String, "chat")
        XCTAssertEqual(config["idleSleep"] as? Int, 15)
        // Desktop canonicalizes false by removing the stored flag; its settings route returns explicit false.
        XCTAssertFalse(config["freeAgentMode"] as? Bool ?? false)
        let response = try XCTUnwrap(try dispatcherFixture("settings", ["agentId": id]) as? [String: Any])
        let body = try XCTUnwrap(response["body"] as? [String: Any])
        let persisted = try XCTUnwrap(body["settings"] as? [String: Any])
        XCTAssertEqual((persisted["freeAgentMode"] as? [String: Any])?["value"] as? Bool, false)
        XCTAssertFalse(element(app, "agent-settings-error").exists)
        screenshot(app, "Dispatcher settings saved on real desktop")
        waitAndTap(app.buttons["Done"], untilGone: element(app, "agent-settings-model"))
        for fields: [String: Any] in [["name": "renamed"], ["color": "blue"], ["emoji": "X"], ["persona": "default"],
                                      ["clubhouseMode": true], ["orchestration": ["orchestrate": true]]] {
            var command = fields
            command["type"] = "agent.update"; command["agentId"] = id
            let result = try XCTUnwrap(try dispatcherFixture("command", ["fields": command]) as? [String: Any])
            XCTAssertEqual(result["status"] as? Int, 409)
            XCTAssertTrue(String(describing: result["body"]).contains("dispatcher_locked"), "Locked write: \(fields)")
        }
        // Keep the fixture deterministic for retries: these settings apply next start, no CLI is invoked here.
        let reset = try XCTUnwrap(try dispatcherFixture("command", ["fields": ["type": "agent.update", "agentId": id,
            "orchestrator": "claude-code", "model": "default", "runtime": "chat", "idleSleep": "never", "freeAgentMode": true]]) as? [String: Any])
        XCTAssertEqual(reset["status"] as? Int, 200)
    }

}
