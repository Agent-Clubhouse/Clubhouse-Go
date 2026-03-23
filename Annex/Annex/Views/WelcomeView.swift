import SwiftUI

struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    var onContinue: () -> Void

    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var glowAmount: CGFloat = 0.3
    @State private var textOpacity: Double = 0
    @State private var hintOpacity: Double = 0

    var body: some View {
        ZStack {
            store.theme.baseColor
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo with glow
                ZStack {
                    // Ambient glow behind logo
                    Image("ClubhouseLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .blur(radius: 40)
                        .opacity(glowAmount)
                        .scaleEffect(1.2)

                    Image("ClubhouseLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .shadow(color: store.theme.accentColor.opacity(glowAmount), radius: 30)
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // Title and tagline
                VStack(spacing: 12) {
                    Text("Clubhouse Go")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("Your agents, everywhere")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .opacity(textOpacity)

                Spacer()

                // Tap hint
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Tap anywhere to continue")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .opacity(hintOpacity)

                Spacer()
                    .frame(height: 60)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onContinue()
        }
        .onAppear {
            // Staggered entrance animations
            withAnimation(.easeOut(duration: 0.8)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.7).delay(0.4)) {
                textOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.9)) {
                hintOpacity = 1.0
            }
            // Continuous gentle glow pulse
            withAnimation(
                .easeInOut(duration: 2.5)
                .repeatForever(autoreverses: true)
                .delay(0.8)
            ) {
                glowAmount = 0.6
            }
        }
    }
}

#Preview {
    WelcomeView(onContinue: {})
        .environment(AppStore())
}
