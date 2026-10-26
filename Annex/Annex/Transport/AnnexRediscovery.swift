import Foundation

/// Finds a remembered desktop at a new address after its saved one stops answering: a Mac
/// renamed on the network, a new DHCP lease. Bonjour only suggests where to look. A candidate
/// is accepted only when its TLS certificate is the exact one pinned at pairing, so this never
/// creates trust; the probe sends nothing but the TLS hello.
nonisolated public enum AnnexRediscovery {
    /// Probes at most this many candidates per attempt.
    public static let probeLimit = 8

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
