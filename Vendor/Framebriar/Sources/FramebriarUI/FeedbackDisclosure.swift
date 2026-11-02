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
            return "Connecting also shares performance and diagnostic data with the developer: event names, counts, timings and error classes, designed not to include prompts, agent content, file paths or account details. Clearing enrollment stops it immediately. Feedback is shared only when you send it. Each report can include recent diagnostics, which you can switch off before sending. Review images for private information before sending."
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
    public static let diagnosticsToggle = "Include recent diagnostics"
    public static let enrollmentChangedNotice = "Your enrollment changed while this was open, so nothing was saved or sent. Your note and image are still here, and diagnostics were captured again for the new enrollment. Check what's included, then tap Send."

    /// The one-line summary, built from the same values that go on the wire.
    public static func summary(hasNote: Bool, hasScreenshot: Bool, diagnostics: FeedbackDiagnostics, hasIncident: Bool) -> String {
        var items: [String] = []
        if hasNote { items.append("note") }
        if hasScreenshot { items.append("screenshot") }
        switch diagnostics.state {
        case .attached: items.append("recent diagnostics (\(diagnostics.entries.count) \(diagnostics.entries.count == 1 ? "event" : "events"))")
        case .none: items.append("no diagnostics recorded")
        case .unavailable: items.append("diagnostics unavailable")
        case .left_out: items.append("diagnostics left out")
        }
        if hasIncident { items.append("incident references") }
        return "Included: " + items.joined(separator: " · ")
    }

    public static let alwaysIncluded = "Every report includes your note, any image shown here, the app's identifier and build, iOS, touch input, the time, and random report and session IDs."
    public static let diagnosticsMeaning = "Recent diagnostics are this app's event names, levels, times, counts, timings, error categories and random connection and trace IDs, recorded before this form opened. They are short fixed-format labels and numbers, not free text, and are designed not to include your messages or file paths. Turning the switch off also removes incident references, which are random IDs that link this report to other diagnostics."

    /// What the app's own telemetry does around this report, which the switch only partly controls.
    public static func telemetryNote(enabled: Bool, excerptOnly: Bool, includeDiagnostics: Bool) -> String? {
        guard enabled else { return nil }
        if includeDiagnostics { return "A copy of the last five minutes of these events not yet delivered also goes to the developer's telemetry, labeled with this report's ID." }
        return excerptOnly ? "Only a marker with this report's ID goes to the developer's telemetry."
                           : "A marker with this report's ID goes to the developer's telemetry. Turning this off doesn't stop the regular telemetry you agreed to when enrolling."
    }

    // MARK: Why Send is unavailable

    public static func sendBlocked(_ block: FeedbackSendBlock) -> String {
        switch block {
        case .checkingAccess: "Checking feedback access…"
        case .notEnrolled: "Redeem a feedback invitation to send reports."
        case .empty: "Add a note or a screenshot to send."
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
        case .needsAttention(.storageUnavailable): "Not saved: local storage is unavailable. Your draft is still here."
        case .needsAttention(.invalidReport): "Not saved: use at most 2,000 characters and an image up to 8 MiB. Your draft is still here."
        case .needsAttention(.notEnrolled): "Not saved: feedback access is required. Your draft is still here."
        case .needsAttention(.busy): "Not saved: another feedback action is in progress. Your draft is still here, so try Send again."
        }
    }
}

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

/// One composer session. Diagnostics and incident references are captured once, when it opens;
/// the switch only chooses whether the frozen capture goes out.
public struct FeedbackDraft: Sendable {
    public let id: UUID
    public let openedAt: Date
    public let capturedDiagnostics: FeedbackDiagnostics
    public let incident: FeedbackIncident?
    /// The enrollment this was opened under, beside the report and never in its bytes. Saving under any
    /// other enrollment fails with `enrollmentChanged`, and this draft can never send after that.
    public let enrollmentRef: String?

    public func diagnostics(included: Bool) -> FeedbackDiagnostics {
        included ? capturedDiagnostics : .leftOut(at: openedAt)
    }
    public func summary(notes: String, hasScreenshot: Bool, includeDiagnostics: Bool) -> String {
        FeedbackDisclosure.summary(hasNote: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasScreenshot: hasScreenshot,
                                   diagnostics: diagnostics(included: includeDiagnostics), hasIncident: includeDiagnostics && incident != nil)
    }
    /// The same report for the same inputs: a save retried after a failure keeps its ID and time.
    public func report(configuration: Configuration, notes: String, screenshotPNG: Data?, includeDiagnostics: Bool) throws -> ReviewedFeedback {
        try ReviewedFeedback(configuration: configuration, notes: notes, reviewedScreenshotPNG: screenshotPNG, id: id, capturedAt: openedAt,
                             incident: includeDiagnostics ? incident : nil, diagnostics: diagnostics(included: includeDiagnostics))
    }
}
