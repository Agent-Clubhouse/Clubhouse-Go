import Testing
import Foundation
@testable import ClubhouseGo

@MainActor struct FramebriarIntegrationTests {
    @Test func unconfiguredBuildCreatesNoFeedbackClient() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "FramebriarGameID") == nil)
        #expect(CompanionFeedback.makeModel() == nil)
    }

}
