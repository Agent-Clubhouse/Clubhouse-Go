#if os(macOS)
import Testing
import Foundation
@testable import ClubhouseTransport

// Opt-in discriminator (ANNEX_POOL_PROBE=1): does real URLSession per-host connection limiting
// let held REST reads delay a new read, or the WebSocket ping/pong, to the same desktop host?
//
// Real PinnedAnnexIO (production URLSessionConfiguration, pinned TLS, mTLS client identity, the
// session-shared WebSocket) against Fixtures/pool-server.mjs, which mirrors the desktop's Node
// `https.createServer` with no ALPN (HTTP/1.1). macOS only: iOS limits and networking may differ.
// It measures and prints; the assertions are only on what the harness itself needs.

private let probeEnabled = ProcessInfo.processInfo.environment["ANNEX_POOL_PROBE"] == "1"
private let probeIdentity = Result { try AnnexClientIdentity.ephemeral() }

private func report(_ line: String) { print("POOLPROBE \(line)") }

private struct PoolStats: Decodable {
    struct Arrival: Decodable { let path: String; let id: String; let t: Double; let socket: Int?; let alpn: String?; let httpVersion: String }
    struct Ping: Decodable { let t: Double; let socket: Int? }
    struct Closed: Decodable { let id: String; let t: Double }
    let accepted: Int, open: Int, maxOpen: Int, held: Int
    let arrivals: [Arrival], pings: [Ping], closedHolds: [Closed]
    let t: Double
}

private struct PoolFixture: @unchecked Sendable {
    struct Info: Decodable { let port: UInt16; let controlPort: UInt16; let pin: String }
    let process: FixtureProcess
    let info: Info
    let host: TrustedAnnexHost
    let control = URLSession(configuration: .ephemeral)
    static func start() throws -> PoolFixture {
        let process = try FixtureProcess(arguments: [
            "node", try #require(Bundle.module.url(forResource: "pool-server", withExtension: "mjs", subdirectory: "Fixtures")).path
        ])
        do {
            var line = Data()
            while let byte = try process.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
                line.append(byte)
                guard line.count < 4096 else { throw AnnexTransportError.malformedResponse }
            }
            let info = try JSONDecoder().decode(Info.self, from: line)
            let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: info.port),
                                            verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                            verifiedCertificatePin: AnnexCertificatePin(sha256: info.pin))
            return PoolFixture(process: process, info: info, host: host)
        } catch {
            process.stop()
            throw error
        }
    }
    func stop() { control.invalidateAndCancel(); process.stop() }
    func request(_ path: String, id: String) throws -> URLRequest {
        var request = URLRequest(url: try host.endpoint.url(path: [path], query: [URLQueryItem(name: "id", value: id)]))
        request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
        return request
    }
    func webSocketRequest() throws -> URLRequest {
        var request = URLRequest(url: try host.endpoint.url(path: ["ws"], webSocket: true))
        request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
        return request
    }
    func stats(release: String? = nil) async throws -> PoolStats {
        let path = release.map { "release?id=\($0)" } ?? "stats"
        let (data, _) = try await control.data(from: URL(string: "http://127.0.0.1:\(info.controlPort)/\(path)")!)
        return try JSONDecoder().decode(PoolStats.self, from: data)
    }
}

/// Starts an operation and reports its latency if it finishes inside the window; otherwise it keeps
/// running and `settle` can wait for it later.
private final class Timed: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedAt: ContinuousClock.Instant?
    private var failure: String?
    let started = ContinuousClock.now
    private(set) var task: Task<Void, Never>!
    init(_ operation: @escaping @Sendable () async throws -> Void) {
        task = Task { [self] in
            var message: String?
            do { try await operation() } catch { message = "\(type(of: error)) \((error as NSError).domain) \((error as NSError).code)" }
            let end = ContinuousClock.now
            lock.withLock { finishedAt = end; failure = message }
        }
    }
    var result: (ms: Double, failure: String?)? {
        lock.withLock { finishedAt.map { (Self.ms(started, $0), failure) } }
    }
    static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let d = end - start
        return (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded(toPlaces: 1)
    }
    /// Waits up to `seconds` for completion, polling every 2 ms.
    @discardableResult func settle(within seconds: Double) async -> (ms: Double, failure: String?)? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let result { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return result
    }
    func describe() -> String {
        guard let result else { return "PENDING(>\(Self.ms(started, .now))ms)" }
        return result.failure.map { "\(result.ms)ms FAILED[\($0)]" } ?? "\(result.ms)ms"
    }
}

private extension Double { func rounded(toPlaces places: Int) -> Double { let f = pow(10, Double(places)); return (self * f).rounded() / f } }

@Suite(.serialized, .enabled(if: probeEnabled))
struct URLSessionPoolProbe {

