import XCTest
import SwiftUI
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
            let content = VStack(alignment: .leading, spacing: 16) {
                Text("Agent rows").font(.largeTitle.bold())
                Text("Known default hidden; exception and unknown shown").font(.caption)
                CompanionAgentListRow(agent: river)
                Divider()
                CompanionAgentListRow(agent: cedar)
                Divider()
                CompanionAgentListRow(agent: unknown)
                Spacer(minLength: 0)
            }
            .padding(20)
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
            .sizeThatFits(in: CGSize(width: 320, height: .greatestFiniteMagnitude))
        let accessible = UIHostingController(rootView: CompanionAgentListRow(agent: unknown).dynamicTypeSize(.accessibility3))
            .sizeThatFits(in: CGSize(width: 320, height: .greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(accessible.width, 320)
        XCTAssertGreaterThan(accessible.height, standard.height, "Accessibility type expands vertically, not into metadata")
    }
}
