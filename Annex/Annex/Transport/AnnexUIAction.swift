import Foundation

/// Content-free user intent. These values are a stable telemetry vocabulary, never accessibility IDs,
/// screen titles, target IDs, provider/model names, or user-entered text.
nonisolated public struct AnnexUIAction: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, CaseIterable, Sendable {
        case home, dispatcher, needsYou, agents, search, project, conversation
        case agentDetails, agentSettings, newAgent, workspaceTools, projectInfo, wakeAgent, review, archive, changes
        case settings, desktopSettings, desktopUpdate, dispatcherSettings, providerSettings, planLimits, helperPresets
        case feedback, feedbackPrompt, feedbackEnrollment, feedbackDiagnostics, connectionDiagnostics, diagnosticsExport, telemetryDestination
        case welcome, demo, pairing, providerSignIn, terminal, content, markdownFile
    }

    public enum Control: String, Codable, CaseIterable, Sendable {
        case homeTab, dispatcherTab, needsYouTab, agentsTab
        case openSearch, openSettings, openAgent, openProject, openAgentDetails, openAgentSettings, openContext
        case newAgent, wakeAgent, wakeAndResume, startNewSession, sleepAgent, refreshSleepState
        case openTerminal, openAgentTerminal, openProjectTerminal, restartTerminal, copyTerminalOutput, toggleTerminalKeyboard
        case terminalEscape, terminalTab, terminalControl, terminalUp, terminalDown, terminalLeft, terminalRight
        case terminalInterrupt, terminalSymbol, pasteTerminalInput, openDemo
        case openMore, close, back, cancel, done, save, confirm, submit
        case send, steer, queue, interrupt, removeQueued
        case approve, decline, allowOnce, allowAlways, deny, answerQuestion, skipQuestion
        case openAttachments, addImage, clearImages, openPlanLimits, openHelperPresets
        case openFeedback, openFeedbackEnrollment, openFeedbackDiagnostics, openConnectionDiagnostics, openDesktopSettings
        case pinProject, unpinProject, markProjectInactive, markProjectActive, openProjectInfo, dismissFinished, clearFinished
        case retry, reconnect, refresh, copy, share, forgetDesktop, revokeSession, checkForUpdates, restartForUpdate, cancelUpdate
        case checkProviderResult, saveProvider
        case selectDesktop, selectProject, selectProvider, selectModel, selectRuntime, selectAccess, selectColor
        case selectContextWindow, resetContextWindow, selectAutoSleep, selectHelperPreset, selectBehavior
        case selectEffort, toggleModelSelection, renameDispatcher, selectPersonality, savePersonality, revertPersonality
        case clearDispatcherChat, forgetDispatcherMemory
        case resetAllHelperPresets, resetProviderPresets, resetHelperPreset, toggleHelperFallback
        case toggleDispatcher, renameAgent, selectEmoji, openWorkspaceTools, selectMCP, toggleWorktree, toggleHelpers
        case expandHelpers, expandQuietAgents, expandSleepingAgents, expandFinishedAgents
        case connectDesktop, scanPairingCode, enterPairingAddress, trustDesktop, pairDesktop
        case inspectDesktop, toggleRememberDesktop, renamePhone
        case enrollFeedback, clearFeedback, sendHeldFeedback, clearHeldFeedback, prepareDiagnosticsReport
        case toggleShakeFeedback, toggleShakeScreenshot, toggleScreenshotFeedback
        case selectDiagnosticCapture, openDiagnosticExport, clearDiagnostics, saveTelemetryDestination, toggleCollectorExport, removeTelemetryDestination
        case openArchive, openChanges, openContent, openLink, openRouting, openProviderSignIn, signOutProvider
    }

    public let screen: Screen
    public let control: Control

    public init(screen: Screen, control: Control) {
        self.screen = screen
        self.control = control
    }
}
