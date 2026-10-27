import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Status parity with the desktop's `agentDot` (`src/renderer/features/agents/agent-status.tsx`) and
/// Needs you rule (`src/renderer/chrome/sidebar/treeModel.ts`).
struct CompanionStatusTests {
    private func detailed(_ state: String, message: String = "", toolName: String? = nil) -> AnnexJSON {
        var values: [String: AnnexJSON] = ["state": .string(state), "message": .string(message), "timestamp": .integer(1)]
        if let toolName { values["toolName"] = .string(toolName) }
        return .object(values)
    }
    private func dot(_ status: String?, _ detailed: AnnexJSON? = nil) -> CompanionStatusDot {
        CompanionChatProjector.status(status, detailed: detailed).dot
    }

    // Every desktop `AgentDetailedState` for a running agent.
    @Test(arguments: [
        ("idle", "Idle", CompanionAgentStatus.idle),
        ("idle", "Thinking", .working),
        ("working", "Editing App.tsx", .working),
        ("needs_permission", "Needs permission", .approval),
        ("needs_permission", "Has a question", .waiting),
        ("tool_error", "Bash failed", .failed),
    ])
    func runningAgentFollowsDetailedState(state: String, message: String, expected: CompanionAgentStatus) {
        #expect(CompanionChatProjector.status("running", detailed: detailed(state, message: message)) == expected)
    }

    @Test func askUserQuestionPermissionIsAQuestion() {
        let status = CompanionChatProjector.status("running", detailed: detailed("needs_permission", message: "Needs permission", toolName: "AskUserQuestion"))
        #expect(status == .waiting)
    }

    @Test func toolErrorIsAnErrorThatNeedsYou() {
        let status = CompanionChatProjector.status("running", detailed: detailed("tool_error", toolName: "Bash"))
        #expect(status.dot == .error)
        #expect(status.label == "Error")
        #expect(status.needsYou)
        #expect(CompanionAgentFilter.needsYou.matches(status))
        #expect(!CompanionAgentFilter.working.matches(status))
    }

    // Every desktop `AgentStatus`, with no detailed status.
    @Test(arguments: [
        ("running", CompanionStatusDot.working),
        ("sleeping", .sleeping),
        ("waking", .starting),
        ("creating", .starting),
        ("spawning", .starting),
        ("error", .error),
    ])
    func everyDesktopAgentStatus(status: String, expected: CompanionStatusDot) {
        #expect(dot(status) == expected)
    }

    @Test func startingStatesAreNotReady() {
        for status in ["creating", "spawning", "waking"] {
            #expect(CompanionChatProjector.status(status, detailed: detailed("idle", message: "Idle")) == .starting)
            #expect(CompanionChatProjector.status(status, detailed: nil).label == "Starting")
        }
    }

    @Test func errorsWinOverEveryOtherState() {
        #expect(dot("error", detailed("working")) == .error)
        #expect(dot("sleeping", detailed("tool_error")) == .error)
        #expect(dot("waking", detailed("tool_error")) == .error)
    }

    // Every desktop `ChatSessionState`, as `chatDot` shows it.
    @Test(arguments: [
        ("starting", CompanionStatusDot.starting),
        ("idle", .done),
        ("running", .working),
        ("waiting_permission", .needsYou),
        ("waiting_input", .needsYou),
        ("sleeping", .sleeping),
        ("error", .error),
    ])
    func everyChatSessionState(state: String, expected: CompanionStatusDot) {
        #expect(CompanionChatProjector.status(state).dot == expected)
    }

    @Test func cancelledTurnIsDoneNotSleeping() {
        var projector = CompanionChatProjector()
        projector.apply(.object(["sessionId": .string("s"), "seq": .integer(1), "type": .string("turn_started"), "data": .object([:])]))
        projector.apply(.object(["sessionId": .string("s"), "seq": .integer(2), "type": .string("turn_ended"),
                                 "data": .object(["stopReason": .string("cancelled")])]))
        #expect(projector.status.dot == .done)
    }