    @Test func effectiveConfiguration() async throws {
        let production = PinnedAnnexIO.configuration()
        report("config macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        report("config default.httpMaximumConnectionsPerHost=\(URLSessionConfiguration.default.httpMaximumConnectionsPerHost)")
        report("config ephemeral.httpMaximumConnectionsPerHost=\(URLSessionConfiguration.ephemeral.httpMaximumConnectionsPerHost)")
        report("config production.httpMaximumConnectionsPerHost=\(production.httpMaximumConnectionsPerHost) timeoutForRequest=\(production.timeoutIntervalForRequest) timeoutForResource=\(production.timeoutIntervalForResource) httpShouldUsePipelining=\(production.httpShouldUsePipelining) waitsForConnectivity=\(production.waitsForConnectivity) networkServiceType=\(production.networkServiceType.rawValue)")
        // Negotiated protocol, observed client-side with the production configuration and the real pinned delegate.
        let fixture = try PoolFixture.start()
        defer { fixture.stop() }
        final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var protocols: [String?] = []
            func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
                protocols = metrics.transactionMetrics.map(\.networkProtocolName)
            }
        }
        let trust = AnnexPinnedSessionDelegate(host: fixture.host, clientIdentity: try probeIdentity.get(), telemetry: AnnexTelemetry())
        let session = URLSession(configuration: production, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let metrics = Metrics()
        let (_, response) = try await session.data(for: try fixture.request("fast", id: "proto"), delegate: metrics)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let stats = try await fixture.stats()
        report("config clientNetworkProtocolName=\(metrics.protocols) serverHTTPVersion=\(stats.arrivals.map(\.httpVersion)) serverALPN=\(stats.arrivals.map { $0.alpn ?? "none" })")
    }

    /// (a) new REST read latency, (b) WS ping RTT, (c) cancelling a held read, with K held reads in flight.
    /// The WebSocket is open first, as in a live session.
    @Test(.timeLimit(.minutes(1)), arguments: [1, 4, 5, 6, 8])
    func heldReads(k: Int) async throws {
        let fixture = try PoolFixture.start()
        defer { fixture.stop() }
        let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try probeIdentity.get(), telemetry: AnnexTelemetry())
        _ = try await io.perform(try fixture.request("fast", id: "warm"))
        let socket = try await io.openWebSocket(try fixture.webSocketRequest())
        _ = try await socket.receive() // greeting
        // URLSession only reads pongs while a receive is outstanding; the transport's receive loop always is (AnnexTransport.swift:597).
        let reader = Task { while true { _ = try await socket.receive() } }
        var baselinePings: [String] = []
        for _ in 0..<3 { let p = Timed { try await socket.ping() }; await p.settle(within: 4); baselinePings.append(p.describe()) }
        let baselineRead = Timed { _ = try await io.perform(try fixture.request("fast", id: "baseline")) }
        await baselineRead.settle(within: 4)

