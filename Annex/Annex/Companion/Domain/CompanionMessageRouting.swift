import Foundation
import Observation

/// Desktop message-routing.ts. Compute at the message boundary, never from a SwiftUI body.
enum CompanionMessageDisplay: Sendable, Equatable {
    case you(String)
    case others([CompanionRoutedMessagePart])
}

enum CompanionMessageRouting {
    private static let sectionHeader = pattern(#"^(\d+) updates, oldest first:\n\n"#)
    private static let clubhouse = pattern(#"^\[Clubhouse\] "#)
    private static let helper = pattern(#"^\[FROM HELPER:([^\]]+?) \(([^)\]]+)\)\] "#)
    private static let question = pattern(#"^\[QUESTION FROM HELPER:([^\]]+?) \(([^)\]]+)\)\] .*? is waiting for your answer\. Answer with answer_helper_question, requestId "[^"]*"\. If the user should decide, call it with escalate: true instead\.\n?"#)
    private static let from = pattern(#"^(?:\[TASK:[^\]]+\] )?\[FROM:([^\]]+)\] "#)
    // ICU $ also accepts a final newline; \z matches JavaScript's actual end-of-input anchor.
    private static let replyFooter = pattern(#"\n\n---\nReply to [^\n]* via tool "[^"\n]*" with task_id="[^"\n]*"\. Prefix your response with TASK_RESULT:\S*\.\z"#)
    private static let missionFooter = pattern(#"\n\n---\nYou are a helper agent started by [^\n]*\. Use the message_parent tool to send [^\n]* your progress, questions and results\.(?:\n\n\[FROM:[^\]]+\] )?"#)
    private static let fileNotice = pattern(#"^File delivered: ([^\n]*) — read this file for content from [^\n]*\.\z"#)
    private static let tap = pattern(#"^Group Project notification — shoulder tap from "([^"\n]*)" in "[^"\n]*"\n([\s\S]*?)\n\n---\nRESPONSE INSTRUCTIONS:\n[\s\S]*\z"#)
    private static let taskMarker = pattern(#"^TASK_(?:RESULT|ACK):[^\s:]+(?::\s*|\s+|\z)"#)

    private static func pattern(_ text: String) -> NSRegularExpression { try! NSRegularExpression(pattern: text) }
    private static func match(_ pattern: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func group(_ result: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        String(text[Range(result.range(at: index), in: text)!])
    }
    private static func replacing(_ pattern: NSRegularExpression, in text: String, with replacement: String) -> String {
        guard let result = match(pattern, text), let range = Range(result.range, in: text) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
    private static func nameFromLabel(_ label: String) -> String {
        guard let at = label.lastIndex(of: "@"), at > label.startIndex else { return label }
        return String(label[..<at])
    }
    static func stripTaskMarker(_ text: String) -> String { replacing(taskMarker, in: text, with: "") }
    static func isLongMessage(_ text: String) -> Bool {
        // Count LF code units: Swift treats CRLF as one Character, but JavaScript splits on its LF.
        text.utf16.count > 800 || text.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 } > 14
    }

    private static func splitCoalesced(_ text: String) -> [String] {
        guard let header = match(sectionHeader, text), let count = Int(group(header, 1, text)) else { return [text] }
        var rest = String(text[Range(header.range, in: text)!.upperBound...])
        var sections: [String] = []
        guard count > 0 else { return sections }
        for index in 1...count {
            let label = "--- \(index) of \(count) ---\n"
            guard rest.hasPrefix(label) else { return [text] }
            rest.removeFirst(label.count)
            if index == count { sections.append(rest) }
            else {
                guard let next = rest.range(of: "\n\n--- \(index + 1) of \(count) ---\n") else { return [text] }
                sections.append(String(rest[..<next.lowerBound]))
                rest = String(rest[rest.index(next.lowerBound, offsetBy: 2)...])
            }
        }
        return sections
    }
    private static func parseSection(_ text: String) -> CompanionRoutedMessagePart {
        if match(clubhouse, text) != nil { return .init(fromClubhouse: true, text: replacing(clubhouse, in: text, with: "")) }
        if let helper = match(helper, text) ?? match(question, text) {
            return .init(sender: .init(agentID: group(helper, 2, text), name: group(helper, 1, text)),
                         text: String(text[Range(helper.range, in: text)!.upperBound...]))
        }
        if let from = match(from, text) {
            var body = String(text[Range(from.range, in: text)!.upperBound...])
            body = replacing(replyFooter, in: body, with: "")
            if let footer = match(missionFooter, body) {
                body = replacing(missionFooter, in: body, with: group(footer, 0, body).hasSuffix("] ") ? "\n\n" : "")
            }
            if let file = match(fileNotice, body) { body = "File delivered: \(group(file, 1, body))" }
            return .init(sender: .init(name: nameFromLabel(group(from, 1, text))), text: body)
        }
        return .init(text: text)
    }
    static func parseRoutedText(_ text: String) -> [CompanionRoutedMessagePart] { splitCoalesced(text).map(parseSection) }
    static func display(source: String?, text: String, routed: [CompanionRoutedMessagePart] = []) -> CompanionMessageDisplay {
        if source == nil || source == "user" || source == "annex" { return .you(text) }
        if !routed.isEmpty { return .others(routed.map(shown)) }
        if source == "system" { return .others([.init(fromClubhouse: true, text: text)]) }
        if source == "group_project" { return .others([.init(text: text)]) }
        if source == "shoulder_tap" {
            guard let tap = match(tap, text) else { return .others([.init(text: text)]) }
            let name = group(tap, 1, text), body = group(tap, 2, text)
            return name == "user" ? .you(body) : .others([.init(sender: .init(name: nameFromLabel(name)), text: body)])
        }
        let parts = parseRoutedText(text).map(shown)
        if source == "mission" && !parts.contains(where: { $0.sender != nil || $0.fromClubhouse }) { return .you(text) }
        return .others(parts)
    }
    private static func shown(_ part: CompanionRoutedMessagePart) -> CompanionRoutedMessagePart {
        var part = part; part.text = part.displayText; return part
    }
}

/// A value lookup passed by transcript parents: rows never observe the host catalog or the whole store.
struct CompanionSenderResolver: Sendable {
    private var byID: [String: CompanionAgent] = [:]
    private var uniqueNames: [String: CompanionAgent] = [:]
    init(agents: [CompanionAgent]) {
        for agent in agents { byID[agent.id.agentID] = agent }
        for (name, matches) in Dictionary(grouping: agents, by: \.name) where matches.count == 1 { uniqueNames[name] = matches[0] }
    }
    func resolve(_ sender: CompanionRoutedMessagePart.Sender?) -> CompanionAgent? {
        guard let sender else { return nil }
        if let id = sender.agentID, !id.isEmpty { return byID[id] }
        return uniqueNames[sender.name]
    }
    func avatarAgent(for sender: CompanionRoutedMessagePart.Sender?) -> CompanionAgent? {
        guard let sender else { return nil }
        return resolve(sender) ?? .init(id: .init(hostID: "", projectID: "", agentID: sender.agentID ?? sender.name),
                                      name: sender.name, subtitle: "", status: .idle)
    }
}

/// Owned above the transcript and outside snapshots. Only the part being toggled observes its open value.
@MainActor final class CompanionTranscriptExpansion {
    private var parts: [String: CompanionPartExpansion] = [:]
    func part(messageID: String, index: Int) -> CompanionPartExpansion {
        let key = "\(messageID):sent:\(index)"
        if let part = parts[key] { return part }
        let part = CompanionPartExpansion(); parts[key] = part; return part
    }
}

@MainActor @Observable final class CompanionPartExpansion {
    var open: Bool?
    func isOpen(for text: String) -> Bool { open ?? !CompanionMessageRouting.isLongMessage(text) }
}
