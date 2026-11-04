import Foundation
import Framebriar

/// Every statement the composer makes about what a report contains and what happened to it.
/// This is the one place to review or change that wording. Each string must stay true of the report
/// `FeedbackDraft.report(...)` actually builds; `DisclosureTests` checks the summary against the wire bytes.
public enum FeedbackDisclosure {
    // MARK: Enrollment

    /// `sendsDiagnostics`: this app can attach recent diagnostics to a report, from a provider or `Telemetry`.
    public static func enrollment(hasTelemetry: Bool, sendsDiagnostics: Bool) -> String {
        if hasTelemetry {
            // Required disclosure (docs/telemetry.md): enrollment enables telemetry.
            let reports = sendsDiagnostics ? "Each report can include recent diagnostics, which you can switch off before sending. " : ""
            return "Connecting also shares performance and diagnostic data with the developer: event names, counts, timings and error classes, designed not to include prompts, agent content, file paths or account details. Clearing enrollment stops it immediately. Feedback is shared only when you send it. \(reports)Review images for private information before sending."
        }
        if sendsDiagnostics {
            return "Only feedback you choose to send is shared. Each report can include recent app diagnostics (event names, counts, timings and error categories), which you can switch off before sending. They are designed not to include prompts or agent content. Optional trace references can link a report to separately configured tracing. Review images for private information before sending."
        }
        return "Only feedback you choose to send is shared. No prompts, agent content or logs are collected. Optional trace references can link a report to separately configured tracing. Review images for private information before sending."
    }

    // MARK: Reports saved under another enrollment

    public static func heldSummary(count: Int) -> String {
        "\(count) \(count == 1 ? "report was" : "reports were") saved under a previous enrollment and \(count == 1 ? "hasn't" : "haven't") been sent. \(count == 1 ? "It stays" : "They stay") on this device until you choose."
    }
    public static func releaseConfirmation(count: Int) -> String {
        "Send \(count) \(count == 1 ? "report" : "reports") saved under a previous enrollment with this one?"
    }
    public static func releaseResult(_ result: HeldReleaseResult) -> String {
        switch result.code {
        case "stale-release": return "This changed before you confirmed, so nothing was sent. Check the reports below and try again."
        case "not-enrolled": return "Redeem an invitation first. The reports stay on this device."
        default:
            if result.failed > 0 { return "\(result.released) will send with this enrollment. \(result.failed) couldn't be moved and \(result.failed == 1 ? "stays" : "stay") saved here." }
            return "\(result.released) will send with this enrollment. They aren't confirmed sent yet."
        }
    }
    public static func clearHeldResult(_ result: HeldClearResult) -> String {
        result.failed > 0 ? "\(result.cleared) cleared from this device. \(result.failed) couldn't be cleared." : "\(result.cleared) cleared from this device. They weren't sent."
    }

    // MARK: Before sending

