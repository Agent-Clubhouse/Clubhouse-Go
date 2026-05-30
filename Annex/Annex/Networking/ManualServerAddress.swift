import Foundation

/// Parsed address from user-entered text in the manual-pair flow.
struct ManualServerAddress: Equatable {
    let host: String
    /// Main (mTLS) port — defaults to `defaultMainPort` when the user omits `:port`.
    let mainPort: UInt16

    /// Default ports matching the Clubhouse desktop server when TXT records can't be discovered.
    static let defaultMainPort: UInt16 = 8443
    static let defaultPairingPort: UInt16 = 8080

    /// Parse `host`, `host:port`, or `[ipv6]:port` from raw user input.
    /// Returns nil for empty/whitespace-only input or invalid port numbers.
    static func parse(_ raw: String) -> ManualServerAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bracketed IPv6: [::1]:8443 or [::1]
        if trimmed.hasPrefix("[") {
            guard let closeIdx = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            guard !host.isEmpty else { return nil }
            let afterBracket = trimmed[trimmed.index(after: closeIdx)...]
            if afterBracket.isEmpty {
                return ManualServerAddress(host: host, mainPort: defaultMainPort)
            }
            guard afterBracket.hasPrefix(":") else { return nil }
            let portStr = afterBracket.dropFirst()
            guard let port = parsePort(String(portStr)) else { return nil }
            return ManualServerAddress(host: host, mainPort: port)
        }

        // Bare IPv6 (multiple colons, no brackets) — accept as host only, no port.
        if trimmed.filter({ $0 == ":" }).count >= 2 {
            return ManualServerAddress(host: trimmed, mainPort: defaultMainPort)
        }

        // host or host:port
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let host = String(trimmed[..<colonIdx])
            let portStr = String(trimmed[trimmed.index(after: colonIdx)...])
            guard !host.isEmpty, let port = parsePort(portStr) else { return nil }
            return ManualServerAddress(host: host, mainPort: port)
        }

        return ManualServerAddress(host: trimmed, mainPort: defaultMainPort)
    }

    private static func parsePort(_ s: String) -> UInt16? {
        guard let n = Int(s), n > 0, n <= 65535 else { return nil }
        return UInt16(n)
    }
}
