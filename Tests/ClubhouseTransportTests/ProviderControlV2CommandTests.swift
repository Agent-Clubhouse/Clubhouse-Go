import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct ProviderControlV2CommandTests {
    private func fixture() throws -> AnnexJSON {
        let url = try #require(Bundle.module.url(forResource: "provider-control-v2", withExtension: "json", subdirectory: "Fixtures/ProviderControlV2"))
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: url))
    }
    private func check(_ request: AnnexJSON, kind: AnnexCommand.Kind) throws {
        let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: kind)
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == request)
    }
    @Test func providerOnlyCommandsMatchMergedOmissionsExactly() throws {
        let fixture = try fixture()
        for key in ["preview", "savedDefaultsPreview", "inheritedPreview"] {
            let request = try #require(fixture[key]?["request"])
            try check(request, kind: .providerPreviewV2(agentID: try #require(request["agentId"]?.string), provider: try #require(request["provider"]?.string), selection: .init()))
        }
        let request = try #require(fixture["applied"]?["request"])
        try check(request, kind: .providerChangeV2(agentID: try #require(request["agentId"]?.string), provider: try #require(request["provider"]?.string), selection: .init(), expectedState: try #require(request["expectedState"]?.string)))
    }
    @Test func typedExplicitClearsRemainDistinctFromProviderOnlyCommands() throws {
        let fixture = try fixture(), selection = AnnexProviderSelectionV2(model: .providerDefault, effort: .clear)
        let preview = try #require(fixture["defaultPreview"]?["request"])
        try check(preview, kind: .providerPreviewV2(agentID: try #require(preview["agentId"]?.string), provider: try #require(preview["provider"]?.string), selection: selection))
        let apply = try #require(fixture["defaultApply"]?["request"])
        try check(apply, kind: .providerChangeV2(agentID: try #require(apply["agentId"]?.string), provider: try #require(apply["provider"]?.string), selection: selection, expectedState: try #require(apply["expectedState"]?.string)))
    }
    @Test func strictStartEchoesFullMergedNextWakeAndOpaqueState() throws {
        let fixture = try fixture()
        for key in ["started", "immediateExit", "failedAfterCreation", "refusedBeforeCreation"] {
            let request = try #require(fixture[key]?["request"])
            let expected = try #require(request["expectedNextWake"]).decode(AnnexProviderNextWakeV2.self)
            try check(request, kind: .providerStartV2(agentID: try #require(request["agentId"]?.string), expected: expected, expectedState: try #require(request["expectedState"]?.string)))
        }
    }
}