    public static let notesPrompt = "Describe the issue without prompts, agent responses, credentials, or other private information. A screenshot is optional."
    public static let capturedScreenNote = "This is the screen you were on. It stays on this device unless you tap Send. Check it for private information, then keep, remove or replace it."
    /// True in both modes: under `.on` the logs are in the report, and under `.off` they go to telemetry labeled with its ID.
    public static let diagnosticsToggle = "Send recent logs with this report"
    public static let screenshotToggle = "Include screenshot"
    public static let screenshotLeftOutNote = "This image won't be sent. It stays here, with any edits, until you close this form, so you can include it again."
    /// Why a composer that expected a capture has no image. It still opens, and a note can still be sent.
    public static func screenshotUnavailable(_ reason: FeedbackScreenshotUnavailable) -> String {
        switch reason {
        case .secureField: "No screenshot was taken, because a secure text field was active. You can still send a note or add an image."
        case .failed: "The screen couldn't be captured, so no screenshot is attached. You can still send a note or add an image."
        }
    }
    public static let imageToolsHint = "Tap the image to zoom in, draw on it or cover part of it."
    /// While edits are still reversible, before any Send.
    public static let editedImageNote = "You edited this image, and this flattened copy is the one that will be sent. Tap the image to change or clear your edits, until you tap Send. After that they're permanent. Only areas you covered with Redact are hidden, so check the rest for private information."
    /// After a Send that didn't complete, when the image holds edits from before it.
    public static let editedImageFinalNote = "Edits you made before tapping Send are now part of this image and can't be undone, so anything you covered stays covered. To start over, replace or remove it. You can add marks, and clear those, until you tap Send again. Only areas you covered with Redact are hidden, so check the rest for private information."
    public static func clearEditsConfirmation(editsAreFinal: Bool) -> String {
        editsAreFinal ? "Clear the marks you added since tapping Send? Edits from before that are part of the image and stay, so anything you covered then stays covered."
                      : "Clear all edits? The original image comes back, including anything you covered, and that's what will be sent."
    }
    public static let editorMoveHint = "Pinch, drag or double-tap to look closely. To hide something, choose Redact."
    public static let editorPenHint = "Drawing only marks the image, and what's under a line may still show. To hide something, choose Redact."
    public static let editorRedactHint = "Drag over what to hide. That area becomes solid black in the image you send. It only covers what you cover, so check the rest."
    public static let editorCannotOpen = "This image couldn't be opened for editing. Your screenshot hasn't changed."
    public static let editorCannotFinish = "These edits couldn't be applied. Your screenshot hasn't changed. Try Done again, or Cancel."
    /// After `FramebriarError.conflict`: this device already holds different contents under this report's ID.
    public static let saveConflictNotice = "A saved copy of this report with different contents is already on this device and may also be delivered. Your note and image are still here. Tap Send to send them as a separate report."
    public static let enrollmentChangedNotice = "Your enrollment changed while this was open, so nothing was saved or sent. Your note and image are still here. Check what's included, then tap Send."

    /// The one-line summary, built from the same values that go on the wire.
    /// Nil `diagnostics` means the report has no such field, so the line doesn't mention them.
    /// `screenshotLeftOut`: an image is attached and unchecked, so the report has no media.
    public static func summary(hasNote: Bool, hasScreenshot: Bool, diagnostics: FeedbackDiagnostics?, hasIncident: Bool, screenshotLeftOut: Bool = false) -> String {
        var items: [String] = []
        if hasNote { items.append("note") }
        if hasScreenshot { items.append("screenshot") } else if screenshotLeftOut { items.append("screenshot left out") }
        switch diagnostics?.state {
        case .attached: items.append("recent diagnostics (\(diagnostics?.entries.count ?? 0) \(diagnostics?.entries.count == 1 ? "event" : "events"))")
        case .none?: items.append("no diagnostics recorded")
        case .unavailable: items.append("diagnostics unavailable")
        case .left_out: items.append("diagnostics left out")
        case nil: break
        }
        if hasIncident { items.append("incident references") }
        return items.isEmpty ? "Included: nothing yet" : "Included: " + items.joined(separator: " · ")
    }

    public static let alwaysIncluded = "Every report includes your note, any image shown here, the app's identifier and build, iOS, touch input, the time, and random report and session IDs."
    public static let diagnosticsMeaning = "Recent logs, listed above as diagnostics, are this app's event names, levels, times, counts, timings, error categories and random connection and trace IDs, recorded before this form opened. They are short fixed-format labels and numbers, not free text, and are designed not to include your messages or file paths. Turning the switch off also removes incident references, which are random IDs that link this report to other diagnostics."

    /// `diagnosticsMeaning` for a report with no `diagnostics` field, where the switch governs the telemetry excerpt.
    public static let telemetryDiagnosticsMeaning = "Recent logs are this app's telemetry events: event names, counts, timings and error classes, designed not to include your messages or file paths. They aren't part of this report. Turning the switch off also removes any incident references, which are random IDs that link this report to other diagnostics."

