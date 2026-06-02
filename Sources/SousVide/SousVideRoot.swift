import SwiftUI
import PanelKit
import SousKit

/// The whole sous-vide panel: the Sous control surface, a footer with a settings
/// gear, and a Settings route that slides over it. Pinned to the panel size with
/// a definite frame (see PanelKit's root-frame discipline).
struct SousVideRoot: View {
    var appDelegate: AppDelegate?
    @ObservedObject private var sous = SousManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showingSettings = false
    @State private var panelSize: CGSize = PanelLayout.current

    @AppStorage("glassOpacity", store: PanelKit.settingsDefaults) private var glassOpacity = 0.7
    @AppStorage("panelSizePreset", store: PanelKit.settingsDefaults) private var panelSizePreset = PanelSize.standard.rawValue
    @AppStorage("panelCustomLocked", store: PanelKit.settingsDefaults) private var panelCustomLocked = false

    /// The corner grip shows only when the panel is actually drag-resizable.
    private var showResizeGrip: Bool { panelSizePreset == PanelSize.custom.rawValue && !panelCustomLocked }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if showingSettings {
                    SousVideSettings()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    SousView(sous: sous)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(GlassShell(tint: glassOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if showResizeGrip {
                ResizeGrip()
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottomTrailing)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showResizeGrip)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { showingSettings = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelSizeChanged)) { _ in
            // Match the window's eased resize so the content tracks it instead of snapping.
            withAnimation(.easeInOut(duration: PanelLayout.resizeDuration)) { panelSize = PanelLayout.current }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            // Follow live custom drag-resizes; skip while a preset change is
            // animating the window (else the content snaps each tick and fights
            // the eased panelSizeChanged animation).
            guard PanelLayout.isResizable,
                  appDelegate?.isProgrammaticResize == false,
                  let window = note.object as? NSWindow, window == appDelegate?.panel else { return }
            panelSize = window.frame.size
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.badge.bolt")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.panelAccent, .white.opacity(0.9))
            Text(showingSettings ? "Settings" : "sous-vide")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Button(action: {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { showingSettings.toggle() }
            }) {
                Image(systemName: showingSettings ? "chevron.left" : "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Back" : "Settings")
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}
