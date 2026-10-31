import Foundation
import Testing
@testable import CompanionDomain

struct CompanionBuildInfoTests {
    @Test func acceptsOnlyARealCommit() {
        let full = "4905102899ee20db0c436716f4783f6ba9827c5d"
        #expect(CompanionBuildInfo.buildSHA(full) == full)
        #expect(CompanionBuildInfo.buildSHA("4905102") == "4905102")
        #expect(CompanionBuildInfo.buildSHA(" 4905102899EE20DB0C436716F4783F6BA9827C5D\n") == full)
    }

    @Test func emptyOrUnexpandedOrMalformedIsNil() {
        // Local and CI builds without git leave the setting empty; the report then has no buildSha.
        for value: Any? in [nil, "", "   ", "$(FRAMEBRIAR_BUILD_SHA)", "490510", "2.0.0", "v0.5.0",
                            String(repeating: "a", count: 41), "4905102g", 4905102] {
            #expect(CompanionBuildInfo.buildSHA(value) == nil)
        }
    }

    @Test func infoPlistDeclaresTheKeyFromTheBuildSetting() throws {
        let plist = try String(contentsOf: Self.repo.appendingPathComponent("Annex/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<key>\(CompanionBuildInfo.buildSHAKey)</key>\n\t<string>$(FRAMEBRIAR_BUILD_SHA)</string>"))
        let archive = try String(contentsOf: Self.repo.appendingPathComponent("scripts/testflight.sh"), encoding: .utf8)
        #expect(archive.contains("FRAMEBRIAR_BUILD_SHA=\"$BUILD_SHA\""))
    }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
