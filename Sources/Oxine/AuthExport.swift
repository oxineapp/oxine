import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PanelKit

/// What the export card shows: the accounts picked (all of them, or one row's).
struct ExportRequest: Identifiable {
    let id = UUID()
    let accounts: [Account]
}

/// Shows accounts as Google Authenticator migration QR codes, one per batch of
/// ten, for moving them to a phone or another authenticator app. A Liquid
/// Glass card shown over the Auth tab.
struct ExportAccountsView: View {
    let request: ExportRequest
    let onDone: () -> Void
    @State private var links: [String] = []
    @State private var page = 0
    @State private var copied = false
    /// The code starts veiled; a click reveals it from the click point, and
    /// another click veils it again.
    @State private var qrHidden = true
    @State private var qrOrigin: UnitPoint = .center

    private var leftOut: [Account] {
        request.accounts.filter { !MigrationHandler.canExport($0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(request.accounts.count == 1 ? "Export Account" : "Export Accounts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("Scan in Google Authenticator or any app that imports from it.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)

            if links.isEmpty {
                Text("None of these accounts fit the export format.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 20)
            } else {
                if let image = QRCode.image(for: links[page]) {
                    qrCard(image)
                }

                if links.count > 1 { pager }

                Text("Anyone who sees this code can copy these accounts.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            if !leftOut.isEmpty {
                Text("Not included (only 30-second, 6- or 8-digit codes transfer): \(leftOut.map(\.label).joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if !links.isEmpty {
                    Button(copied ? "Copied" : "Copy Link") { copyLink() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(copied ? 0.85 : 0.6))
                        .animation(.easeOut(duration: 0.15), value: copied)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.panelAccent)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 18)
        .frame(width: 290)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .focusEffectDisabled()
        .onAppear { links = MigrationHandler.makeMigrationURLs(request.accounts) }
    }

    private static let cardSide: CGFloat = 220

    private func qrCard(_ image: CGImage) -> some View {
        Spoiler(isHidden: qrHidden, origin: qrOrigin, style: .image) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(width: Self.cardSide, height: Self.cardSide)
                .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            ZStack {
                if qrHidden {
                    Label("Click to show", systemImage: "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: qrHidden)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            qrOrigin = UnitPoint(x: location.x / Self.cardSide, y: location.y / Self.cardSide)
            qrHidden.toggle()
        }
        .help(qrHidden ? "Show the code" : "Hide the code")
    }

    private var pager: some View {
        HStack(spacing: 14) {
            Button { page -= 1; copied = false } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
            Text("Code \(page + 1) of \(links.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            Button { page += 1; copied = false } label: { Image(systemName: "chevron.right") }
                .disabled(page == links.count - 1)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.6))
    }

    /// Copies the shown link marked concealed, so clipboard histories (Oxine's
    /// shows it veiled) treat it as a secret.
    private func copyLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(links[page], forType: .string)
        pasteboard.setData(Data(), forType: .concealed)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

enum QRCode {
    /// One pixel per module; draw it with `.interpolation(.none)` to scale up.
    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
