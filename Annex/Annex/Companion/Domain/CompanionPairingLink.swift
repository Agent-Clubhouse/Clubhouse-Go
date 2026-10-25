import Foundation

/// A pairing invitation from the QR code in the desktop's Annex settings (contract v1):
/// `clubhousego://pair?v=1&host=<ip>&host=<ip2>&port=<main TLS port>&id=<identity fingerprint>&cert=<TLS SHA-256>&pin=<PIN>&name=<alias>`
/// Scanning it proves the desktop's identity and certificate, so there are no fingerprints to compare by eye.
struct CompanionPairingLink: Equatable, Sendable {
    static let scheme = "clubhousego"
    /// Addresses in the desktop's order of preference: LAN first, then Tailscale.
    var hosts: [String]
    var port: UInt16
    /// The desktop's identity fingerprint: 16 colon-separated hex pairs.
    var identity: String
    /// SHA-256 of the desktop's TLS leaf certificate: 64 lowercase hex characters.
    var certificate: String
    var pin: String
    var name: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("v") == "1",
              let port = value("port").flatMap(UInt16.init), port > 0,
              let identity = value("id")?.lowercased(), Self.isIdentity(identity),
              let certificate = value("cert")?.replacingOccurrences(of: ":", with: "").lowercased(),
              certificate.count == 64, certificate.allSatisfy(\.isHexDigit),
              let pin = value("pin"), !pin.isEmpty, pin.allSatisfy(\.isNumber) else { return nil }
        let hosts = items.filter { $0.name == "host" }.compactMap(\.value).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.hosts = hosts
        self.port = port
        self.identity = identity
        self.certificate = certificate
        self.pin = pin
        self.name = value("name").flatMap { $0.isEmpty ? nil : $0 }
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    private static func isIdentity(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 16 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }
}

/// What one pairing sends to the desktop and what this phone calls that desktop afterwards.
/// The desktop stores `alias` as the name of the phone controlling it, so it is always the phone's own name.
/// Desktop names, typed, discovered, or read from a QR code, are only ever the local label.
struct CompanionPairingNames: Equatable, Sendable {
    /// This phone's name, sent as `alias` in `POST /pair`.
    var alias: String
    /// The desktop's name on this phone. Nil keeps the name the desktop reports when pairing.
    var desktopLabel: String?

    init(deviceName: String, desktopName: String?) {
        alias = deviceName
        desktopLabel = desktopName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A QR or `clubhousego://pair` invitation: its `name` is the desktop's.
    init(deviceName: String, link: CompanionPairingLink) { self.init(deviceName: deviceName, desktopName: link.name) }
}
