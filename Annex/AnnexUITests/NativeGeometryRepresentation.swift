import Foundation

/// Test-only arithmetic contract, not a claim about UIKit's internal layout or AX conversion pipeline.
/// Endpoints rounded once and their difference rounded once can differ by their local spacings.
/// Full (rather than half) ULPs conservatively include reconstructing the far endpoint from CGRect.
/// Values inside this envelope are representation-compatible, not proof of exact real-number equality.
enum NativeGeometryRepresentation {
    struct Axis {
        let origin: CGFloat
        let extent: CGFloat
        let end: CGFloat
        let uncertainty: CGFloat

        init?(origin: CGFloat, extent: CGFloat) {
            let end = origin + extent
            guard origin.isFinite, extent.isFinite, extent > 0, end.isFinite, end > origin else { return nil }
            let uncertainty = (origin.ulp + end.ulp + extent.ulp).nextUp
            // Fail closed for ill-conditioned coordinates: this is a numerical-quality ceiling,
            // not an allowed UI tolerance. The actual comparison uses only the ULP-derived bound.
            guard uncertainty.isFinite, uncertainty > 0,
                  uncertainty / extent < CGFloat.ulpOfOne.squareRoot() else { return nil }
            self.origin = origin; self.extent = extent; self.end = end; self.uncertainty = uncertainty
        }

        func meets(_ minimum: CGFloat) -> Bool {
            guard minimum.isFinite, minimum > 0 else { return false }
            return extent >= minimum || minimum - extent <= uncertainty
        }

        func sameExtent(as reference: Axis) -> Bool {
            abs(extent - reference.extent) <= (uncertainty + reference.uncertainty).nextUp
        }

        var evidence: String {
            "origin=\(origin), extent=\(extent), end=\(end), ulps=\(origin.ulp)/\(end.ulp)/\(extent.ulp), envelope=\(uncertainty)"
        }
    }

    /// A fixed reference prevents successive near-equalities from accumulating into real resizing.
    /// A resize invalidates every old span. The caller still fails its unchanged-size contract.
    struct Coverage {
        private(set) var reference: Axis?
        private(set) var spans: [(CGFloat, CGFloat)] = []

        mutating func observe(_ axis: Axis, lower: CGFloat?, upper: CGFloat?) -> Bool {
            let unchanged = reference.map { axis.sameExtent(as: $0) } ?? true
            if reference == nil || !unchanged { reference = axis; spans.removeAll() }
            if let lower, let upper, lower.isFinite, upper.isFinite,
               lower >= 0, upper >= lower, upper <= axis.extent, let reference {
                // A measured full bottom edge denotes the reference's full bottom edge.
                // Interior gaps are never bridged using the representation envelope.
                let end = upper == axis.extent ? reference.extent : min(upper, reference.extent)
                spans.append((min(lower, reference.extent), end))
            }
            return unchanged
        }

        var prefix: CGFloat {
            var end: CGFloat = 0
            for span in spans.sorted(by: { $0.0 < $1.0 }) {
                if span.0 > end { break }
                end = max(end, span.1)
            }
            return end
        }

        var complete: Bool { reference.map { prefix >= $0.extent } ?? false }
    }
}
