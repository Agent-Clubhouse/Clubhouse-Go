import SwiftUI
import UIKit
import Combine

struct PermissionRequestSheet: View {
    let permission: PermissionRequest
    let agentName: String?

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isExpired = false
    private let expirationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeRemaining: String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let remainingMs = max(0, (permission.deadline ?? 0) - now)
        let seconds = remainingMs / 1000
        if seconds <= 0 { return "Expired" }
        if seconds < 60 { return "\(seconds)s remaining" }
        return "\(seconds / 60)m \(seconds % 60)s remaining"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agentName ?? permission.agentId)
                                .font(.headline)
                            Text("wants to use **\(permission.toolName)**")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let message = permission.message {
                    Section("Details") {
                        Text(message)
                            .font(.subheadline)
                    }
                }

                if let summary = permission.toolInputSummary {
                    Section("Input") {
                        Text(summary)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .lineLimit(4)
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text(timeRemaining)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                if isExpired {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("This permission request has expired")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task { await respond(allow: true) }
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Allow", systemImage: "checkmark.shield")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isSubmitting)

                        Button(role: .destructive) {
                            Task { await respond(allow: false) }
                        } label: {
                            HStack {
                                Spacer()
                                Label("Deny", systemImage: "xmark.shield")
                                Spacer()
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Permission Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
            }
            .onReceive(expirationTimer) { _ in
                guard let deadline = permission.deadline else { return }
                let now = Int(Date().timeIntervalSince1970 * 1000)
                if now >= deadline && !isExpired {
                    isExpired = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
        }
    }

    private func respond(allow: Bool) async {
        isSubmitting = true
        errorMessage = nil

        let style: UIImpactFeedbackGenerator.FeedbackStyle = allow ? .medium : .rigid
        UIImpactFeedbackGenerator(style: style).impactOccurred()

        do {
            try await store.respondToPermission(
                agentId: permission.agentId,
                requestId: permission.id,
                allow: allow
            )
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            isSubmitting = false
        }
    }
}

// MARK: - Permission Banner (shown inline in AgentDetailView)

struct PermissionBanner: View {
    let permission: PermissionRequest
    let onTap: () -> Void

    @Environment(AppStore.self) private var store
    @State private var isResponding = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Permission")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(permission.toolName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            Task { await quickRespond(allow: true) }
                        } label: {
                            Text("Allow")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.25))
                                .clipShape(Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await quickRespond(allow: false) }
                        } label: {
                            Text("Deny")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
            .opacity(isResponding ? 0.6 : 1)

            Divider()
        }
    }

    private func quickRespond(allow: Bool) async {
        isResponding = true
        let style: UIImpactFeedbackGenerator.FeedbackStyle = allow ? .medium : .rigid
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        try? await store.respondToPermission(
            agentId: permission.agentId,
            requestId: permission.id,
            allow: allow
        )
        isResponding = false
    }
}
