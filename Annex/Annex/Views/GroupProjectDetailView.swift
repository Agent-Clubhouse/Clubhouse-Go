import SwiftUI

/// Detail view for a Group Project canvas node.
/// Shows metadata from the canvas view (read-only first pass).
struct GroupProjectDetailView: View {
    let canvasView: CanvasView
    let instance: ServerInstance?
    let theme: ThemeColors

    private var name: String {
        metadataString("name") ?? canvasView.displayLabel
    }

    private var description: String? {
        metadataString("description")
    }

    private var instructions: String? {
        metadataString("instructions")
    }

    private var groupProjectId: String? {
        metadataString("groupProjectId")
    }

    private var connectedAgentCount: Int {
        instance?.allAgents.filter { $0.status == .running }.count ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if let description, !description.isEmpty {
                    sectionCard(title: "Description", content: description)
                }
                if let instructions, !instructions.isEmpty {
                    sectionCard(title: "Instructions", content: instructions)
                }
                statusSection
                infoSection
            }
            .padding()
        }
        .background(theme.baseColor)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.accentColor)

            Text(name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Label("\(connectedAgentCount) agents connected", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Section Card

    private func sectionCard(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.surface0Color.opacity(0.5))
        )
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bulletin Board")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bulletin interaction requires server-side support")
                        .font(.subheadline)
                    Text("Read topics, post messages, and shoulder-tap will be available in a future update.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface0Color.opacity(0.3))
            )
        }
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                if let gpId = groupProjectId {
                    infoRow(label: "Project ID", value: gpId)
                    Divider().padding(.leading)
                }
                infoRow(label: "Node Type", value: "Group Project Plugin")
                Divider().padding(.leading)
                infoRow(label: "Canvas Position",
                        value: "(\(Int(canvasView.position.x)), \(Int(canvasView.position.y)))")
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface0Color.opacity(0.5))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Metadata Helpers

    private func metadataString(_ key: String) -> String? {
        guard case .object(let dict) = canvasView.metadata,
              case .string(let value) = dict[key] else { return nil }
        return value
    }
}
