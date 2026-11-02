import Foundation
import XCTest
@testable import Framebriar

/// XCTest rather than swift-testing: the count is process-wide, and `swift test` runs XCTest cases
/// serially and apart from the swift-testing suites, which create instances in parallel.
final class TelemetryInstanceCountTests: XCTestCase {
    private func make() throws -> Telemetry {
        let r = Rig()
        return try Telemetry(client: try r.client(), configuration: r.config, transport: r.network, observeAppLifecycle: false, now: r.clock.now)
    }

    func testCountsLiveInstancesAndForgetsThemOnDisposeAndDeinit() throws {
        let base = Telemetry.liveInstanceCount
        var first: Telemetry? = try make()
        XCTAssertEqual(Telemetry.liveInstanceCount, base + 1)
        var second: Telemetry? = try make()
        XCTAssertEqual(Telemetry.liveInstanceCount, base + 2)
        second?.dispose()
        XCTAssertEqual(Telemetry.liveInstanceCount, base + 1)
        second?.dispose()
        XCTAssertEqual(Telemetry.liveInstanceCount, base + 1, "A second dispose doesn't count twice")
        second = nil
        XCTAssertEqual(Telemetry.liveInstanceCount, base + 1, "Deinit after dispose doesn't count twice")
        first = nil
        XCTAssertEqual(Telemetry.liveInstanceCount, base)
        _ = first
    }

    func testAFailedInitializerIsNotCounted() throws {
        let base = Telemetry.liveInstanceCount
        let r = Rig()
        XCTAssertThrowsError(try Telemetry(client: try r.client(), configuration: r.config, sessionID: "bad id!", observeAppLifecycle: false))
        XCTAssertEqual(Telemetry.liveInstanceCount, base)
    }
}
