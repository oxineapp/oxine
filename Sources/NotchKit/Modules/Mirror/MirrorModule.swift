import SwiftUI
import AVFoundation
import PanelKit

/// The webcam mirror slot used inside the Home tab — a quick self-view to check
/// your hair/teeth before a call. The camera never goes live just because the
/// notch opened: it's strictly click-to-open, and stops when the view goes away.
struct CameraSlot: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    /// The camera never goes live just because the Mirror tab is selected — it
    /// only starts on an explicit click, and stops when the view goes away.
    @State private var started = false

    var body: some View {
        Group {
            if started && status == .authorized {
                // Click the live view again to close it.
                CameraView()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { started = false }
                    .help("Click to close")
            } else if status == .denied || status == .restricted {
                message("Camera access denied. Enable it in System Settings › Privacy.")
            } else {
                prompt("Open camera", system: "camera.fill", openCamera)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openCamera() {
        switch status {
        case .authorized:
            started = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    status = AVCaptureDevice.authorizationStatus(for: .video)
                    started = granted
                }
            }
        default:
            break
        }
    }

    private func prompt(_ text: String, system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: system).font(.system(size: 22))
                Text(text).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.panelAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AVCaptureVideoPreviewLayer host

private struct CameraView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraSessionView { CameraSessionView() }
    func updateNSView(_ nsView: CameraSessionView, context: Context) {}
    static func dismantleNSView(_ nsView: CameraSessionView, coordinator: ()) { nsView.stop() }
}

/// Layer-backed view that owns the capture session. Front-camera previews are
/// mirrored by default, which is exactly what a mirror wants.
private final class CameraSessionView: NSView {
    // nonisolated(unsafe): the session is configured/torn down on a private queue.
    private nonisolated(unsafe) let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let queue = DispatchQueue(label: "com.oxine.notch.mirror")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = session
        layer = previewLayer
        start()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        // Show the true (un-mirrored) image. Front-camera previews default to
        // mirrored; turn that off so text/orientation read correctly.
        if let conn = previewLayer.connection, conn.automaticallyAdjustsVideoMirroring {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
        }
    }

    private func start() {
        let session = self.session
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        let session = self.session
        queue.async {
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
        }
    }
}
