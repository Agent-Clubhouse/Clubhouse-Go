import SwiftUI
import AVFoundation
import Vision
import VisionKit

/// Full-screen camera that looks for the pairing code shown in the desktop's Annex settings.
struct CompanionQRScannerView: View {
    var onFound: (CompanionPairingLink) -> Void
    var onCancel: () -> Void
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if access == .authorized && DataScannerViewController.isSupported {
                CompanionCodeScanner { handle($0) }.ignoresSafeArea()
            } else if access == .notDetermined {
                ProgressView().tint(.white)
            } else {
                ContentUnavailableView {
                    Label("Camera unavailable", systemImage: "camera")
                } description: {
                    Text(DataScannerViewController.isSupported
                         ? "Allow camera access for Clubhouse Go in Settings, or pair manually."
                         : "This device can't scan codes. Pair manually instead.")
                } actions: {
                    if DataScannerViewController.isSupported, let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url).buttonStyle(.glassProminent)
                    }
                }
                .foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Cancel", systemImage: "xmark", action: onCancel)
                        .labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                }
                Spacer()
                VStack(spacing: 6) {
                    Text("Point at the code on your Mac").font(.title3.bold())
                    Text(message ?? "In Clubhouse, open Settings → Annex.").font(.subheadline)
                }
                .foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                Button("Pair manually", action: onCancel).buttonStyle(.glass).controlSize(.large).padding(.top, 12)
            }
            .padding(20)
        }
        .task {
            guard access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private func handle(_ payload: String) {
        if let link = CompanionPairingLink(string: payload) { onFound(link) }
        else { message = "That isn't a Clubhouse pairing code. Use the one in Settings → Annex." }
    }
}

private struct CompanionCodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue { onCode(payload); return }
            }
        }
    }
}

/// After a scan: one card, no fingerprints to compare, since the code already proved who the desktop is.
struct CompanionInvitationView: View {
    let runtime: CompanionRuntime
    let link: CompanionPairingLink
    var onScanAgain: () -> Void
    var onPaired: () -> Void
    @State private var remember = true
    @State private var isPairing = false
    @State private var error: String?
    @Environment(\.companionPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "laptopcomputer").font(.system(size: 38)).foregroundStyle(Color(palette.tint))
                    .frame(width: 76, height: 76).background(Color(palette.tintSoft), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                VStack(spacing: 4) {
                    Text(link.name ?? "Your desktop").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("\(link.hosts[0]) · port \(String(link.port))").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                }
                Label("Identity checked from the code you scanned.", systemImage: "lock.fill")
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("This phone").font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    CompanionDeviceNameField(preferences: runtime.preferences).font(.body)
                    Text(CompanionDeviceNameField.footer).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                }
                .padding(16).background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Remember this desktop", isOn: $remember)
                    Text(remember ? "Reconnects on its own next time." : "Pairing ends when you close the app.")
                        .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                }
                .padding(16).background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("Pairing lets this phone control Clubhouse agents on this desktop.")
                    .font(.caption).foregroundStyle(Color(palette.secondaryLabel)).frame(maxWidth: .infinity, alignment: .leading)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Color(palette.error))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { Task { await pair() } } label: {
                    Group { if isPairing { ProgressView() } else { Text("Pair") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(isPairing)
                Button("Scan again", action: onScanAgain).disabled(isPairing)
            }
            .padding(20)
        }
        .companionBackground()
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isPairing)
    }

    private func pair() async {
        isPairing = true; error = nil
        defer { isPairing = false }
        do { try await runtime.pair(link: link, remember: remember); onPaired() }
        catch { self.error = CompanionLiveService.readableError(error) }
    }
}
