import SwiftUI

/// A desktop folder from the chat-link route: name, kind and size. Files preview, folders drill in,
/// and a symlink resolves to wherever it goes. Nothing is fetched until an entry is tapped.
struct CompanionFolderList<Destination: View>: View {
    let listing: CompanionFolderListing
    /// The page for an entry's desktop path.
    @ViewBuilder let destination: (String) -> Destination

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if listing.entries.isEmpty {
                Text("This folder is empty.").foregroundStyle(.secondary).padding(.vertical, 12)
                    .accessibilityIdentifier("companion-folder-empty")
            }
            ForEach(listing.entries) { entry in
                if entry.opens {
                    NavigationLink { destination(listing.path(of: entry)) } label: { row(entry, chevron: true) }
                        .buttonStyle(.plain)
                } else {
                    row(entry, chevron: false)
                }
                Divider()
            }
            if listing.truncated {
                Label("More items on the desktop", systemImage: "ellipsis.circle")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                    .accessibilityElement(children: .ignore).accessibilityLabel("More items on the desktop")
                    .accessibilityIdentifier("companion-folder-more")
            }
        }
        .accessibilityIdentifier("companion-folder-list")
    }

    private func row(_ entry: CompanionFolderEntry, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(entry.kind)).foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(2)
                Text(Self.detail(entry)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("companion-folder-entry")
    }

    static func symbol(_ kind: CompanionFolderEntry.Kind) -> String {
        switch kind {
        case .file: "doc"
        case .directory: "folder"
        case .symlink: "link"
        case .other: "questionmark.square.dashed"
        }
    }

    static func detail(_ entry: CompanionFolderEntry) -> String {
        switch entry.kind {
        case .file: entry.size.map { "File · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "File"
        case .directory: "Folder"
        case .symlink: "Link"
        case .other: "Can't open on the phone"
        }
    }
}
