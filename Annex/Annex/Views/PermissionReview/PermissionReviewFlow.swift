import SwiftUI
import UIKit

struct PermissionReviewFlow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var completedCount = 0

    private var permissions: [AppStore.InstancePermission] {
        store.allPendingPermissions
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Done") { dismiss() }
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(completedCount)/\(completedCount + permissions.count) reviewed")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Color.clear.frame(width: 44)
            }
            .padding()

            if permissions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("All caught up!")
                        .font(.title3.weight(.semibold))
                    Text("No pending permissions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Spacer()

                // Card stack
                ZStack {
                    ForEach(Array(permissions.enumerated().reversed()), id: \.element.id) { index, perm in
                        if index >= currentIndex && index < currentIndex + 3 {
                            let agent = store.durableAgent(byId: perm.permission.agentId)
                            PermissionCard(
                                permission: perm.permission,
                                agentName: agent?.name,
                                agentColor: agent?.color,
                                instanceName: perm.instance.serverName,
                                isTopCard: index == currentIndex,
                                onDecision: { allow in
                                    handleDecision(perm: perm, allow: allow)
                                }
                            )
                            .offset(y: CGFloat(index - currentIndex) * 8)
                            .scaleEffect(1.0 - CGFloat(index - currentIndex) * 0.04)
                            .zIndex(Double(permissions.count - index))
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // Action buttons
                if currentIndex < permissions.count {
                    HStack(spacing: 40) {
                        Button {
                            let perm = permissions[currentIndex]
                            handleDecision(perm: perm, allow: false)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title2.weight(.bold))
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(.red.opacity(0.15)))
                                .foregroundStyle(.red)
                        }

                        Button {
                            let perm = permissions[currentIndex]
                            handleDecision(perm: perm, allow: true)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.title2.weight(.bold))
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(.green.opacity(0.15)))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .background(store.theme.baseColor)
    }

    private func handleDecision(perm: AppStore.InstancePermission, allow: Bool) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle = allow ? .medium : .rigid
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        Task {
            try? await store.respondToPermission(
                agentId: perm.permission.agentId,
                requestId: perm.permission.id,
                allow: allow
            )
            completedCount += 1
        }
    }
}
