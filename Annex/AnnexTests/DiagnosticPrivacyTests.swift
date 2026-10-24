import Foundation
import Testing
@testable import ClubhouseGo

@MainActor struct DiagnosticPrivacyTests {
    @Test func legacyLogNeverRetainsRawCategoryOrBody() {
        let log = AppLog.shared
        log.clear()
        let payload = "https://192.0.2.1/users/private?token=secret message contents"
        log.error(payload, payload)
        log.info("API", payload)
        #expect(!log.exportText.contains(payload))
        #expect(!log.exportText.contains("192.0.2.1"))
        #expect(!log.exportText.contains("token"))
        #expect(log.entries.last?.category == "API")
        #expect(log.entries.last?.message == "Details omitted for privacy")
        log.clear()
    }
}
