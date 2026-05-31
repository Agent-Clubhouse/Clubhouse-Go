import Testing
import Foundation
@testable import ClubhouseGo

// Covers GH #91: group-project plugin nodes are hidden from the canvas because
// their detail view (bulletin board) isn't functional on mobile.

struct CanvasGroupProjectTests {
    private func pluginView(
        _ id: String,
        widgetType: String? = nil,
        pluginId: String? = nil
    ) -> CanvasView {
        CanvasView(
            id: id, type: .plugin,
            position: .init(x: 0, y: 0),
            size: .init(width: 160, height: 80),
            title: id, displayName: nil, zIndex: 0, metadata: nil,
            agentId: nil, projectId: nil,
            label: nil, autoCollapse: nil,
            pluginWidgetType: widgetType, pluginId: pluginId,
            themeId: nil, containedViewIds: nil
        )
    }

    private func agentView(_ id: String) -> CanvasView {
        CanvasView(
            id: id, type: .agent,
            position: .init(x: 0, y: 0),
            size: .init(width: 160, height: 80),
            title: id, displayName: nil, zIndex: 0, metadata: nil,
            agentId: "agent_\(id)", projectId: nil,
            label: nil, autoCollapse: nil, pluginWidgetType: nil, pluginId: nil,
            themeId: nil, containedViewIds: nil
        )
    }

    @Test func detectsGroupProjectByWidgetType() {
        #expect(pluginView("v", widgetType: "group-project").isGroupProject)
        #expect(pluginView("v", widgetType: "annex.group-project.board").isGroupProject)
    }

    @Test func detectsGroupProjectByPluginId() {
        #expect(pluginView("v", pluginId: "group-project").isGroupProject)
    }

    @Test func ordinaryPluginIsNotGroupProject() {
        #expect(!pluginView("v", widgetType: "terminal", pluginId: "terminal").isGroupProject)
        #expect(!pluginView("v").isGroupProject)
    }

    @Test func agentNodeIsNotGroupProject() {
        #expect(!agentView("a").isGroupProject)
    }

    @Test func filteringDropsGroupProjectNodesOnly() {
        let views = [
            agentView("a"),
            pluginView("gp", widgetType: "group-project"),
            pluginView("term", pluginId: "terminal"),
        ]
        let visible = views.filter { !$0.isGroupProject }
        #expect(visible.map(\.id) == ["a", "term"])
    }
}
