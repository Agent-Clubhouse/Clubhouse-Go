import SwiftUI

struct LogViewerView: View {
    @State private var log = AppLog.shared
    @State private var filterLevel: AppLog.Entry.Level?
    @State private var filterCategory: String?
    @State private var showShareSheet = false
    @State private var searchText = ""

    private var filteredEntries: [AppLog.Entry] {
        log.entries.reversed().filter { entry in
            if let level = filterLevel, entry.level != level { return false }
            if let cat = filterCategory, entry.category != cat { return false }
            if !searchText.isEmpty {
                let text = searchText.lowercased()
                return entry.message.lowercased().contains(text)
                    || entry.category.lowercased().contains(text)
            }
            return true
        }
    }

    private var categories: [String] {
        Array(Set(log.entries.map(\.category))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: filterLevel == nil && filterCategory == nil) {
                        filterLevel = nil
                        filterCategory = nil
                    }
                    FilterChip(label: "Errors", isSelected: filterLevel == .error, color: .red) {
                        filterLevel = filterLevel == .error ? nil : .error
                        filterCategory = nil
                    }
                    FilterChip(label: "Warnings", isSelected: filterLevel == .warn, color: .orange) {
                        filterLevel = filterLevel == .warn ? nil : .warn
                        filterCategory = nil
                    }
                    ForEach(categories, id: \.self) { cat in
                        FilterChip(label: cat, isSelected: filterCategory == cat, color: .blue) {
                            filterCategory = filterCategory == cat ? nil : cat
                            filterLevel = nil
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)

            Divider()

            // Log entries
            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(log.entries.isEmpty ? "No logs yet" : "No matching logs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                }
            }
        }
        .background(.black)
        .navigationTitle("Logs (\(log.entries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter logs...")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(log.entries.isEmpty)

                Menu {
                    Button {
                        UIPasteboard.general.string = log.exportText
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        log.clear()
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(text: log.exportText)
        }
    }
}

private struct LogEntryRow: View {
    let entry: AppLog.Entry

    private var levelColor: Color {
        switch entry.level {
        case .error: .red
        case .warn: .orange
        case .info: .green
        case .debug: .gray
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.gray)
                .frame(width: 80, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 40)

            Text(entry.category)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 50, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    var color: Color = .secondary

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? color.opacity(0.3) : .secondary.opacity(0.15))
                )
                .foregroundStyle(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    // Add some sample entries
    AppLog.shared.info("Pairing", "Pairing with host=192.168.1.10 port=3000")
    AppLog.shared.info("WS", "Connected to wss://192.168.1.10:8443/ws")
    AppLog.shared.info("WS", "Snapshot: 3 projects, 5 agents")
    AppLog.shared.warn("WS", "Reconnecting (attempt 1)")
    AppLog.shared.error("Pairing", "Invalid PIN — server returned 401")
    AppLog.shared.debug("Crypto", "Ed25519 fingerprint: AA:BB:CC:DD:EE:FF")
    AppLog.shared.info("WS", "Permission request: agent=faithful-urchin tool=Bash")
    AppLog.shared.info("Perm", "Responded allow for requestId=perm_001")

    return NavigationStack {
        LogViewerView()
    }
}
