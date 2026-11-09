import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Presentation only: the authenticated event and its digest remain untouched.
nonisolated struct CompanionFullEventSection: Sendable, Equatable {
    let heading: String
    let chunks: [String]
}

nonisolated enum CompanionFullEventDocument {
    static func sections(_ event: AnnexJSON) throws -> [CompanionFullEventSection] {
        var result: [CompanionFullEventSection] = []
        func walk(_ value: AnnexJSON, path: String) throws {
            try Task.checkCancellation()
            switch value {
            case .object(let fields) where !fields.isEmpty:
                for key in fields.keys.sorted() {
                    try walk(fields[key]!, path: path.isEmpty ? key : "\(path).\(key)")
                }
            case .array(let values) where !values.isEmpty:
                for (index, child) in values.enumerated() { try walk(child, path: "\(path)[\(index)]") }
            default:
                let text: String
                if case .string(let string) = value { text = string }
                else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    text = String(decoding: try encoder.encode(value), as: UTF8.self)
                }
                result.append(.init(heading: visibleFormatting(path.isEmpty ? "Event" : path), chunks: try lineChunks(visibleFormatting(text))))
            }
        }
        try walk(event, path: "")
        return result
    }

    static func visibleFormatting(_ text: String) -> String {
        var result = String(); result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .format {
                result += String(format: "⟨U+%04X⟩", scalar.value)
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    /// A single long line stays whole. Every chunk boundary replaces an existing newline,
    /// so the view never inserts a gap halfway through a command or file line.
    static func lineChunks(_ text: String, targetSize: Int = 16_384) throws -> [String] {
        var chunks: [String] = [], current = String()
        var hasLine = false
        var currentBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            let lineBytes = line.utf8.count
            if hasLine && currentBytes + lineBytes + 1 > targetSize {
                chunks.append(current); current = String(line); currentBytes = lineBytes
            } else {
                if hasLine { current += "\n"; currentBytes += 1 }
                current += line; currentBytes += lineBytes
            }
            hasLine = true
        }
        chunks.append(current)
        return chunks
    }
}
