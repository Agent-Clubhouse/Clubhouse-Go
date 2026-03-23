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

@Observable final class BonjourDiscovery {
    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]

    func startSearching() {
        guard !isSearching else { return }
        isSearching = true
        servers = []

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_clubhouse-annex._tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleResultsChanged(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false
        for conn in connections.values {
            conn.cancel()
        }
        connections = [:]
    }

    private func handleResultsChanged(_ results: Set<NWBrowser.Result>) {
        var currentIds = Set<String>()

        for result in results {
            let endpointId = "\(result.endpoint)"
            currentIds.insert(endpointId)

            if servers.contains(where: { $0.id == endpointId }) {
                continue
            }

            // Parse TXT records from Bonjour metadata
            let txtRecords = parseTXTRecords(from: result.metadata)
            resolveEndpoint(result.endpoint, id: endpointId, txtRecords: txtRecords)
        }

        servers.removeAll { !currentIds.contains($0.id) }
    }

    private func parseTXTRecords(from metadata: NWBrowser.Result.Metadata?) -> [String: String] {
        guard case .bonjour(let txtRecord) = metadata else { return [:] }
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
        return records
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, id: String, txtRecords: [String: String]) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections[id] = conn

        let serviceName: String
        if case .service(let name, _, _, _) = endpoint {
            serviceName = name
        } else {
            serviceName = "Clubhouse Server"
        }

        // Determine protocol version from TXT records
        let protoVersion: ProtocolVersion
        let pairingPort: UInt16?
        let fingerprint: String?

        if txtRecords["v"] == "2",
           let ppStr = txtRecords["pairingPort"],
           let pp = UInt16(ppStr) {
            protoVersion = .v2
            pairingPort = pp
            fingerprint = txtRecords["fingerprint"]
        } else {
            protoVersion = .v1
            pairingPort = nil
            fingerprint = nil
        }

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
                    conn.cancel()
                    self.connections.removeValue(forKey: id)
                case .failed:
                    conn.cancel()
                    self.connections.removeValue(forKey: id)
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }
}