        let holds = (0..<k).map { i in Timed { _ = try await io.perform(try fixture.request("hold", id: "h\(i)")) } }
        var arrived = 0
        for _ in 0..<40 { // up to 2 s for held reads to reach the server
            arrived = try await fixture.stats().arrivals.filter { $0.path == "/hold" }.count
            if arrived == k { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let read = Timed { _ = try await io.perform(try fixture.request("fast", id: "probe")) }
        await read.settle(within: 3)
        let readDuringHold = read.describe()
        var pingsDuringHold: [String] = []
        for _ in 0..<3 { let p = Timed { try await socket.ping() }; await p.settle(within: 4); pingsDuringHold.append(p.describe()) }
        // (c) cancel one held read's Swift task; does the queued read then proceed?
        var afterCancel = "n/a(read not queued)"
        if read.result == nil {
            let cancelledAt = ContinuousClock.now
            holds[0].task.cancel()
            if let done = await read.settle(within: 4) {
                afterCancel = "\((done.ms - Timed.ms(read.started, cancelledAt)).rounded(toPlaces: 1))ms after cancel\(done.failure.map { " FAILED[\($0)]" } ?? "")"
            } else { afterCancel = "still PENDING 4s after cancel" }
        }
        let stats = try await fixture.stats()
        let probeArrived = stats.arrivals.contains { $0.id == "probe" }
        report("heldReads k=\(k) holdsArrivedAtServer=\(arrived)/\(k) baselineRead=\(baselineRead.describe()) baselinePings=\(baselinePings) readDuringHold=\(readDuringHold) probeReachedServer=\(probeArrived) pingsDuringHold=\(pingsDuringHold) queuedReadAfterCancelOneHold=\(afterCancel) serverAccepted=\(stats.accepted) serverMaxOpen=\(stats.maxOpen) wsSocket=\(stats.arrivals.first { $0.path == "/ws" }?.socket ?? -1) pingSockets=\(Set(stats.pings.compactMap(\.socket)))")
        _ = try await fixture.stats(release: "all")
        for hold in holds { await hold.settle(within: 4) }
        await read.settle(within: 4)
        reader.cancel()
        await socket.close()
    }

    /// The reconnect shape: K reads already held when the WebSocket is opened.
    @Test(.timeLimit(.minutes(1)), arguments: [4, 6, 8])
    func webSocketOpenedBehindHeldReads(k: Int) async throws {
        let fixture = try PoolFixture.start()
        defer { fixture.stop() }
        let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try probeIdentity.get(), telemetry: AnnexTelemetry())
        _ = try await io.perform(try fixture.request("fast", id: "warm"))
        let holds = (0..<k).map { i in Timed { _ = try await io.perform(try fixture.request("hold", id: "h\(i)")) } }
        var arrived = 0
        for _ in 0..<40 {
            arrived = try await fixture.stats().arrivals.filter { $0.path == "/hold" }.count
            if arrived == k { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let box = SocketBox()
        let open = Timed {
            let socket = try await io.openWebSocket(try fixture.webSocketRequest())
            box.set(socket)
            _ = try await socket.receive()
        }
        await open.settle(within: 5)
        let openedWhileHeld = open.describe()
        var ping = "n/a"
        if open.result?.failure == nil, let socket = box.get() {
            let reader = Task { while true { _ = try await socket.receive() } }
            let p = Timed { try await socket.ping() }; await p.settle(within: 4); ping = p.describe()
            reader.cancel()
        }
        let stats = try await fixture.stats()
        report("wsBehindHeld k=\(k) holdsArrivedAtServer=\(arrived)/\(k) wsOpenToGreeting=\(openedWhileHeld) wsReachedServer=\(stats.arrivals.contains { $0.path == "/ws" }) ping=\(ping) serverAccepted=\(stats.accepted) serverMaxOpen=\(stats.maxOpen)")
        _ = try await fixture.stats(release: "all")
        for hold in holds { await hold.settle(within: 4) }
        await open.settle(within: 4)
        if let socket = box.get() { await socket.close() }
        open.task.cancel()
    }

    /// Held reads that never answer: when do they fail, and what happens to a read queued behind them?
    /// Production timeoutIntervalForRequest is 30 s, so this runs about 35 s.
    @Test(.timeLimit(.minutes(1)))
    func heldReadsTimeOutAndQueuedRead() async throws {
        let fixture = try PoolFixture.start()
        defer { fixture.stop() }
        let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try probeIdentity.get(), telemetry: AnnexTelemetry())
        _ = try await io.perform(try fixture.request("fast", id: "warm"))
        let k = 6
        let holds = (0..<k).map { i in Timed { _ = try await io.perform(try fixture.request("hold", id: "h\(i)")) } }
        try await Task.sleep(for: .milliseconds(500))
        let queued = Timed { _ = try await io.perform(try fixture.request("fast", id: "queued")) }
        await queued.settle(within: 40)
        for hold in holds { await hold.settle(within: 5) }
        let stats = try await fixture.stats()
        let queuedArrival = stats.arrivals.first { $0.id == "queued" }
        report("timeout k=\(k) holds=\(holds.map { $0.describe() }) queuedRead=\(queued.describe()) queuedReachedServer=\(queuedArrival != nil) serverClosedHolds=\(stats.closedHolds.count) serverAccepted=\(stats.accepted) serverMaxOpen=\(stats.maxOpen)")
        _ = try await fixture.stats(release: "all")
    }

    /// Six slow-but-live reads (a byte every 2 s, so their own 30 s idle timeout never fires) occupy the pool
    /// for 36 s. Does a read queued behind them time out on its own 30 s clock without reaching the server?
    @Test(.timeLimit(.minutes(1)))
    func readQueuedBehindLiveSlowReads() async throws {
        let fixture = try PoolFixture.start()
        defer { fixture.stop() }
        let io = PinnedAnnexIO(host: fixture.host, clientIdentity: try probeIdentity.get(), telemetry: AnnexTelemetry())
        _ = try await io.perform(try fixture.request("fast", id: "warm"))
        let k = 6
        let slow = (0..<k).map { i in Timed { _ = try await io.perform(try fixture.request("trickle", id: "s\(i)")) } }
        try await Task.sleep(for: .milliseconds(500))
        let queued = Timed { _ = try await io.perform(try fixture.request("fast", id: "queued")) }
        await queued.settle(within: 35.5)
        let queuedAt36 = queued.describe()
        let before = try await fixture.stats()
        _ = try await fixture.stats(release: "all")
        await queued.settle(within: 3)
        for read in slow { await read.settle(within: 3) }
        let after = try await fixture.stats()
        report("queuedBehindLive k=\(k) queuedReadAt36s=\(queuedAt36) queuedReachedServerBeforeRelease=\(before.arrivals.contains { $0.id == "queued" }) queuedReadFinal=\(queued.describe()) slowReads=\(slow.map { $0.describe() }) serverAccepted=\(after.accepted) serverMaxOpen=\(after.maxOpen)")
    }
}

private final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: (any AnnexWebSocket)?
    func set(_ value: any AnnexWebSocket) { lock.withLock { socket = value } }
    func get() -> (any AnnexWebSocket)? { lock.withLock { socket } }
}
#endif
