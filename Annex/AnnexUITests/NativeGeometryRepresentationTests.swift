import XCTest

/// Pure arithmetic controls: no app, simulator interaction, fixture or native export is consulted.
final class NativeGeometryRepresentationTests: XCTestCase {
    func testObservedSizeDiscrepanciesUnderExplicitSyntheticOrigins() throws {
        // These are test inputs, NOT reconstructed origins from the missing CI artifact.
        for extent in [43.99999999999994, 43.999999999999986, 44] as [CGFloat] {
            let axis = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 320, extent: extent))
            XCTAssertTrue(axis.meets(44))
        }
        let reference = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: 119.66666666666666))
        let moved = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 64, extent: 119.66666666666667))
        XCTAssertTrue(moved.sameExtent(as: reference))
    }

    func testRealDeficitsAndResizingRemainFailures() throws {
        for extent in [42.24875621890544, 43.9, 43.999999] as [CGFloat] {
            let axis = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 320, extent: extent))
            XCTAssertFalse(axis.meets(44))
        }
        let reference = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: 120))
        for extent in [119.999999, 120.000001, 119, 121] as [CGFloat] {
            let resized = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 64, extent: extent))
            XCTAssertFalse(resized.sameExtent(as: reference))
        }
    }

    func testInvalidAndIllConditionedOperandsFailClosed() {
        for (origin, extent) in [(CGFloat.nan, CGFloat(44)), (.infinity, 44), (0, .nan), (0, .infinity), (0, 0), (0, -44), (1e16, 44)] {
            XCTAssertNil(NativeGeometryRepresentation.Axis(origin: origin, extent: extent))
        }
    }

    func testCoverageAccumulatesOverlapButNeverBridgesAnInteriorGap() throws {
        let axis = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: 120))
        var coverage = NativeGeometryRepresentation.Coverage()
        XCTAssertTrue(coverage.observe(axis, lower: 0, upper: 60))
        XCTAssertTrue(coverage.observe(axis, lower: CGFloat(60).nextUp, upper: 120))
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.prefix, 60)
        XCTAssertTrue(coverage.observe(axis, lower: 59, upper: 61))
        XCTAssertTrue(coverage.complete)
    }

    func testResizeInvalidatesOldCoverageInBothDirections() throws {
        for newExtent in [119, 121] as [CGFloat] {
            let old = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: 120))
            let new = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 64, extent: newExtent))
            var coverage = NativeGeometryRepresentation.Coverage()
            XCTAssertTrue(coverage.observe(old, lower: 0, upper: 80))
            XCTAssertFalse(coverage.observe(new, lower: 60, upper: newExtent))
            XCTAssertEqual(coverage.spans.count, 1)
            XCTAssertEqual(coverage.prefix, 0)
            XCTAssertFalse(coverage.complete)
            XCTAssertTrue(coverage.observe(new, lower: 0, upper: 60))
            XCTAssertTrue(coverage.complete)
        }
    }

    func testFixedReferenceRejectsCumulativeDriftAndMapsOnlyFullBottomEdge() throws {
        let old = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: 120))
        var coverage = NativeGeometryRepresentation.Coverage()
        XCTAssertTrue(coverage.observe(old, lower: 0, upper: 60))
        let moved = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 64, extent: CGFloat(120).nextUp))
        XCTAssertTrue(coverage.observe(moved, lower: 59, upper: moved.extent))
        XCTAssertTrue(coverage.complete)
        XCTAssertEqual(coverage.reference?.extent, old.extent)
        var extent = old.extent
        var rejected = false
        for _ in 0..<128 {
            extent = extent.nextUp
            let drift = try XCTUnwrap(NativeGeometryRepresentation.Axis(origin: 128, extent: extent))
            if !coverage.observe(drift, lower: nil, upper: nil) { rejected = true; break }
        }
        XCTAssertTrue(rejected)
        XCTAssertTrue(coverage.spans.isEmpty)
        XCTAssertFalse(coverage.complete)
    }
}
