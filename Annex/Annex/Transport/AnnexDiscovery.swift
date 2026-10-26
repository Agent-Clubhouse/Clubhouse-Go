import Foundation

nonisolated public struct AnnexDiscoveredHost: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let endpoint: AnnexEndpoint
    /// Unauthenticated hints. Never pass these to a trust constructor without
    /// confirming against the actual desktop invitation/fingerprint display.
    public let identityFingerprintHint: String?
    public let pairingPortHint: UInt16?
    public init(id: String, name: String, host: String, port: UInt16, txt: [String: Data]) throws {
        self.id = id; self.name = name
        self.endpoint = try AnnexEndpoint(host: host, port: port, route: .localNetwork)
        self.identityFingerprintHint = txt["fingerprint"].flatMap { String(data: $0, encoding: .utf8) }
        self.pairingPortHint = txt["pairingPort"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(UInt16.init)
    }
}

nonisolated public struct AnnexDiscoveryState: Sendable {
    public let isSearching: Bool
    public let hosts: [AnnexDiscoveredHost]
    public let errorCode: Int?
}

/// LAN discovery for pairing, and for finding a remembered desktop that stopped
/// answering at its saved address (AnnexRediscovery). Creates no client identity
/// or connection credentials. Stop when the pairing sheet closes or the search
/// ends; never browse while the app is in the background.
@MainActor public final class AnnexDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let makeBrowser: () -> NetServiceBrowser
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var hosts: [String: AnnexDiscoveredHost] = [:]
    private var continuations: [UUID: AsyncStream<AnnexDiscoveryState>.Continuation] = [:]
    private var errorCode: Int?
    private var diagnostic: AnnexDiagnosticSpan?
    private var resolutions: [String: AnnexDiagnosticSpan] = [:]
    public override init() { makeBrowser = { NetServiceBrowser() }; super.init() }
    /// Injectable discovery engine; tests never browse the user's network.
    public init(makeBrowser: @escaping () -> NetServiceBrowser) { self.makeBrowser = makeBrowser; super.init() }
    public func states() -> AsyncStream<AnnexDiscoveryState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AnnexDiscoveryState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations.removeValue(forKey: id) } }
        return stream
    }
    private var current: AnnexDiscoveryState { AnnexDiscoveryState(isSearching: browser != nil, hosts: hosts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errorCode: errorCode) }
    /// Hosts resolved so far, for a caller that polls during a bounded search.
    public var discovered: [AnnexDiscoveredHost] { current.hosts }
    private func publish() { for continuation in continuations.values { continuation.yield(current) } }
    public func start() {
        guard browser == nil else { return }
        errorCode = nil
        diagnostic = AnnexTelemetry.shared.begin(.discovery)
        let browser = makeBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_clubhouse-annex._tcp.", inDomain: "local.")
        publish()
    }
    public func stop() {
        for span in resolutions.values { span.fail(.cancelled); span.end() }
        resolutions.removeAll()
        diagnostic?.number(.discoveredCount, Double(hosts.count)); diagnostic?.end(); diagnostic = nil
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services.values { service.stop(); service.delegate = nil }
        services.removeAll(); hosts.removeAll(); publish()
    }
    private func key(_ service: NetService) -> String { "\(service.domain)|\(service.type)|\(service.name)" }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = key(service)
        guard self.browser === browser, services[id] == nil, services.count < 64 else { return }
        diagnostic?.event(.found)
        services[id] = service
        resolutions[id] = AnnexTelemetry.shared.begin(.resolve, parent: diagnostic)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        let id = key(service)
        if let span = resolutions.removeValue(forKey: id) { span.fail(.cancelled); span.end() }
        services.removeValue(forKey: id)?.stop()
        hosts.removeValue(forKey: id); publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        diagnostic?.fail(.connection)
        errorCode = errorDict[NetService.errorCode]?.intValue
        stop()
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard services[id] === sender, let host = sender.hostName, let port = UInt16(exactly: sender.port), port != 0 else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard let discovered = try? AnnexDiscoveredHost(id: id, name: sender.name, host: host, port: port, txt: txt) else { return }
        resolutions.removeValue(forKey: id)?.end()
        diagnostic?.event(.resolved)
        hosts[id] = discovered; publish()
    }
    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = key(sender)
        guard services[id] === sender else { return }
        if let failure = resolutions.removeValue(forKey: id) { failure.fail(.dns); failure.end() }
        services.removeValue(forKey: id); hosts.removeValue(forKey: id); sender.stop(); publish()
    }
}