    @Test func statusWordsAreTheDesktops() {
        #expect(CompanionStatusDot.allCases.map(\.label) == ["Working", "Done", "Needs you", "Error", "Sleeping", "Starting"])
        #expect(CompanionAgentStatus.idle.label == "Done")
        #expect(CompanionAgentStatus.sleeping.label == "Sleeping")
        #expect(CompanionAgentStatus.failed.label == "Error")
        #expect(CompanionAgentStatus.approval.label == "Needs you")
        #expect(CompanionAgentStatus.waiting.label == "Needs you")
        #expect(CompanionStatusDot.allCases.filter(\.isHollow) == [.sleeping, .starting])
    }

    @Test func filtersUseTheDesktopsWords() {
        #expect(CompanionAgentFilter.allCases.map(\.label) == ["All", "Working", "Needs you", "Done", "Sleeping"])
    }

    @Test(arguments: [
        (CompanionAgentStatus.idle, [CompanionAgentFilter.all, .done]),
        (.working, [.all, .working]),
        (.approval, [.all, .needsYou]),
        (.waiting, [.all, .needsYou]),
        (.failed, [.all, .needsYou]),
        (.completed, [.all, .done]),
        (.sleeping, [.all, .sleeping]),
        (.stopped, [.all, .sleeping]),
        (.starting, [.all]),
    ])
    func filterMembership(status: CompanionAgentStatus, filters: [CompanionAgentFilter]) {
        #expect(CompanionAgentFilter.allCases.filter { $0.matches(status) } == filters)
    }
}

struct CompanionStatusPaletteTests {
    private let latte = ["base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85",
                         "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "warning": "#7e5700", "error": "#c4122f",
                         "success": "#347d22", "info": "#04a5e5"]
    private let mocha = ["base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4", "subtext0": "#a6adc8",
                         "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa", "warning": "#f9e2af", "error": "#f38ba8",
                         "success": "#a6e3a1", "info": "#89dceb"]

    private func palettes(_ colors: [String: String]) throws -> [CompanionPalette] {
        let theme = try #require(CompanionDesktopTheme.transported(colors))
        return [CompanionPalette(theme: theme, dark: true), CompanionPalette(theme: theme, dark: false)]
    }

    @Test func desktopInfoColorIsUsedWhenSent() throws {
        let theme = try #require(CompanionDesktopTheme.transported(mocha))
        #expect(theme.info == CompanionRGB(hex: "#89dceb"))
        let palette = CompanionPalette(theme: theme, dark: true)
        #expect(CompanionStatusDot.done.color(in: palette) == palette.info)
    }

    @Test func infoIsDerivedWhenTheDesktopDoesNotSendIt() throws {
        var older = mocha; older["info"] = nil
        let theme = try #require(CompanionDesktopTheme.transported(older))
        #expect(theme.info.blue > theme.info.red && theme.info.blue > theme.info.green)
    }

    @Test func everyDotColorReaches3To1AgainstTheCard() throws {
        var withoutInfo = latte; withoutInfo["info"] = nil
        for colors in [latte, mocha, withoutInfo] {
            for palette in try palettes(colors) {
                for dot in CompanionStatusDot.allCases {
                    #expect(dot.color(in: palette).contrast(with: palette.card) >= 3, "\(dot) on \(palette.card.hex)")
                }
            }
        }
        for palette in [CompanionPalette(theme: .clubhouse, dark: true), CompanionPalette(theme: .clubhouse, dark: false)] {
            #expect(palette.info.contrast(with: palette.card) >= 3)
        }
    }

    @Test func dotColorsAreTheDesktops() throws {
        let palette = try #require(try palettes(mocha).first)
        #expect(CompanionStatusDot.working.color(in: palette) == palette.success)
        #expect(CompanionStatusDot.done.color(in: palette) == palette.info)
        #expect(CompanionStatusDot.starting.color(in: palette) == palette.info)
        #expect(CompanionStatusDot.needsYou.color(in: palette) == palette.warning)
        #expect(CompanionStatusDot.error.color(in: palette) == palette.error)
    }
}
