import Testing
import Foundation
@testable import ClubhouseGo

// Covers GH #86: the Clubhouse tab is a rail of Canvas + projects. Only
// Annex-enabled plugins with a working mobile view (canvas) should appear;
// non-Annex rows and "not yet available on mobile" placeholders are hidden.

struct ClubhousePluginVisibilityTests {
    private func plugin(_ id: String, name: String? = nil, scope: String? = "app", annexEnabled: Bool = true) -> PluginSummary {
        PluginSummary(id: id, name: name ?? id.capitalized, version: nil, scope: scope, annexEnabled: annexEnabled)
    }

    @Test func canvasIsShownWhenAnnexEnabled() {
        #expect(ClubhousePluginVisibility.shouldShow(plugin("canvas")))
    }

    @Test func canvasIsHiddenWhenNotAnnexEnabled() {
        #expect(!ClubhousePluginVisibility.shouldShow(plugin("canvas", annexEnabled: false)))
    }

    @Test func placeholderOnlyPluginsAreHidden() {
        // These route to the "not yet available on mobile" placeholder.
        for id in ["hub", "browser", "git", "search", "issues"] {
            #expect(!ClubhousePluginVisibility.shouldShow(plugin(id)), "\(id) should be hidden")
        }
    }

    @Test func groupProjectPluginIsHidden() {
        #expect(!ClubhousePluginVisibility.shouldShow(plugin("group-project")))
    }

    @Test func homeIsHiddenFromClubhouseRail() {
        // Home is already covered by the Dashboard tab.
        #expect(!ClubhousePluginVisibility.shouldShow(plugin("home")))
    }

    @Test func filterKeepsOnlyCanvasFromMixedList() {
        let plugins = [
            plugin("canvas"),
            plugin("home"),
            plugin("hub"),
            plugin("git", annexEnabled: false),
            plugin("issues"),
        ]
        let visible = ClubhousePluginVisibility.visibleAppPlugins(plugins)
        #expect(visible.map(\.id) == ["canvas"])
    }

    @Test func emptyWhenNoCanvasPresent() {
        let plugins = [plugin("home"), plugin("browser"), plugin("search")]
        #expect(ClubhousePluginVisibility.visibleAppPlugins(plugins).isEmpty)
    }
}
