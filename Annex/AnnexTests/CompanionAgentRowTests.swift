import XCTest
import SwiftUI
import Vision
@testable import ClubhouseGo

@MainActor final class CompanionAgentRowTests: XCTestCase {
    private var agent: CompanionAgent {
        .init(id: .init(hostID: "studio", projectID: "clubhouse", agentID: "river"),
              name: "River", subtitle: "Build the mobile companion", status: .approval, access: .ask)
    }

    func testAccessBadgeIsHiddenWhenItMatchesKnownDefault() {
        let context = CompanionAgentRowContext(
            projectAccessDefaults: [.init(hostID: "studio", projectID: "clubhouse"): .ask])
        XCTAssertNil(context.accessBadge(for: agent))
    }

    func testAccessBadgeIsShownWhenItDiffersFromKnownDefault() {
        let context = CompanionAgentRowContext(
            projectAccessDefaults: [.init(hostID: "studio", projectID: "clubhouse"): .auto])
        XCTAssertEqual(context.accessBadge(for: agent), .ask)
    }

    func testAccessBadgeIsShownWhenDefaultIsUnknown() {
        XCTAssertEqual(CompanionAgentRowContext().accessBadge(for: agent), .ask,
                       "Unknown is not evidence that access is the default")
    }

    func testAgentSpecificDefaultWinsOverProjectDefault() {
        let context = CompanionAgentRowContext(
            projectAccessDefaults: [.init(hostID: "studio", projectID: "clubhouse"): .ask],
            agentAccessDefaults: [agent.id: .auto])
        XCTAssertEqual(context.accessBadge(for: agent), .ask)
        var elevated = agent
        elevated.access = .auto
        XCTAssertNil(context.accessBadge(for: elevated))
    }

    func testHostTagRequiresMultipleHostsAndNoImpliedHost() {
        var context = CompanionAgentRowContext(hostNames: ["studio": "Studio Mac"])
        XCTAssertNil(context.hostTag(for: agent.id, fallback: "Studio Mac"))
        context.hostNames["travel"] = "Travel Mac"
        XCTAssertEqual(context.hostTag(for: agent.id), "Studio Mac")
        context.impliedHostID = "studio"
        XCTAssertNil(context.hostTag(for: agent.id, fallback: "Studio Mac"))
    }

    func testProjectOriginWinsOverImpliedHostAndEmptyMapPreservesSuppression() {
        var context = CompanionAgentRowContext(hostNames: ["studio": "Studio Mac"], impliedHostID: "studio",
            projectOriginLabels: [.init(hostID: "studio", projectID: "clubhouse"): "Studio Mac · Clubhouse"])
        XCTAssertEqual(context.hostTag(for: agent.id), "Studio Mac · Clubhouse")
        context.projectOriginLabels = [:]
        XCTAssertNil(context.hostTag(for: agent.id, fallback: "Studio Mac"))
    }

    func testPermissionStatusDoesNotRepeatAttentionLabel() {
        var value = agent
        value.detail = .init(state: "needs_permission", message: "Run xcodebuild", toolName: "Bash")
        let line = CompanionAgentStatusLine(agent: value, detail: "Needs permission to use Bash")
        XCTAssertEqual(line.status, "Needs permission")
        XCTAssertEqual(line.task, "Run xcodebuild")
        value.detail?.message = "Needs permission"
        XCTAssertEqual(CompanionAgentStatusLine(agent: value).task, value.subtitle)
        value.subtitle = ""
        XCTAssertEqual(CompanionAgentStatusLine(agent: value).task, "Bash")
    }

    func testLivePermissionToolWinsOverDifferentCatalogTool() {
        var value = agent
        value.detail = .init(state: "needs_permission", message: "Run stale command", toolName: "Bash")
        let line = CompanionAgentStatusLine(agent: value, detail: "Needs permission to use Edit")
        XCTAssertEqual(line.status, "Needs permission")
        XCTAssertEqual(line.task, "Edit", "Use the live approval's tool, not the stale catalog task")
    }

    func testLivePermissionToolSurvivesMissingCatalogTool() {
        let line = CompanionAgentStatusLine(agent: agent, detail: "Needs permission to use Edit")
        XCTAssertEqual(line.status, "Needs permission")
        XCTAssertEqual(line.task, "Edit")
    }

    func testMissingSuppliedPermissionToolKeepsUsefulTask() {
        var value = agent
        value.detail = .init(state: "needs_permission", message: "Review requested action", toolName: "Bash")
        for detail in ["Needs permission", "Needs permission to use", "Needs permission to use   "] {
            XCTAssertEqual(CompanionAgentStatusLine(agent: value, detail: detail).task, "Review requested action")
        }
    }

