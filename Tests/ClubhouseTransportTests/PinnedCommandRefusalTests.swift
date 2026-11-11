#if os(macOS)
import Foundation
import Testing
@testable import ClubhouseTransport

/// A paced stream prevents the tiny loopback upload from finishing before the early response is written.
private final class PacedCommandBody: InputStream, @unchecked Sendable {
    private let wrapped: InputStream
    override init(data: Data) { wrapped = InputStream(data: data); super.init(data: Data()) }
    override func open() { wrapped.open() }
    override func close() { wrapped.close() }
    override var streamStatus: Stream.Status { wrapped.streamStatus }
    override var streamError: Error? { wrapped.streamError }
    override var hasBytesAvailable: Bool { wrapped.hasBytesAvailable }
    override var delegate: (any StreamDelegate)? {
        get { wrapped.delegate }
        set { wrapped.delegate = newValue }
    }
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) { wrapped.schedule(in: runLoop, forMode: mode) }
    override func remove(from runLoop: RunLoop, forMode mode: RunLoop.Mode) { wrapped.remove(from: runLoop, forMode: mode) }
    override func property(forKey key: Stream.PropertyKey) -> Any? { wrapped.property(forKey: key) }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { wrapped.setProperty(property, forKey: key) }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        Thread.sleep(forTimeInterval: 0.01)
        return wrapped.read(buffer, maxLength: min(len, 16_384))
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
}

@Test(.timeLimit(.minutes(1))) func pinnedURLSessionObservesRefusalWhileAnOversizeBodyIsUploading() async throws {
    let process = try FixtureProcess(arguments: [
        "node", try #require(Bundle.module.url(forResource: "command-refusal-server", withExtension: "mjs", subdirectory: "Fixtures")).path
    ])
    defer { process.stop() }
    var line = Data()
    while let byte = try process.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
        line.append(byte)
        guard line.count < 4096 else { throw AnnexTransportError.malformedResponse }
    }
    struct Info: Decodable { let port: UInt16; let pin: String }
    let info = try JSONDecoder().decode(Info.self, from: line)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: info.port),
        verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef", verifiedCertificatePin: AnnexCertificatePin(sha256: info.pin))
    let client = try AnnexClientIdentity.ephemeral()
    let io = PinnedAnnexIO(host: host, clientIdentity: client, telemetry: AnnexTelemetry())
    func command(_ text: String) -> AnnexCommand { .init(commandID: "oversize", epoch: "client-epoch", kind: .send(agentID: "a", sessionID: "s", text: text)) }
    let body = try command(String(repeating: "a", count: 1_048_577 - command("").encoded().count)).encoded()
    #expect(body.count == 1_048_577)
    // Deliberately exercise raw IO: production execute's 1 MiB preflight prevents this request.
    var request = URLRequest(url: try host.endpoint.url(path: ["api", "v1", "mobile", "commands"]))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer test-only", forHTTPHeaderField: "Authorization")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    request.httpBodyStream = PacedCommandBody(data: body)
    do {
        let response = try await io.perform(request)
        let receipt = try JSONDecoder().decode(AnnexCommandReceipt.self, from: response.data)
        #expect(response.status == 413 && receipt.version == 1 && receipt.status == .rejected)
        #expect(receipt.commandId == nil && receipt.error?.code == "too_large")
        print("Pinned URLSession early 413: response delivered, \(response.data.count) bytes; production decoder can prove refusal")
    } catch {
        let error = error as NSError
        print("Pinned URLSession early 413: transport error \(error.domain) \(error.code); production execute keeps outcome unknown")
        #expect(error.domain == NSURLErrorDomain || error.domain == NSPOSIXErrorDomain)
    }
    var observations: [AnnexJSON] = []
    for _ in 0..<100 {
        let response = try await io.perform(URLRequest(url: host.endpoint.url(path: ["observations"])))
        observations = try JSONDecoder().decode([AnnexJSON].self, from: response.data)
        if observations.first?["connectionClosed"] == .bool(true) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let observed = try #require(observations.first)
    #expect(observations.count == 1, "The pinned stack must not automatically resend")
    #expect(observed["clientCN"]?.string == (try client.fingerprint))
    let startedAtBytes = try #require(observed["responseStartedAtBytes"]?.integer)
    #expect(startedAtBytes > 0 && startedAtBytes < body.count, "The response must start during the upload")
    #expect(observed["connectionClosed"] == .bool(true))
    print("Pinned URLSession early 413 server: responseStartedAt=\(startedAtBytes), received=\(observed["receivedBytes"]?.integer ?? -1)/1048577, uploadEnded=\(observed["uploadEnded"] == .bool(true)), responseEnded=\(observed["responseEnded"] == .bool(true)), connectionClosed=\(observed["connectionClosed"] == .bool(true))")
}
#endif
