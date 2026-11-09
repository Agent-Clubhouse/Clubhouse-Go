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

    /// Normalize newline conventions for display and prefer whole-line boundaries.
    /// Oversized lines split at Unicode scalar boundaries so every Text stays bounded,
    /// including pathological grapheme clusters. The source event is never changed.
    static func lineChunks(_ text: String, targetSize: Int = 16_384) throws -> [String] {
        let limit = min(16_384, max(4, targetSize))
        var chunks: [String] = [], current = String()
        var hasLine = false
        var currentBytes = 0
        func flush() {
            chunks.append(current); current = ""; currentBytes = 0; hasLine = false
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            let lineBytes = line.utf8.count
            if lineBytes <= limit {
                if hasLine && currentBytes + lineBytes + 1 > limit { flush() }
                if hasLine { current += "\n"; currentBytes += 1 }
                current += line; currentBytes += lineBytes
            } else {
                if hasLine { flush() }
                for scalar in line.unicodeScalars {
                    let bytes = scalar.utf8.count
                    if currentBytes + bytes > limit { flush() }
                    if currentBytes == 0 { try Task.checkCancellation() }
                    current.unicodeScalars.append(scalar); currentBytes += bytes
                }
            }
            hasLine = true
        }
        chunks.append(current)
        return chunks
    }
}