    /// What the app's own telemetry sends without asking, then what this report adds to it. The switch only
    /// controls the second. `includeDiagnostics` means an excerpt goes out, which never happens for a report
    /// carrying its own.
    public static func telemetryNote(enabled: Bool, excerptOnly: Bool, includeDiagnostics: Bool) -> String? {
        guard enabled else { return nil }
        let automatic = excerptOnly ? "Nothing is sent automatically while you're enrolled. Logs stay on this device unless they go with a report you send."
                                    : "While you're enrolled, this app automatically sends the developer performance and diagnostic data: event names, counts, timings and error classes. That happens whether or not you send a report, and this switch doesn't change it. Clearing enrollment stops it."
        let added = includeDiagnostics ? "This report also sends a copy of the last five minutes of these events not yet delivered, labeled with its ID."
                                       : "This report adds only a marker with its ID."
        return automatic + " " + added
    }

    // MARK: Why Send is unavailable

    public static func sendBlocked(_ block: FeedbackSendBlock) -> String {
        switch block {
        case .checkingAccess: "Checking feedback access…"
        case .notEnrolled: "Redeem a feedback invitation to send reports."
        case .empty: "Add a note or include a screenshot to send."
        case .notesTooLong: "Use at most 2,000 characters."
        case .queueFull: "\(ClientStatus.maxItems) reports are already waiting on this device, which may include reports from a previous enrollment. Send or clear them first."
        case .preparingImage: "Preparing the image…"
        case .saving: "Saving…"
        }
    }

    // MARK: After Send

    public static let sendingTitle = "Saved, sending…"
    public static let sendingDetail = "Your report is saved on this device. You can close this. If it doesn't finish, it will send when the app is open and online."

    public static func title(_ outcome: FeedbackDeliveryOutcome) -> String {
        switch outcome {
        case .sent: "Sent"
        case .saved(.offline): "Saved, will send when online"
        case .saved: "Saved, will send later"
        case .needsAttention: "Needs attention"
        }
    }
    public static func detail(_ outcome: FeedbackDeliveryOutcome) -> String {
        switch outcome {
        case .sent: "The service confirmed it received your report."
        case .saved(.offline): "Saved. It will send when the app is open and online."
        case .saved(.paused): "Saved. It will send when the app is open and online."
        case .saved(.serviceBusy): "The service couldn't take your report just now. Saved. It will retry while the app is open and online."
        case .saved(.waitingForService): "Saved. It will send when the app is open and online, once the service accepts its incident references."
        case .needsAttention(.accessRequired): "Feedback access needs a new invitation. Your report stays on this device. After you reconnect, you'll choose whether to send it with the new enrollment."
        case .needsAttention(.heldForEnrollment): "Your report was saved under a previous enrollment and hasn't been sent. It stays on this device until you send or clear it from the enrollment screen."
        case .needsAttention(.enrollmentChanged): "Not saved: " + enrollmentChangedNotice
        case .needsAttention(.rejected): "The service didn't accept this report. It stays on this device until you clear it, and it won't be retried."
        case .needsAttention(.removed): "This report was cleared from this device before it was sent."
        case .needsAttention(.deliveryUnconfirmed): "Your report is saved on this device, but local storage failed while recording its delivery. It may send again while the app is open; the service recognizes a repeat."
        case .needsAttention(.storageFull): "Not saved: local feedback storage is full. Your draft is still here."
        case .needsAttention(.storageUnavailable): "Couldn't confirm this saved, because local storage reported an error. Your draft is still here, so you can try Send again. Unless a later Send succeeds, a copy may still be on this device and could send the next time the app opens."
        case .needsAttention(.invalidReport): "Not saved: use at most 2,000 characters and an image up to 8 MiB. Your draft is still here."
        case .needsAttention(.notEnrolled): "Not saved: feedback access is required. Your draft is still here."
        case .needsAttention(.busy): "Not saved: another feedback action is in progress. Your draft is still here, so try Send again."
        }
    }
}

/// Why there's no image, for a host that does its own capture. `FeedbackShakeEvent` carries this for a shake.
public enum FeedbackScreenshotUnavailable: Sendable, Equatable { case secureField, failed }

public enum FeedbackSendBlock: Sendable, Equatable {
    case checkingAccess, notEnrolled, empty, notesTooLong, queueFull, preparingImage, saving

