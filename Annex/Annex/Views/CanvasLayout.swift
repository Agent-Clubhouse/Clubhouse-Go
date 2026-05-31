import Foundation

/// Pure, view-independent layout math for the canvas.
///
/// The server sends absolute node coordinates laid out for a desktop-sized
/// canvas. On the much smaller mobile viewport those frames frequently end up
/// visually overlapping (see GH #88). `CanvasLayout` runs a deterministic
/// relaxation pass that nudges overlapping node frames apart so a minimum gap
/// is preserved, while keeping the overall arrangement as close to the server
/// layout as possible.
///
/// All math is in canvas coordinate units (the same space the server uses);
/// the renderer applies pan/zoom on top of the resolved positions.
enum CanvasLayout {
    /// Minimum gap (in canvas coordinate units) to keep between node frames.
    static let defaultMinSpacing: Double = 24

    /// Node types that participate in collision resolution. Zones are skipped:
    /// they are large background containers that intentionally sit *under* their
    /// child nodes, so separating them would break the layout.
    static func isCollidable(_ type: CanvasViewType) -> Bool {
        type != .zone
    }

    /// Returns adjusted center positions keyed by view id.
    ///
    /// Every view in `views` is present in the result. Non-collidable views
    /// (zones) are returned with their original position and never move other
    /// nodes. Collidable views are nudged apart so that, after resolution, no
    /// two of their frames overlap once expanded by `minSpacing`.
    ///
    /// The pass is fully deterministic: iteration order is fixed and ties are
    /// broken by index, so the same input always yields the same output.
    static func resolvePositions(
        for views: [CanvasView],
        minSpacing: Double = defaultMinSpacing,
        maxIterations: Int = 200
    ) -> [String: CanvasViewPosition] {
        // Snapshot mutable node state. Index into `nodes` is the stable id used
        // for deterministic tie-breaking.
        struct Node {
            let id: String
            var x: Double
            var y: Double
            let halfW: Double
            let halfH: Double
            let collidable: Bool
        }

        var nodes: [Node] = views.map { view in
            Node(
                id: view.id,
                x: view.position.x,
                y: view.position.y,
                halfW: max(0, view.size.width) / 2,
                halfH: max(0, view.size.height) / 2,
                collidable: isCollidable(view.type)
            )
        }

        // Indices of collidable nodes; only these are relaxed against each other.
        let movable = nodes.indices.filter { nodes[$0].collidable }

        if movable.count > 1 {
            for _ in 0..<maxIterations {
                var moved = false

                for ii in 0..<movable.count {
                    for jj in (ii + 1)..<movable.count {
                        let i = movable[ii]
                        let j = movable[jj]

                        let dx = nodes[j].x - nodes[i].x
                        let dy = nodes[j].y - nodes[i].y

                        // Required center separation along each axis for the
                        // frames (plus the spacing margin) to not overlap.
                        let needX = nodes[i].halfW + nodes[j].halfW + minSpacing
                        let needY = nodes[i].halfH + nodes[j].halfH + minSpacing

                        let overlapX = needX - abs(dx)
                        let overlapY = needY - abs(dy)

                        // Frames only intersect when both axes overlap.
                        guard overlapX > 0, overlapY > 0 else { continue }

                        // Resolve along the axis of least penetration so nodes
                        // move the smallest distance needed to separate.
                        if overlapX <= overlapY {
                            let shift = overlapX / 2
                            // dx == 0 → tie-break by index (j to the right).
                            let sign = dx >= 0 ? 1.0 : -1.0
                            nodes[i].x -= sign * shift
                            nodes[j].x += sign * shift
                        } else {
                            let shift = overlapY / 2
                            let sign = dy >= 0 ? 1.0 : -1.0
                            nodes[i].y -= sign * shift
                            nodes[j].y += sign * shift
                        }
                        moved = true
                    }
                }

                if !moved { break }
            }
        }

        var result: [String: CanvasViewPosition] = [:]
        result.reserveCapacity(nodes.count)
        for node in nodes {
            result[node.id] = CanvasViewPosition(x: node.x, y: node.y)
        }
        return result
    }
}
