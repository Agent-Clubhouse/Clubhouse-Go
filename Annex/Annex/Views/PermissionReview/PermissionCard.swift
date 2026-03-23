import SwiftUI

struct PermissionCard: View {
    let permission: PermissionRequest
    let agentName: String?
    let agentColor: String?
    let instanceName: String
    let isTopCard: Bool
    let onDecision: (Bool) -> Void

    @State private var offset: CGSize = .zero
    @State private var isExpanded = false

    private var swipeProgress: CGFloat {
        offset.width / 150
    }

    private var toolInputSummary: String? {
        guard let input = permission.toolInput else { return nil }
        switch input {
        case .object(let dict):
            if let path = dict["path"], case .string(let s) = path { return s }
            if let command = dict["command"], case .string(let s) = command {
                return String(s.prefix(120))
            }
            if let pattern = dict["pattern"], case .string(let s) = pattern { return s }
            return nil
        case .string(let s):
            return String(s.prefix(120))
        default:
            return nil
        }
    }

    var body: some View {
        ZStack {
            // Background reveal
            RoundedRectangle(cornerRadius: 20)
                .fill(revealColor)

            // Card content
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    AgentAvatarView(
                        color: agentColor ?? "gray",
                        status: .running,
                        state: .needsPermission,
                        name: agentName,
                        size: 36
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(agentName ?? permission.agentId)
                            .font(.subheadline.weight(.semibold))
                        Text(instanceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    PermissionTimerView(deadline: permission.deadline)
                }

                Divider()

                // Tool request
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.orange)
                        Text("Wants to use")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(permission.toolName)
                        .font(.title3.weight(.bold))
                }

                // Expandable details
                if let message = permission.message {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Details")
                                    .font(.caption.weight(.medium))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if isExpanded {
                            Text(message)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.secondary.opacity(0.1))
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                if let summary = toolInputSummary {
                    Text(summary)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .lineLimit(isExpanded ? nil : 2)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.secondary.opacity(0.1))
                        )
                }

                Spacer()

                // Swipe hint
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Deny")
                    Spacer()
                    Text("Allow")
                    Image(systemName: "arrow.right")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(borderColor, lineWidth: 2)
            )
        }
        .frame(height: 340)
        .offset(offset)
        .rotationEffect(.degrees(Double(offset.width) / 25))
        .gesture(
            isTopCard ? DragGesture()
                .onChanged { value in
                    offset = value.translation
                }
                .onEnded { value in
                    if value.translation.width > 120 {
                        withAnimation(.easeOut(duration: 0.3)) {
                            offset = CGSize(width: 500, height: 0)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onDecision(true)
                        }
                    } else if value.translation.width < -120 {
                        withAnimation(.easeOut(duration: 0.3)) {
                            offset = CGSize(width: -500, height: 0)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onDecision(false)
                        }
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            offset = .zero
                        }
                    }
                }
            : nil
        )
    }

    private var revealColor: Color {
        if swipeProgress > 0.2 { return .green.opacity(min(Double(swipeProgress), 1.0)) }
        if swipeProgress < -0.2 { return .red.opacity(min(Double(-swipeProgress), 1.0)) }
        return .clear
    }

    private var borderColor: Color {
        if swipeProgress > 0.3 { return .green.opacity(0.6) }
        if swipeProgress < -0.3 { return .red.opacity(0.6) }
        return .clear
    }
}

struct PermissionTimerView: View {
    let deadline: Int?

    @State private var timeString = ""
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(timeString)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(urgencyColor)
        .onReceive(timer) { _ in updateTime() }
        .onAppear { updateTime() }
    }

    private var remainingSeconds: Int {
        guard let deadline else { return Int.max }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return max(0, (deadline - now) / 1000)
    }

    private var urgencyColor: Color {
        let remaining = remainingSeconds
        if remaining <= 0 { return .red }
        if remaining < 30 { return .orange }
        return .secondary
    }

    private func updateTime() {
        let seconds = remainingSeconds
        if seconds == Int.max {
            timeString = ""
            return
        }
        if seconds <= 0 {
            timeString = "Expired"
            return
        }
        if seconds < 60 {
            timeString = "\(seconds)s"
        } else {
            timeString = "\(seconds / 60)m \(seconds % 60)s"
        }
    }
}
