#if os(macOS)
import Darwin
import Foundation
import Testing

@Test func fixtureProcessCanStopAfterItAlreadyExited() throws {
    let fixture = try FixtureProcess(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    defer { fixture.stop() }
    try #require(fixture.waitForExit(timeout: .seconds(2)))
    fixture.stop()
    try #require(!fixture.process.isRunning)
    #expect(fixture.process.terminationStatus == 0)
}

@Test func fixtureProcessKillsAChildThatIgnoresTermination() throws {
    let fixture = try FixtureProcess(arguments: [
        "node", "-e",
        "process.on('SIGTERM', () => {}); process.stdout.write('ready\\n'); setInterval(() => {}, 1000);"
    ])
    defer { fixture.stop() }
    #expect(try fixture.output.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
    let started = ContinuousClock.now
    fixture.stop(gracePeriod: .milliseconds(50))
    #expect(ContinuousClock.now - started < .seconds(3))
    try #require(!fixture.process.isRunning)
    #expect(fixture.process.terminationReason == .uncaughtSignal)
    #expect(fixture.process.terminationStatus == SIGKILL)
}
#endif
