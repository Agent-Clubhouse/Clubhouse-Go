import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Answers `POST /pair` as a desktop named "Mason's Mac" and keeps the request.
private actor CapturingPairIO: AnnexIO {
    let response: Data
    private(set) var requests: [URLRequest] = []
    init(_ response: Data) { self.response = response }
    func perform(_ request: URLRequest) -> AnnexHTTPResponse { requests.append(request); return AnnexHTTPResponse(status: 200, data: response) }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
    func pairBody() throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: #require(requests.last?.httpBody)) }
}

private struct Desktop {
    let host: TrustedAnnexHost
    let io: CapturingPairIO
    let registry: AnnexTransportRegistry
    init() throws {
        let server = AnnexPairingIdentity()
        host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "10.0.0.2", port: 7787),
                                    verifiedHostID: AnnexPairingIdentity.fingerprint(publicKeyBase64: server.publicKeyBase64),
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let body: AnnexJSON = .object(["token": .string("fake-only"), "publicKey": .string(server.publicKeyBase64),
            "fingerprint": .string(host.hostID), "alias": .string("Mason's Mac"), "tlsCertificateFingerprint": .string(host.certificatePin.sha256),
            "mobileProtocolVersion": .integer(1), "pairingMode": .string("session")])
        let io = try CapturingPairIO(JSONEncoder().encode(body))
        self.io = io
        registry = AnnexTransportRegistry(credentials: MemoryAnnexCredentialStore(), pairings: nil, pairingIO: { _, _ in io })
    }
    func pair(_ names: CompanionPairingNames) async throws -> AnnexTransportRegistry.Registration {
        try await registry.pair(host: host, pin: "123456", alias: names.alias, label: names.desktopLabel, persistence: .sessionOnly)
    }
}

@MainActor private func makePreferences(system: String = "iPhone") throws -> (CompanionPreferences, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "companion-device-\(UUID().uuidString)"))
    return (CompanionPreferences(defaults: defaults, systemDeviceName: system), defaults)
}

@MainActor struct CompanionDeviceNameTests {
    @Test func firstRunStartsWithTheSystemName() throws {
        let (preferences, defaults) = try makePreferences(system: "Mason's iPhone")
        #expect(preferences.deviceName == "Mason's iPhone")
        #expect(preferences.pairingAlias == "Mason's iPhone")
        // Nothing is saved until the name is edited or used, so a later system name still applies.
        #expect(defaults.string(forKey: "companion.deviceName") == nil)
        #expect(CompanionPreferences(defaults: defaults, systemDeviceName: "Renamed").deviceName == "Renamed")
    }

    @Test func editedNamePersists() throws {
        let (preferences, defaults) = try makePreferences()
        preferences.deviceName = "Travel phone"
        #expect(CompanionPreferences(defaults: defaults, systemDeviceName: "iPhone").deviceName == "Travel phone")
        #expect(CompanionPreferences(defaults: defaults, systemDeviceName: "iPhone").pairingAlias == "Travel phone")
    }

    @Test func pairingAliasIsTrimmedNeverEmptyAndBounded() throws {
        let (preferences, _) = try makePreferences(system: "iPhone")
        preferences.deviceName = "  Work phone \n"
        #expect(preferences.pairingAlias == "Work phone")
        preferences.deviceName = "   "
        #expect(preferences.pairingAlias == "iPhone")
        preferences.deviceName = String(repeating: "x", count: 300)
        #expect(preferences.pairingAlias.count == 128)
        let (blankSystem, _) = try makePreferences(system: "")
        blankSystem.deviceName = ""
        #expect(blankSystem.pairingAlias == "iPhone")
    }

    @Test func savingKeepsTheNameUsedToPair() throws {
        let (preferences, defaults) = try makePreferences(system: "iPhone")
        preferences.saveDeviceName()
        #expect(defaults.string(forKey: "companion.deviceName") == "iPhone")
        preferences.deviceName = " Desk phone "
        preferences.saveDeviceName()
        #expect(CompanionPreferences(defaults: defaults).deviceName == "Desk phone")
    }

    @Test func manualPairingSendsThePhoneNameNotTheDesktopName() async throws {
        let desktop = try Desktop()
        let registration = try await desktop.pair(CompanionPairingNames(deviceName: "Mason's iPhone", desktopName: "Studio Mac"))
        let body = try await desktop.io.pairBody()
        #expect(body["alias"]?.string == "Mason's iPhone")
        #expect(body["alias"]?.string != "Studio Mac")
        #expect(registration.alias == "Studio Mac")
    }

    @Test func manualPairingWithoutADesktopNameKeepsTheDesktopsOwn() async throws {
        let desktop = try Desktop()
        let registration = try await desktop.pair(CompanionPairingNames(deviceName: "Mason's iPhone", desktopName: "  "))
        #expect(try await desktop.io.pairBody()["alias"]?.string == "Mason's iPhone")
        #expect(registration.alias == "Mason's Mac")
    }

    @Test func invitationPairingSendsThePhoneNameNotTheLinkName() async throws {
        let id = Array(repeating: "ab", count: 16).joined(separator: ":")
        let link = try #require(CompanionPairingLink(string:
            "clubhousego://pair?v=1&host=10.0.0.2&port=7787&id=\(id)&cert=\(String(repeating: "cd", count: 32))&pin=123456&name=Mason%27s%20Mac"))
        let names = CompanionPairingNames(deviceName: "Mason's iPhone", link: link)
        #expect(names == CompanionPairingNames(deviceName: "Mason's iPhone", desktopName: "Mason's Mac"))
        let desktop = try Desktop()
        let registration = try await desktop.pair(names)
        let body = try await desktop.io.pairBody()
        #expect(body["alias"]?.string == "Mason's iPhone")
        #expect(body["alias"]?.string != link.name)
        #expect(registration.alias == "Mason's Mac")
    }
}