    func testPermissionNormalizationLeavesOtherStatesAndTaskLabelsAlone() {
        var value = agent
        let states: [CompanionAgentStatus] = [.working, .waiting, .failed]
        for status in states {
            value.status = status
            let detail = "Needs permission to use Edit"
            XCTAssertEqual(CompanionAgentStatusLine(agent: value, detail: detail).task, detail)
        }
        value.status = .approval
        XCTAssertEqual(CompanionAgentStatusLine(agent: value, detail: "Review the generated patch").task,
                       "Review the generated patch")
    }

    func testLivePermissionRowAtNarrowWidthAndAccessibilityText() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var value = agent
        value.detail = .init(state: "needs_permission", message: "Stale command", toolName: "Bash")
        for (name, type, scheme) in [("narrow light", DynamicTypeSize.large, ColorScheme.light),
                                     ("narrow dark", .large, .dark), ("AX3", .accessibility3, .light)] {
            let content = VStack {
                CompanionAgentListRow(agent: value, detail: "Needs permission to use Edit")
                    .background(CompanionCardBackground())
                Spacer()
            }.padding(16).dynamicTypeSize(type).companionBackground()
                .companionTheme(.clubhouse).environment(\.colorScheme, scheme)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            window.layoutIfNeeded(); hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            // Fixture: 16pt padding + 32pt avatar + 12pt gap puts labels at x60.
            // Exclude only the avatar (including its status dot), leaving 4pt before labels.
            let full = try XCTUnwrap(image.cgImage)
            let left = 56 * image.scale
            let crop = try XCTUnwrap(full.cropping(to: CGRect(x: left, y: 0,
                width: CGFloat(full.width) - left, height: CGFloat(full.height))))
            let croppedPixels = XCTAttachment(image: UIImage(cgImage: crop, scale: image.scale, orientation: .up))
            croppedPixels.name = "573 permission row label crop \(name)"; croppedPixels.lifetime = .keepAlways
            add(croppedPixels)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
            let pixels = XCTAttachment(image: image); pixels.name = "573 permission row \(name)"; pixels.lifetime = .keepAlways
            add(pixels)
            let words = XCTAttachment(string: text); words.name = "573 permission row OCR \(name)"; words.lifetime = .keepAlways
            add(words)
            XCTAssertTrue(text.contains("Needs permission") && text.contains("Edit"), text)
            XCTAssertEqual(text.components(separatedBy: "Needs permission").count - 1, 1, text)
            XCTAssertFalse(text.contains("Bash") || text.contains("Stale command"), text)
        }
    }

    func testQuestionAndOrdinaryTaskKeepOneStateAndUsefulDetail() {
        var value = agent
        value.status = .waiting
        value.detail = .init(state: "needs_input", message: "Which simulator should I use?")
        let question = CompanionAgentStatusLine(agent: value, detail: CompanionAttentionItem.questionLine)
        XCTAssertEqual(question.status, "Has a question")
        XCTAssertEqual(question.task, "Which simulator should I use?")
        value.status = .working
        value.detail = nil
        XCTAssertEqual(CompanionAgentStatusLine(agent: value).status, "Working")
        XCTAssertEqual(CompanionAgentStatusLine(agent: value).task, value.subtitle)
        XCTAssertEqual(CompanionAgentStatusLine(agent: value, detail: "Inspecting reconnect behavior").task, "Inspecting reconnect behavior")
    }

    func testExistingReadsRetainDefaultsAndDisconnectClearsThem() async throws {
        let store = CompanionStore(service: CompanionPreviewService())
        let host = try XCTUnwrap(CompanionPreviewService.hosts(now: Date()).first)
        store.apply(.hosts([host]))
        let project = CompanionProjectTarget(hostID: host.id, projectID: "clubhouse")
        let target = try XCTUnwrap(host.projects.first { $0.id == project.projectID }?.agents.first?.id)
        XCTAssertTrue(store.projectAccessDefaults.isEmpty && store.agentAccessDefaults.isEmpty)
        let options = try await store.createOptions(for: project)
        XCTAssertEqual(store.projectAccessDefaults[project], options.defaultAccess)
        let settings = try await store.settings(for: target)
        XCTAssertEqual(store.agentAccessDefaults[target], settings.access?.defaultLevel)
        var offline = host
        offline.connection = .offline
        store.apply(.hosts([offline]))
        XCTAssertTrue(store.projectAccessDefaults.isEmpty && store.agentAccessDefaults.isEmpty)
        store.shutdown()
        _ = try await store.createOptions(for: project)
        XCTAssertTrue(store.projectAccessDefaults.isEmpty, "A late read must not repopulate a shut-down store")
    }

    func testQuietFoldCombinesSleepingAndFinishedWithoutEmptyGroups() {
        let preferences = CompanionPreferences()
        var sleeping = agent
        sleeping.status = .sleeping
        var quick = agent
        quick.id.agentID = "quick"
        quick.isQuick = true
        quick.hasExited = true
        quick.status = .completed
        let tree = CompanionAgentTree.build([sleeping, quick], sort: .alphabetical, lastActivity: { _ in nil })
        XCTAssertEqual(CompanionAgentTreeQuietFold(projectID: "clubhouse", tree: tree, preferences: preferences).text,
                       "1 sleeping · 1 finished quick agent")
        let finishedOnly = CompanionAgentTree(active: [], sleeping: [], finishedQuick: tree.finishedQuick)
        XCTAssertEqual(CompanionAgentTreeQuietFold(projectID: "clubhouse", tree: finishedOnly, preferences: preferences).text,
                       "1 finished quick agent")
        let empty = CompanionAgentTree(active: [], sleeping: [], finishedQuick: [])
        XCTAssertEqual(CompanionAgentTreeQuietFold(projectID: "clubhouse", tree: empty, preferences: preferences).text, "")
    }

    func testRowVisualMatrixAndAccessibleGrowth() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let mocha = CompanionDesktopTheme(id: "mocha", name: "Mocha", source: "Desktop", mode: .dark,
            colors: ["base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4",
                     "subtext0": "#a6adc8", "surface0": "#313244", "accent": "#cba6f7", "warning": "#f9e2af",
                     "success": "#a6e3a1", "error": "#f38ba8", "info": "#89b4fa"], gradient: [])
        let daybreak = CompanionDesktopTheme(id: "daybreak", name: "Daybreak", source: "Desktop", mode: .light,
            colors: ["base": "#fffaf3", "mantle": "#f8f0e3", "crust": "#eee4d2", "text": "#3e342e",
                     "subtext0": "#77685e", "surface0": "#ede3d5", "accent": "#9a5c35", "warning": "#ab6400",
                     "success": "#28784c", "error": "#b93b37", "info": "#326a9d"], gradient: [])
        let variants: [(String, CompanionDesktopTheme, ColorScheme, DynamicTypeSize)] = [
            ("Light", .clubhouse, .light, .large), ("Dark", .clubhouse, .dark, .large),
            ("Mocha desktop theme", mocha, .dark, .large), ("Daybreak desktop theme", daybreak, .light, .large),
            ("Accessibility AX3", .clubhouse, .light, .accessibility3)
        ]
        let project = CompanionProjectTarget(hostID: "studio", projectID: "clubhouse")
        let context = CompanionAgentRowContext(hostNames: ["studio": "Studio Mac", "travel": "Travel Mac"],
                                               projectAccessDefaults: [project: .ask])
        var cedar = agent
        cedar.name = "Cedar"
        cedar.id.agentID = "cedar"
        cedar.access = .auto
        cedar.status = .working
        cedar.subtitle = "Investigate reconnect behavior"
        var river = agent
        river.detail = .init(state: "needs_permission", message: "Run xcodebuild", toolName: "Bash")
        var unknown = cedar
        unknown.name = "A longer agent name"
        unknown.id.projectID = "unknown"
        unknown.access = .autoEdit
        for (name, theme, scheme, type) in variants {
            let content = ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if type.isAccessibilitySize {
                        Text("Agent rows").font(.headline)
                        CompanionAgentListRow(agent: unknown)
                    } else {
                        Text("Agent rows").font(.largeTitle.bold())
                        Text("Known default hidden; exception and unknown shown").font(.caption)
                        CompanionAgentListRow(agent: river)
                        Divider()
                        CompanionAgentListRow(agent: cedar)
                        Divider()
                        CompanionAgentListRow(agent: unknown)
                    }
                }
                .padding(20)
            }
            .environment(\.companionAgentRowContext, context)
            .dynamicTypeSize(type)
            .companionBackground()
            .companionTheme(theme)
            .environment(\.colorScheme, scheme)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "434 Agent rows - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let standard = UIHostingController(rootView: CompanionAgentListRow(agent: unknown).dynamicTypeSize(.large))
            .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        let accessible = UIHostingController(rootView: CompanionAgentListRow(agent: unknown).dynamicTypeSize(.accessibility3))
            .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(accessible.width, 320)
        XCTAssertGreaterThan(accessible.height, standard.height, "Accessibility type expands vertically, not into metadata")
        var short = unknown
        short.name = "A"
        short.subtitle = ""
        let shortAccessible = UIHostingController(rootView: CompanionAgentListRow(agent: short).dynamicTypeSize(.accessibility3))
            .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertGreaterThan(accessible.height, shortAccessible.height, "Long names and tasks wrap at accessibility sizes")
    }
}
