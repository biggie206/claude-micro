// FR-020: scan the server's pairing QR (claudemicro://pair?url=…&token=…) instead of
// typing a URL and 32-char token on a phone keyboard.
import AVFoundation
import SwiftUI
import VisionKit

enum Pairing {
    /// Parses a claudemicro://pair URI. Returns nil for anything else.
    static func parse(_ raw: String) -> (url: String, token: String)? {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "claudemicro", c.host == "pair",
              let url = c.queryItems?.first(where: { $0.name == "url" })?.value,
              let token = c.queryItems?.first(where: { $0.name == "token" })?.value,
              url.hasPrefix("ws://") || url.hasPrefix("wss://"),
              !token.isEmpty
        else { return nil }
        return (url, token)
    }
}

struct PairingSheet: View {
    let onPaired: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rejected = false

    var body: some View {
        NavigationStack {
            Group {
                // isSupported only: isAvailable stays false until camera access is granted,
                // and presenting the scanner is what triggers the permission prompt.
                if DataScannerViewController.isSupported {
                    QRScannerView { payload in
                        if let pairing = Pairing.parse(payload) {
                            onPaired(pairing.url, pairing.token)
                            return true    // latch — stop scanning
                        }
                        rejected = true
                        return false       // keep scanning; wrong QR shouldn't dead-end the sheet
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("Run `npm run pair` on the Mac and enter the URL + token manually in Settings."))
                }
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if rejected {
                    Text("Not a Claude Micro pairing code")
                        .font(.caption).padding(8)
                        .background(.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    /// Returns true when the payload was accepted (latches the scanner).
    let onScan: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { if granted { try? vc.startScanning() } }
        }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Bool
        private var fired = false
        init(onScan: @escaping (String) -> Bool) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for case let .barcode(barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    fired = onScan(payload)
                    if fired { return }
                }
            }
        }
    }
}
