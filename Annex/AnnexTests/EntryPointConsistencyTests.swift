import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - #87 Canvas presentation

@MainActor
struct CanvasPresentationTests {
    @Test func noCanvasesShowsEmpty() {
        #expect(CanvasPresentation.mode(canvasCount: 0) == .empty)
    }

    @Test func negativeCountTreatedAsEmpty() {
        // Defensive: counts are never negative, but the boundary must not crash.
        #expect(CanvasPresentation.mode(canvasCount: -1) == .empty)
    }

    @Test func singleCanvasRendersDirectly() {
        #expect(CanvasPresentation.mode(canvasCount: 1) == .single)
    }

    @Test func multipleCanvasesShowSelector() {
        #expect(CanvasPresentation.mode(canvasCount: 2) == .selector)
        #expect(CanvasPresentation.mode(canvasCount: 5) == .selector)
    }
}

// MARK: - #92 Orchestrator display resolution

@MainActor @Suite(.serialized)
struct OrchestratorDisplayTests {
    private func makeInstance(idValue: String,
                              orchestrators: [String: OrchestratorEntry]) -> ServerInstance {
        let inst = ServerInstance(
            id: ServerInstanceID(value: idValue),
            protocolConfig: .v2(host: "localhost", mainPort: 8443, pairingPort: 8080,
                                fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99")
        )
        inst.orchestrators = orchestrators
        inst.connectionState = .connected
        return inst
    }

    /// Two connected instances that both define orchestrator id "cc" but with
    /// different short names, plus one ("xyz") only present on instance 2.
    private func makeStore() -> (AppStore, ServerInstanceID, ServerInstanceID) {
        let store = AppStore()
        let id1 = ServerInstanceID(value: "inst-1")
        let id2 = ServerInstanceID(value: "inst-2")
        let inst1 = makeInstance(idValue: id1.value, orchestrators: [
            "cc": OrchestratorEntry(displayName: "Claude Code A", shortName: "CC-A", badge: nil),
        ])
        let inst2 = makeInstance(idValue: id2.value, orchestrators: [
            "cc": OrchestratorEntry(displayName: "Claude Code B", shortName: "CC-B", badge: nil),
            "xyz": OrchestratorEntry(displayName: "Experimental", shortName: "XYZ", badge: nil),
        ])
        store.instances = [inst1, inst2]
        return (store, id1, id2)
    }

    @Test func instanceScopedNameWins() {
        let (store, id1, id2) = makeStore()
        // The same orchestrator id resolves per the project's own instance,
        // so the same project looks the same regardless of entry point.
        #expect(store.orchestratorDisplayName("cc", instanceId: id1) == "CC-A")
        #expect(store.orchestratorDisplayName("cc", instanceId: id2) == "CC-B")
    }

    @Test func fallsBackToMergedMapWhenInstanceLacksIt() {
        let (store, id1, _) = makeStore()
        // instance 1 has no "xyz" — resolution falls back to the merged map.
        #expect(store.orchestratorDisplayName("xyz", instanceId: id1) == "XYZ")
    }

    @Test func fallsBackToRawIdWhenUnknown() {
        let (store, id1, _) = makeStore()
        #expect(store.orchestratorDisplayName("nope", instanceId: id1) == "nope")
    }

    @Test func nilInstanceUsesMergedMap() {
        let (store, _, _) = makeStore()
        // With no instance context, the merged map is used (last-writer wins on
        // collision); either valid short name is acceptable, never the raw id.
        #expect(["CC-A", "CC-B"].contains(store.orchestratorDisplayName("cc", instanceId: nil)))
        #expect(store.orchestratorDisplayName("xyz", instanceId: nil) == "XYZ")
    }
}

// MARK: - #92 Entry-point navigation parity

@MainActor
struct ProjectEntryPointParityTests {
    /// Both the Clubhouse tab (`AnnexNav.project`) and the Projects tab
    /// (`ProjectNavItem`) must carry the same project + instance so they land in
    /// the same `ProjectExplorerView` with identical header inputs.
    @Test func bothNavPayloadsCarrySameProjectAndInstance() {
        let project = Project(id: "p1", name: "demo", path: "/demo", color: nil,
                              icon: nil, displayName: nil, orchestrator: "cc")
        let instanceId = ServerInstanceID(value: "inst-1")

        let clubhouseNav = AnnexNav.project(project, instanceId)
        let projectsNav = ProjectNavItem(project: project, instanceId: instanceId)

        guard case let .project(navProject, navInstanceId) = clubhouseNav else {
            Issue.record("Expected AnnexNav.project")
            return
        }
        #expect(navProject.id == projectsNav.project.id)
        #expect(navInstanceId == projectsNav.instanceId)
        #expect(navProject.orchestrator == projectsNav.project.orchestrator)
    }
}
