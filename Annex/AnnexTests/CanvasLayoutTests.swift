import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Canvas Layout (collision / spacing) Tests
//
// Covers GH #88: node frames laid out for desktop overlap on the mobile
// viewport. `CanvasLayout.resolvePositions` separates overlapping frames while
// leaving non-overlapping and zone nodes alone.

struct CanvasLayoutTests {
    /// Concise fixture for a canvas node.
    private func makeView(
        _ id: String,
        type: CanvasViewType = .agent,
        x: Double,
        y: Double,
        w: Double = 160,
        h: Double = 80
    ) -> CanvasView {
        CanvasView(
            id: id, type: type,
            position: .init(x: x, y: y),
            size: .init(width: w, height: h),
            title: id, displayName: nil, zIndex: 0, metadata: nil,
            agentId: type == .agent ? "agent_\(id)" : nil, projectId: nil,
            label: nil, autoCollapse: nil, pluginWidgetType: nil, pluginId: nil,
            themeId: nil, containedViewIds: nil
        )
    }

    /// True when two node frames overlap once each is expanded by `spacing`.
    private func framesOverlap(
        _ a: (pos: CanvasViewPosition, view: CanvasView),
        _ b: (pos: CanvasViewPosition, view: CanvasView),
        spacing: Double
    ) -> Bool {
        let needX = a.view.size.width / 2 + b.view.size.width / 2 + spacing
        let needY = a.view.size.height / 2 + b.view.size.height / 2 + spacing
        let dx = abs(b.pos.x - a.pos.x)
        let dy = abs(b.pos.y - a.pos.y)
        return dx < needX && dy < needY
    }

    private func assertNoOverlaps(
        _ views: [CanvasView],
        spacing: Double,
        considerZones: Bool = false
    ) {
        let resolved = CanvasLayout.resolvePositions(for: views, minSpacing: spacing)
        let collidable = views.filter { considerZones || $0.type != .zone }
        for i in 0..<collidable.count {
            for j in (i + 1)..<collidable.count {
                let a = (pos: resolved[collidable[i].id]!, view: collidable[i])
                let b = (pos: resolved[collidable[j].id]!, view: collidable[j])
                // Allow a tiny epsilon: relaxation lands exactly on the spacing
                // boundary, where floating point can read as a hair under.
                #expect(
                    !framesOverlap(a, b, spacing: spacing - 0.001),
                    "\(collidable[i].id) and \(collidable[j].id) still overlap"
                )
            }
        }
    }

    @Test func separatesTwoOverlappingNodes() {
        // Two identical-size agents almost exactly on top of each other.
        let views = [
            makeView("a", x: 0, y: 0),
            makeView("b", x: 10, y: 5),
        ]
        assertNoOverlaps(views, spacing: 24)
    }

    @Test func separatesNodesAtIdenticalPosition() {
        // Exact same point — must still be deterministically pushed apart.
        let views = [
            makeView("a", x: 100, y: 100),
            makeView("b", x: 100, y: 100),
        ]
        let resolved = CanvasLayout.resolvePositions(for: views, minSpacing: 24)
        #expect(resolved["a"]!.x != resolved["b"]!.x || resolved["a"]!.y != resolved["b"]!.y)
        assertNoOverlaps(views, spacing: 24)
    }

    @Test func leavesNonOverlappingNodesUntouched() {
        // Already far apart (gap well beyond spacing) — nothing should move.
        let views = [
            makeView("a", x: -400, y: 0),
            makeView("b", x: 400, y: 0),
            makeView("c", x: 0, y: 400),
        ]
        let resolved = CanvasLayout.resolvePositions(for: views, minSpacing: 24)
        for v in views {
            #expect(resolved[v.id]!.x == v.position.x)
            #expect(resolved[v.id]!.y == v.position.y)
        }
    }

    @Test func zonesAreNeverMovedAndDoNotPushOthers() {
        // A big zone overlapping an agent: the agent stays put (zones are
        // background containers), and the zone stays put.
        let zone = makeView("zone", type: .zone, x: 0, y: 0, w: 500, h: 300)
        let agent = makeView("a", type: .agent, x: 0, y: 0)
        let resolved = CanvasLayout.resolvePositions(for: [zone, agent], minSpacing: 24)
        #expect(resolved["zone"]!.x == 0 && resolved["zone"]!.y == 0)
        #expect(resolved["a"]!.x == 0 && resolved["a"]!.y == 0)
    }

    @Test func clusterOfOverlappingNodesAllSeparate() {
        // Five nodes piled into a tight cluster.
        let views = [
            makeView("a", x: 0, y: 0),
            makeView("b", x: 20, y: 10),
            makeView("c", x: -15, y: -5),
            makeView("d", x: 5, y: 20),
            makeView("e", x: -10, y: 15),
        ]
        assertNoOverlaps(views, spacing: 24)
    }

    @Test func resolutionIsDeterministic() {
        let views = [
            makeView("a", x: 0, y: 0),
            makeView("b", x: 12, y: 8),
            makeView("c", x: -6, y: 4),
        ]
        let first = CanvasLayout.resolvePositions(for: views, minSpacing: 24)
        let second = CanvasLayout.resolvePositions(for: views, minSpacing: 24)
        for v in views {
            #expect(first[v.id]!.x == second[v.id]!.x)
            #expect(first[v.id]!.y == second[v.id]!.y)
        }
    }

    @Test func everyViewIsPresentInResult() {
        let views = [
            makeView("a", x: 0, y: 0),
            makeView("z", type: .zone, x: 0, y: 0, w: 400, h: 300),
            makeView("p", type: .plugin, x: 5, y: 5),
        ]
        let resolved = CanvasLayout.resolvePositions(for: views, minSpacing: 24)
        #expect(resolved.count == 3)
        #expect(resolved["a"] != nil && resolved["z"] != nil && resolved["p"] != nil)
    }
}
