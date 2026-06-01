import Foundation
import CoreImage
import CoreGraphics
import AppKit

enum QRImport {
    /// Whether Oxine already has Screen Recording permission. Without it a
    /// screenshot of another app's window (where the QR lives) comes back blank.
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompt for Screen Recording (adds Oxine to the System Settings list). The
    /// grant only takes effect after a relaunch, so callers should tell the user
    /// to reopen Oxine.
    @discardableResult
    static func requestScreenAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func decode(imageURL: URL) -> [String] {
        guard let ci = CIImage(contentsOf: imageURL) else { return [] }
        return decode(ciImage: ci)
    }

    static func decode(ciImage: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func captureScreenRegion() -> [String] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("menubar-auth-qr.png")
        try? FileManager.default.removeItem(at: tmp)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", tmp.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        guard FileManager.default.fileExists(atPath: tmp.path) else { return [] }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return decode(imageURL: tmp)
    }

    @MainActor
    static func pickImageAndDecode() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        return decode(imageURL: url)
    }
}
