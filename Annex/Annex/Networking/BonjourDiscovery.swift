import Foundation
import Network

enum ProtocolVersion: Sendable {
    case v1
    case v2
}

struct DiscoveredServer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let protocolVersion: ProtocolVersion
    let pairingPort: UInt16?
    let fingerprint: String?

    static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable final class BonjourDiscovery: NSObject {
    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]

    /// NetService instances kept alive during TXT resolution
    private var resolvingServices: [String: NetService] = [:]

    /// Servers waiting for TXT resolution (keyed by endpoint ID)
    private struct PendingServer {
        let id: String
        let name: String
        let host: String
        let port: UInt16
    }
    private var pendingTXTResolution: [String: PendingServer] = [:]

    func startSearching() {
        guard !isSearching else {
            AppLog.shared.debug("Bonjour", "startSearching called but already searching — ignored")
            return
        }
        isSearching = true
        servers = []
        AppLog.shared.info("Bonjour", "Starting mDNS browse for _clubhouse-annex._tcp")

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_clubhouse-annex._tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    AppLog.shared.info("Bonjour", "Browser ready — actively browsing")
                case .failed(let error):
                    AppLog.shared.error("Bonjour", "Browser failed: \(error)")
                    self?.isSearching = false
                case .cancelled:
                    AppLog.shared.info("Bonjour", "Browser cancelled")
                    self?.isSearching = false
                case .waiting(let error):
                    AppLog.shared.warn("Bonjour", "Browser waiting: \(error) — check local network permission")
                default:
                    AppLog.shared.debug("Bonjour", "Browser state: \(state)")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                AppLog.shared.debug("Bonjour", "Browse results changed: \(results.count) result(s), \(changes.count) change(s)")
                for change in changes {
                    switch change {
                    case .added(let result):
                        AppLog.shared.info("Bonjour", "Service added: \(result.endpoint)")
                    case .removed(let result):
                        AppLog.shared.info("Bonjour", "Service removed: \(result.endpoint)")
                    case .identical:
                        break
                    @unknown default:
                        break
                    }
                }
                self?.handleResultsChanged(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopSearching() {
        AppLog.shared.info("Bonjour", "Stopping search (had \(servers.count) server(s), \(connections.count) pending resolution(s))")
        browser?.cancel()
        browser = nil
        isSearching = false
        for conn in connections.values {
            conn.cancel()
        }
        connections = [:]
        for svc in resolvingServices.values {
            svc.stop()
        }
        resolvingServices = [:]
        pendingTXTResolution = [:]
    }

    private func handleResultsChanged(_ results: Set<NWBrowser.Result>) {
        var currentIds = Set<String>()

        for result in results {
            let endpointId = "\(result.endpoint)"
            currentIds.insert(endpointId)

            if servers.contains(where: { $0.id == endpointId }) {
                continue
            }

            // Try NWBrowser metadata first (may be .none with some Bonjour publishers)
            let txtRecords = parseTXTRecords(from: result.metadata)
            AppLog.shared.info("Bonjour", "Resolving endpoint \(endpointId), TXT: \(txtRecords)")
            resolveEndpoint(result.endpoint, id: endpointId, txtRecords: txtRecords)
        }

        let removedCount = servers.filter { !currentIds.contains($0.id) }.count
        if removedCount > 0 {
            AppLog.shared.info("Bonjour", "Removing \(removedCount) stale server(s)")
        }
        servers.removeAll { !currentIds.contains($0.id) }
    }

    private func parseTXTRecords(from metadata: NWBrowser.Result.Metadata?) -> [String: String] {
        guard case .bonjour(let txtRecord) = metadata else {
            AppLog.shared.debug("Bonjour", "No Bonjour metadata in result")
            return [:]
        }
        var records: [String: String] = [:]
        for key in ["v", "pairingPort", "fingerprint"] {
            if let entry = txtRecord.getEntry(for: key) {
                switch entry {
                case .string(let value):
                    records[key] = value
                case .data(let data):
                    if let value = String(data: data, encoding: .utf8) {
                        records[key] = value
                    }
                default:
                    break
                }
            }
        }
        AppLog.shared.debug("Bonjour", "Parsed TXT records: \(records)")
        return records
    }

    /// Parse TXT record data from NetService (binary DNS TXT format)
    private func parseTXTData(_ data: Data) -> [String: String] {
        let dict = NetService.dictionary(fromTXTRecord: data)
        var records: [String: String] = [:]
        for (key, value) in dict {
            if let str = String(data: value, encoding: .utf8) {
                records[key] = str
            }
        }
        return records
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, id: String, txtRecords: [String: String]) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections[id] = conn

        let serviceName: String
        let serviceNameRaw: String?
        let serviceDomain: String?
        if case .service(let name, _, let domain, _) = endpoint {
            serviceName = name
            serviceNameRaw = name
            serviceDomain = domain
        } else {
            serviceName = "Clubhouse Server"
            serviceNameRaw = nil
            serviceDomain = nil
        }

        // Determine protocol version from TXT records
        let protoVersion: ProtocolVersion
        let pairingPort: UInt16?
        let fingerprint: String?

        if txtRecords["v"] == "2",
           let ppStr = txtRecords["pairingPort"],
           let pp = UInt16(ppStr) {
            AppLog.shared.info("Bonjour", "v2 server (from NWBrowser TXT): \(serviceName) pairingPort=\(pp) fingerprint=\(txtRecords["fingerprint"] ?? "?")")
            protoVersion = .v2
            pairingPort = pp
            fingerprint = txtRecords["fingerprint"]
        } else {
            // TXT records missing from NWBrowser — will resolve via NetService
            protoVersion = .v1
            pairingPort = nil
            fingerprint = nil
            if txtRecords.isEmpty {
                AppLog.shared.info("Bonjour", "No TXT from NWBrowser for \(serviceName) — will resolve via NetService")
            } else {
                AppLog.shared.info("Bonjour", "Incomplete TXT for \(serviceName): \(txtRecords)")
            }
        }

        let needsTXTResolution = protoVersion == .v1 && txtRecords.isEmpty && serviceNameRaw != nil

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let innerEndpoint = conn.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = innerEndpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr):
                            let raw = "\(addr)"
                            hostStr = raw.split(separator: "%").first.map(String.init) ?? raw
                        case .ipv6(let addr):
                            let raw = "\(addr)"
                            hostStr = raw.split(separator: "%").first.map(String.init) ?? raw
                        case .name(let name, _):
                            hostStr = name
                        @unknown default:
                            hostStr = "\(host)"
                        }

                        if needsTXTResolution {
                            // Store pending server and resolve TXT via NetService
                            AppLog.shared.info("Bonjour", "Resolved \(serviceName) -> \(hostStr):\(port.rawValue), resolving TXT via NetService...")
                            self.pendingTXTResolution[id] = PendingServer(
                                id: id, name: serviceName,
                                host: hostStr, port: port.rawValue
                            )
                            self.resolveTXTViaNetService(
                                id: id,
                                serviceName: serviceNameRaw!,
                                domain: serviceDomain ?? "local."
                            )
                        } else {
                            AppLog.shared.info("Bonjour", "Resolved \(serviceName) -> \(hostStr):\(port.rawValue) (proto=\(protoVersion == .v2 ? "v2" : "v1"))")
                            let server = DiscoveredServer(
                                id: id,
                                name: serviceName,
                                host: hostStr,
                                port: port.rawValue,
                                protocolVersion: protoVersion,
                                pairingPort: pairingPort,
                                fingerprint: fingerprint
                            )
                            if !self.servers.contains(where: { $0.id == id }) {
                                self.servers.append(server)
                            }
                        }
                    } else {
                        AppLog.shared.warn("Bonjour", "Connection ready but could not extract host:port from path for \(serviceName)")
                    }
                    conn.cancel()
                    self.connections.removeValue(forKey: id)
                case .failed(let error):
                    AppLog.shared.error("Bonjour", "Resolution connection failed for \(serviceName): \(error)")
                    conn.cancel()
                    self.connections.removeValue(forKey: id)
                case .waiting(let error):
                    AppLog.shared.warn("Bonjour", "Resolution connection waiting for \(serviceName): \(error)")
                case .preparing:
                    AppLog.shared.debug("Bonjour", "Resolution connection preparing for \(serviceName)")
                default:
                    AppLog.shared.debug("Bonjour", "Resolution connection state for \(serviceName): \(state)")
                }
            }
        }

        conn.start(queue: .main)
    }

    // MARK: - NetService TXT Resolution

    private func resolveTXTViaNetService(id: String, serviceName: String, domain: String) {
        let svc = NetService(domain: domain, type: "_clubhouse-annex._tcp.", name: serviceName)
        svc.delegate = self
        resolvingServices[id] = svc
        AppLog.shared.info("Bonjour", "Starting NetService TXT resolve for '\(serviceName)' in domain '\(domain)'")
        svc.startMonitoring()
    }

    private func finalizePendingServer(serviceName: String, txtRecords: [String: String]) {
        // Find the pending server by name
        guard let (id, pending) = pendingTXTResolution.first(where: { $0.value.name == serviceName }) else {
            AppLog.shared.warn("Bonjour", "TXT resolved for '\(serviceName)' but no pending server found")
            return
        }

        let protoVersion: ProtocolVersion
        let pairingPort: UInt16?
        let fingerprint: String?

        if txtRecords["v"] == "2",
           let ppStr = txtRecords["pairingPort"],
           let pp = UInt16(ppStr) {
            AppLog.shared.info("Bonjour", "v2 server (from NetService TXT): \(pending.name) pairingPort=\(pp) fingerprint=\(txtRecords["fingerprint"] ?? "?")")
            protoVersion = .v2
            pairingPort = pp
            fingerprint = txtRecords["fingerprint"]
        } else {
            AppLog.shared.warn("Bonjour", "NetService TXT resolved but not v2: \(txtRecords)")
            protoVersion = .v1
            pairingPort = nil
            fingerprint = nil
        }

        let server = DiscoveredServer(
            id: id,
            name: pending.name,
            host: pending.host,
            port: pending.port,
            protocolVersion: protoVersion,
            pairingPort: pairingPort,
            fingerprint: fingerprint
        )

        if let existingIdx = servers.firstIndex(where: { $0.id == id }) {
            servers[existingIdx] = server
        } else {
            servers.append(server)
        }

        pendingTXTResolution.removeValue(forKey: id)
        resolvingServices[id]?.stop()
        resolvingServices.removeValue(forKey: id)
    }
}

// MARK: - NetServiceDelegate (TXT record resolution)

extension BonjourDiscovery: NetServiceDelegate {
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let txtRecords = parseTXTData(data)
        AppLog.shared.info("Bonjour", "NetService TXT update for '\(sender.name)': \(txtRecords)")
        finalizePendingServer(serviceName: sender.name, txtRecords: txtRecords)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        AppLog.shared.error("Bonjour", "NetService resolve failed for '\(sender.name)': \(errorDict)")
    }
}
