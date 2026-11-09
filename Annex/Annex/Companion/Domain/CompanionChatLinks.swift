import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// One entry of a desktop folder listing (`chatLinks` v1). Symlinks are listed as themselves, not followed.
struct CompanionFolderEntry: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case file, directory, symlink, other }
    var name: String
    var kind: Kind
    /// Files only.
    var size: Int?
    var id: String { name }
    /// Files preview, folders drill in, and the desktop says where a symlink goes. Anything else stays a row.
    var opens: Bool { kind != .other }
}

/// A desktop folder, sorted by name and capped by the desktop at `chatLinks.maxEntries`.
struct CompanionFolderListing: Hashable, Sendable {
    static let maximumEntries = 500
    /// The desktop's real path, in the host's form.
    var path: String
    var name: String
    var entries: [CompanionFolderEntry]
    /// The folder has more entries than the desktop listed.
    var truncated: Bool
    /// A Windows desktop, whose paths use `\\`.
    var windows = false

    /// The desktop path of an entry: this folder's path plus the name, with the host's separator.
    func path(of entry: CompanionFolderEntry) -> String {
        let separator: Character = windows ? "\\" : "/"
        let base = path.last == separator || (windows && path.last == "/") ? path : path + String(separator)
        return base + entry.name
    }
}

/// What the desktop's chat-link route says a link names.
enum CompanionLinkTarget: Equatable, Sendable {
    /// Read through `/content?path=` with `path`. `kind` is a preview kind.
    case file(path: String, name: String, kind: String, size: Int?)
    case directory(CompanionFolderListing)
    case missing
    /// A network or device path, unreadable, or neither a file nor a folder.
    case notAllowed

    /// Decodes a 200 answer. Anything the phone can't read is malformed rather than guessed at.
    init(json: AnnexJSON, windows: Bool = false) throws {
        guard json["version"]?.integer == 1, let type = json["type"]?.string else { throw AnnexTransportError.malformedResponse }
        switch type {
        case "missing": self = .missing
        case "not_allowed": self = .notAllowed
        case "file":
            guard let path = json["path"]?.string, !path.isEmpty, let name = json["name"]?.string,
                  let kind = json["kind"]?.string else { throw AnnexTransportError.malformedResponse }
            self = .file(path: path, name: name, kind: kind, size: json["size"]?.integer.map(Int.init))
        case "directory":
            guard let path = json["path"]?.string, !path.isEmpty, let name = json["name"]?.string,
                  case .array(let raw)? = json["entries"] else { throw AnnexTransportError.malformedResponse }
            // A name is one path segment; one that isn't can't be joined back onto the folder, so it isn't listed.
            let entries = raw.prefix(CompanionFolderListing.maximumEntries).compactMap { entry -> CompanionFolderEntry? in
                guard let name = entry["name"]?.string, !name.isEmpty, name != ".", name != "..",
                      !name.contains(where: { "/\\\0".contains($0) }) else { return nil }
                let kind = entry["kind"]?.string.flatMap(CompanionFolderEntry.Kind.init(rawValue:)) ?? .other
                return .init(name: name, kind: kind, size: kind == .file ? entry["size"]?.integer.map(Int.init) : nil)
            }
            self = .directory(.init(path: path, name: name, entries: entries,
                                    truncated: json["truncated"].boolValue || raw.count > CompanionFolderListing.maximumEntries, windows: windows))
        default: throw AnnexTransportError.malformedResponse
        }
    }
}

extension CompanionContentReference {
    /// The desktop resolves a link as it would one in its own chat: spellings, `#heading`, symlinks and folders (`chatLinks` v1).
    /// A file is then read through `/content` at the desktop's real path; a folder comes back as its listing.
    @MainActor static func open(link href: String, hostName: String, resolve: (String) async throws -> CompanionLinkTarget,
                                load: (Self) async throws -> CompanionContent) async throws -> CompanionContent {
        switch try await resolve(href) {
        case .file(let path, _, _, _): return try await load(.file(path))
        case .directory(let listing): return .init(kind: "folder", name: listing.name, folder: listing)
        case .missing: throw CompanionLinkError.missing(hostName: hostName)
        case .notAllowed: throw CompanionLinkError.notAllowed
        }
    }
    static let linksNeedUpdate = "Update Clubhouse on your desktop to open links from your phone."
}

/// The route's own answers for a link that doesn't open: named, without a retry that can't help.
enum CompanionLinkError: Error, LocalizedError, Equatable {
    case missing(hostName: String)
    case notAllowed
    var errorDescription: String? {
        switch self {
        case .missing(let hostName): "Not found on \(hostName)"
        case .notAllowed: "Not shared with the phone"
        }
    }
}
