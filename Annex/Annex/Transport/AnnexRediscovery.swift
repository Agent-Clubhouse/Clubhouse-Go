import Foundation

/// Finds a remembered desktop at a new address after its saved one stops answering: a Mac
/// renamed on the network, a new DHCP lease. Bonjour only suggests where to look. A candidate
/// is accepted only when its TLS certificate is the exact one pinned at pairing, so this never
/// creates trust; the probe sends nothing but the TLS hello.
nonisolated public enum AnnexRediscovery {
    /// Probes at most this many candidates per attempt.
    public static let probeLimit = 8

    /// Probes every known route at once and returns the best one serving the pinned
    /// certificate. `routes` is in preference order (current first, LAN before
    /// Tailscale): the first to answer wins unless a preferred one also answers within
    /// `grace`. Nil when none answers before `timeout`. Away from home this takes about
    /// as long as one Tailscale round trip instead of a connection timeout.
    public static func firstAnswering(_ host: TrustedAnnexHost, routes: [AnnexEndpoint],
                                      grace: Duration = .milliseconds(300), timeout: Duration = .seconds(4),
                                      probe: @escaping @Sendable (AnnexEndpoint) async throws -> AnnexCertificatePin) async -> AnnexEndpoint? {
        var unique: [AnnexEndpoint] = []
        for route in routes where !unique.contains(where: { $0.sameAddress(as: route) }) { unique.append(route) }
        guard !unique.isEmpty else { return nil }
        let pin = host.certificatePin
        let deadline = -1, graceOver = -2
        let best: Int? = await withTaskGroup(of: Int?.self) { group in
            for (index, route) in unique.enumerated() {
                group.addTask { (try? await probe(route)) == pin ? index : nil }
            }
            group.addTask { try? await Task.sleep(for: timeout); return deadline }
            var best: Int?
            var outstanding = unique.count
            for await result in group {
                if result == deadline || result == graceOver { break }
                outstanding -= 1
                if let result {
                    if best == nil { group.addTask { try? await Task.sleep(for: grace); return graceOver } }
                    best = min(best ?? result, result)
                }
                if best == 0 || outstanding == 0 { break }
            }
            group.cancelAll()
            return best
        }
        return best.map { unique[$0] }
    }

    public static func locate(_ host: TrustedAnnexHost, in candidates: [AnnexDiscoveredHost],
                              probe: (AnnexEndpoint) async throws -> AnnexCertificatePin) async -> AnnexEndpoint? {
        let fresh = candidates.filter { $0.endpoint.host != host.endpoint.host || $0.endpoint.port != host.endpoint.port }
        // An advertised fingerprint is unauthenticated: it orders the search and skips other
        // desktops, but the pinned certificate alone decides.
        let hinted = fresh.filter { $0.identityFingerprintHint?.lowercased() == host.hostID }
        let unhinted = fresh.filter { $0.identityFingerprintHint == nil }
        for candidate in (hinted + unhinted).prefix(probeLimit) {
            if (try? await probe(candidate.endpoint)) == host.certificatePin { return candidate.endpoint }
        }
        return nil
    }
}
