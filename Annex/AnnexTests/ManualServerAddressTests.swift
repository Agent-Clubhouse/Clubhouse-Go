import Testing
import Foundation
@testable import ClubhouseGo

struct ManualServerAddressTests {
    @Test func hostOnlyUsesDefaultMainPort() {
        let parsed = ManualServerAddress.parse("100.64.0.5")
        #expect(parsed == ManualServerAddress(host: "100.64.0.5", mainPort: 8443))
    }

    @Test func hostnameOnlyUsesDefaultMainPort() {
        let parsed = ManualServerAddress.parse("my-host.tail.ts.net")
        #expect(parsed == ManualServerAddress(host: "my-host.tail.ts.net", mainPort: 8443))
    }

    @Test func hostWithPortIsParsed() {
        let parsed = ManualServerAddress.parse("192.168.1.10:9000")
        #expect(parsed == ManualServerAddress(host: "192.168.1.10", mainPort: 9000))
    }

    @Test func hostnameWithPortIsParsed() {
        let parsed = ManualServerAddress.parse("clubhouse.local:8443")
        #expect(parsed == ManualServerAddress(host: "clubhouse.local", mainPort: 8443))
    }

    @Test func leadingAndTrailingWhitespaceTrimmed() {
        let parsed = ManualServerAddress.parse("   100.64.0.5:8443  \n")
        #expect(parsed == ManualServerAddress(host: "100.64.0.5", mainPort: 8443))
    }

    @Test func emptyInputReturnsNil() {
        #expect(ManualServerAddress.parse("") == nil)
        #expect(ManualServerAddress.parse("   ") == nil)
        #expect(ManualServerAddress.parse("\n\t") == nil)
    }

    @Test func invalidPortReturnsNil() {
        #expect(ManualServerAddress.parse("host:abc") == nil)
        #expect(ManualServerAddress.parse("host:0") == nil)
        #expect(ManualServerAddress.parse("host:65536") == nil)
        #expect(ManualServerAddress.parse("host:-1") == nil)
        #expect(ManualServerAddress.parse("host:") == nil)
    }

    @Test func emptyHostReturnsNil() {
        #expect(ManualServerAddress.parse(":8443") == nil)
    }

    @Test func bracketedIPv6WithPort() {
        let parsed = ManualServerAddress.parse("[fe80::1]:8443")
        #expect(parsed == ManualServerAddress(host: "fe80::1", mainPort: 8443))
    }

    @Test func bracketedIPv6WithoutPort() {
        let parsed = ManualServerAddress.parse("[::1]")
        #expect(parsed == ManualServerAddress(host: "::1", mainPort: 8443))
    }

    @Test func bareIPv6WithMultipleColonsTreatedAsHostOnly() {
        // Bare IPv6 without brackets has ambiguous port — accept as host with default port.
        let parsed = ManualServerAddress.parse("fe80::1")
        #expect(parsed == ManualServerAddress(host: "fe80::1", mainPort: 8443))
    }

    @Test func malformedBracketedIPv6ReturnsNil() {
        #expect(ManualServerAddress.parse("[fe80::1") == nil)
        #expect(ManualServerAddress.parse("[]:8443") == nil)
        #expect(ManualServerAddress.parse("[fe80::1]xyz") == nil)
    }

    @Test func defaultsMatchTestServerConvention() {
        #expect(ManualServerAddress.defaultMainPort == 8443)
        #expect(ManualServerAddress.defaultPairingPort == 8080)
    }
}