    /// Nil when Send is available.
    public static func evaluate(status: ClientStatus?, notes: String, hasScreenshot: Bool, preparingImage: Bool, saving: Bool) -> FeedbackSendBlock? {
        if saving { return .saving }
        if preparingImage { return .preparingImage }
        guard let status else { return .checkingAccess }
        guard status.canSubmit else { return .notEnrolled }
        if status.queued >= ClientStatus.maxItems { return .queueFull }
        if notes.utf16.count > 2000 { return .notesTooLong }
        if !hasScreenshot, notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return nil
    }
}

/// Whether reports carry their own `diagnostics` field. Only `.on` captures anything for it.
public enum FeedbackReportDiagnostics: Sendable { case off, on }

/// One composer session. Diagnostics and incident references are captured once, when it opens;
/// the switch only chooses whether the frozen capture goes out.
public struct FeedbackDraft: Sendable {
    public let id: UUID
    public let openedAt: Date
    /// Frozen at open, whatever the model's mode is later.
    public let reportDiagnosticsMode: FeedbackReportDiagnostics
    /// Whether the composer shows the switch. `.off` has something to switch only when telemetry was enabled
    /// at open. A composer that hides it passes `includeDiagnostics: false`, so nothing goes out unswitchable.
    public let offersDiagnosticsSwitch: Bool
    /// Nil under `.off`, where nothing is captured.
    public let capturedDiagnostics: FeedbackDiagnostics?
    public let incident: FeedbackIncident?
    /// The enrollment this was opened under, beside the report and never in its bytes. Saving under any
    /// other enrollment fails with `enrollmentChanged`, and this draft can never send after that.
    public let enrollmentRef: String?

    /// What goes in the report's `diagnostics` field. Nil under `.off`, which omits the field.
    public func diagnostics(included: Bool) -> FeedbackDiagnostics? {
        guard reportDiagnosticsMode == .on else { return nil }
        return included ? capturedDiagnostics : .leftOut(at: openedAt)
    }
    /// What the switch means for this draft. Nil when it has no switch.
    public var diagnosticsMeaning: String? {
        guard offersDiagnosticsSwitch else { return nil }
        return reportDiagnosticsMode == .on ? FeedbackDisclosure.diagnosticsMeaning : FeedbackDisclosure.telemetryDiagnosticsMeaning
    }
    /// The telemetry note for this draft. Under `.on` the report carries the events, so telemetry gets only the marker.
    public func telemetryNote(telemetry: Telemetry?, includeDiagnostics: Bool) -> String? {
        FeedbackDisclosure.telemetryNote(enabled: telemetry?.isEnabled == true, excerptOnly: telemetry?.mode == .excerptOnly,
                                         includeDiagnostics: reportDiagnosticsMode == .off && includeDiagnostics)
    }
    /// - Parameter screenshotLeftOut: an image is attached and unchecked. `hasScreenshot` is false then.
    public func summary(notes: String, hasScreenshot: Bool, includeDiagnostics: Bool, screenshotLeftOut: Bool = false) -> String {
        FeedbackDisclosure.summary(hasNote: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasScreenshot: hasScreenshot,
                                   diagnostics: diagnostics(included: includeDiagnostics), hasIncident: includeDiagnostics && incident != nil, screenshotLeftOut: screenshotLeftOut)
    }
    /// The same frozen captures under a new report ID.
    func withNewID() -> FeedbackDraft {
        FeedbackDraft(id: UUID(), openedAt: openedAt, reportDiagnosticsMode: reportDiagnosticsMode, offersDiagnosticsSwitch: offersDiagnosticsSwitch,
                      capturedDiagnostics: capturedDiagnostics, incident: incident, enrollmentRef: enrollmentRef)
    }
    /// The same report for the same inputs: a save retried after a failure keeps its ID and time.
    public func report(configuration: Configuration, notes: String, screenshotPNG: Data?, includeDiagnostics: Bool) throws -> ReviewedFeedback {
        try ReviewedFeedback(configuration: configuration, notes: notes, reviewedScreenshotPNG: screenshotPNG, id: id, capturedAt: openedAt,
                             incident: includeDiagnostics ? incident : nil, diagnostics: diagnostics(included: includeDiagnostics))
    }
}
