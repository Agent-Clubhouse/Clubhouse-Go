import SwiftUI

/// First launch: what the app is for, one action to pair, and a demo for anyone without a Mac at hand
/// (including App Review). Shown until the first pairing or until someone moves past it.
struct CompanionWelcomeView: View {
    var onPair: () -> Void
    var onDemo: () -> Void
    @Environment(\.companionPalette) private var palette
    private static let site = URL(string: "https://agent-clubhouse.com")!

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image("ClubhouseLogo").resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Your agents, within reach").font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("Clubhouse Go connects to Clubhouse on your Mac. Chat with your agents, answer what they ask, and keep work moving when you're away from your desk.")
                        .font(.body).foregroundStyle(Color(palette.secondaryLabel)).multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    step("qrcode.viewfinder", "Pair in seconds", "Scan the code in Clubhouse → Settings → Annex.")
                    Divider().padding(.leading, 56)
                    step("hand.raised", "Answer from anywhere", "Approve requests and answer questions from Needs you.")
                    Divider().padding(.leading, 56)
                    step("lock.shield", "Stays between your devices", "Your phone talks to your Mac directly. Your code and prompts never leave your devices.")
                }
                .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                VStack(spacing: 12) {
                    Button(action: onPair) { Text("Pair your Mac").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)
                    Button("Look around first", action: onDemo).buttonStyle(.glass).controlSize(.large)
                }
                VStack(spacing: 4) {
                    Text("Don't have Clubhouse on your Mac yet?").foregroundStyle(Color(palette.secondaryLabel))
                    Link("Get it at agent-clubhouse.com", destination: Self.site)
                }
                .font(.footnote)
            }
            .padding(.horizontal, 24).padding(.vertical, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .companionBackground()
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color(palette.tint)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// The app with a sample desktop. Nothing reaches a real desktop; every action answers "Preview only".
struct CompanionDemoView: View {
    var onPair: () -> Void
    var onClose: () -> Void
    @State private var store = CompanionStore(service: CompanionPreviewService())
    @State private var preferences = CompanionPreferences(defaults: UserDefaults(suiteName: "companion-demo") ?? .standard)

    var body: some View {
        CompanionRootView(store: store, preferences: preferences, onPair: onPair, onSettings: {})
            .overlay(alignment: .bottom) {
                // Floats above the tab bar so it never collides with a screen's own toolbar.
                HStack(spacing: 10) {
                    Label("Sample desktop", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                        .padding(.leading, 6)
                    Spacer(minLength: 8)
                    Button("Pair your Mac", action: onPair).buttonStyle(.glassProminent).companionProminentLabel()
                    Button("Close demo", systemImage: "xmark", action: onClose).labelStyle(.iconOnly).buttonStyle(.glass)
                }
                .padding(8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 16).padding(.bottom, 92)
            }
    }
}
