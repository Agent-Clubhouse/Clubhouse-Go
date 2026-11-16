import XCTest
@testable import ClubhouseGo

@MainActor final class CompanionManagedSpawnFormTests: XCTestCase {
    private var options: CompanionCreateOptions {
        .init(options: .init(), managed: .init(defaultOn: true, templates: [
            .init(id: "helper", name: "Helper", description: "A focused helper", builtin: true),
            .init(id: "lead", name: "Team lead", description: "Coordinates work", builtin: false,
                  orchestrator: "claude-code", model: "custom-lead-model", access: .plan)
        ]), isGitRepo: true, suggestedName: "brave-otter", defaultOrchestrator: "codex-cli", defaultModel: "default")
    }

    func testManagedDefaultRequiresCapabilityAndDesktopOptions() {
        var form = CompanionSpawnSheet.DurableForm()
        form.reset(to: options)
        XCTAssertFalse(form.managedOn)
        form.reset(to: options, supportsManaged: true)
        XCTAssertTrue(form.managedOn)
        XCTAssertNil(form.managedSelection)
        form.selectTemplate(.template("lead"))
        form.managedOn = false
        form.reset(to: options, supportsManaged: true)
        XCTAssertTrue(form.managedOn, "Reopening uses the shipped default, not the previous toggle")
        XCTAssertNil(form.managedSelection, "Every sheet starts with an explicit choice")
        var off = options
        off.managed?.defaultOn = false
        form.reset(to: off, supportsManaged: true)
        XCTAssertFalse(form.managedOn)
        off.managed = nil
        form.reset(to: off, supportsManaged: true)
        XCTAssertFalse(form.managedOn)
    }

    func testTemplateFillsProviderAndCustomModelWithoutCreatingAnOverride() {
        var form = CompanionSpawnSheet.DurableForm()
        form.reset(to: options, supportsManaged: true)
        form.selectTemplate(.template("lead"))
        XCTAssertEqual(form.orchestrator, "claude-code")
        XCTAssertEqual(form.model, "custom-lead-model")
        XCTAssertNil(form.managedOrchestratorOverride)
        XCTAssertNil(form.managedModelOverride)
        form.selectTemplate(.template("helper"))
        XCTAssertEqual(form.orchestrator, "codex-cli")
        XCTAssertEqual(form.model, "default")
    }

    func testExplicitRuntimeChoicesWinWhenATemplateIsPickedAfterThem() {
        var form = CompanionSpawnSheet.DurableForm()
        form.reset(to: options, supportsManaged: true)
        form.managedOrchestratorOverride = "codex-cli"
        form.managedModelOverride = "default"
        form.selectTemplate(.template("lead"))
        XCTAssertEqual(form.orchestrator, "codex-cli")
        XCTAssertEqual(form.model, "default")
        XCTAssertEqual(form.managedOrchestratorOverride, "codex-cli")
        XCTAssertEqual(form.managedModelOverride, "default")
        form.managedModelOverride = nil
        form.selectTemplate(.template("lead"))
        XCTAssertEqual(form.orchestrator, "codex-cli")
        XCTAssertEqual(form.model, "custom-lead-model", "Provider and model overrides are independent")
        form.managedOrchestratorOverride = nil
        form.managedModelOverride = "default"
        form.selectTemplate(.template("lead"))
        XCTAssertEqual(form.orchestrator, "claude-code")
        XCTAssertEqual(form.model, "default")
    }

    func testBlankIsLocalAndResetsTemplateSettings() {
        var form = CompanionSpawnSheet.DurableForm()
        form.reset(to: options, supportsManaged: true)
        form.selectTemplate(.template("lead"))
        form.selectTemplate(.blank)
        XCTAssertEqual(form.managedSelection, .blank)
        XCTAssertEqual(form.orchestrator, "codex-cli")
        XCTAssertEqual(form.model, "default")
        XCTAssertFalse(options.managed!.templates.contains { $0.id == "blank" })
    }

    func testManagedNameNeedsFolderValidationEvenAfterPlainWorktreeWasTurnedOff() {
        var form = CompanionSpawnSheet.DurableForm()
        form.reset(to: options, supportsManaged: true)
        form.useWorktree = false
        form.name = "two words"
        XCTAssertNotNil(form.nameProblem)
        form.managedOn = false
        XCTAssertNil(form.nameProblem)
    }
}
