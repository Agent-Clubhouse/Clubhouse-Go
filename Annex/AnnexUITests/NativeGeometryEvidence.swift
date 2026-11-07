import Foundation

/// Raw representational operands only. ULP spacing does not establish an AX conversion error bound.
enum NativeGeometryEvidence {
    static func describe(_ frame: CGRect) -> String {
        func axis(_ origin: CGFloat, _ extent: CGFloat) -> String {
            let end = origin + extent
            return "origin=\(origin), extent=\(extent), derivedEnd=\(end), ulps=\(origin.ulp)/\(extent.ulp)/\(end.ulp)"
        }
        return "frame=\(frame), x={\(axis(frame.origin.x, frame.size.width))}, y={\(axis(frame.origin.y, frame.size.height))}"
    }
}
