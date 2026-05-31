import SwiftUI
import AppKit

struct MainView: View {
    @StateObject var clipboardManager = ClipboardManager()
    @StateObject var notesManager = QuickNotesManager()
    @State var activeTab: Int = 0
    @State var showSetup = SetupManager.shared.isFirstLaunch
    @State var isPinned: Bool = false
    @State var didStart = false
    @State private var slideForward = true
    /// The panel owns the window size; the SwiftUI root is pinned to it with a *definite*
    /// frame. Without this, `.frame(maxWidth:.infinity)` lets SwiftUI's NSHostingView resolve
    /// an unbounded width against the screen and animate the window to a degenerate size,
    /// which trips AppKit's Update-Constraints loop guard and crashes.
    @State private var panelSize: CGSize = OxinePanelLayout.current
    var appDelegate: AppDelegate?

    /// Slide direction follows tab order: higher index enters from the right.
    var contentTransition: AnyTransition {
        slideForward
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }

    func switchTab(to tab: Int) {
        guard tab != activeTab else { return }
        slideForward = tab > activeTab
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            activeTab = tab
        }
    }

    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.menubar.settings")) var glassOpacity = 0.7
    @AppStorage("panelSizePreset", store: UserDefaults(suiteName: "com.menubar.settings")) var panelSizePreset = OxinePanelSize.standard.rawValue
    @AppStorage("panelCustomLocked", store: UserDefaults(suiteName: "com.menubar.settings")) var panelCustomLocked = false

    /// The corner grip shows only when the panel is actually drag-resizable.
    var showResizeGrip: Bool { panelSizePreset == OxinePanelSize.custom.rawValue && !panelCustomLocked }

    var body: some View {
        Group {
            if showSetup {
                SetupView(onComplete: {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showSetup = false
                        }
                    }
                })
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity))
            } else {
                mainContent
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(OxineGlassShell(tint: glassOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if showResizeGrip {
                ResizeGrip()
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottomTrailing)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showResizeGrip)
        .onAppear {
            appDelegate?.isAuthVisible = (activeTab == 2)
            guard !didStart else { return }
            didStart = true
            clipboardManager.startMonitoring()
        }
        .onChange(of: activeTab) { oldTab, newTab in
            slideForward = newTab > oldTab
            appDelegate?.isAuthVisible = (newTab == 2)
            if oldTab != 2 && newTab == 2 {
                NotificationCenter.default.post(name: .authTabActivated, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelSizeChanged)) { _ in
            panelSize = OxinePanelLayout.current
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            // Follow live custom drag-resizes so the content keeps filling the panel.
            guard OxinePanelLayout.isResizable,
                  let window = note.object as? NSWindow, window == appDelegate?.panel else { return }
            panelSize = window.frame.size
        }
    }

    var mainContent: some View {
        VStack(spacing: 0) {
            TabBar(activeTab: activeTab, onSelect: switchTab, isPinned: $isPinned, appDelegate: appDelegate)

            Group {
                switch activeTab {
                case 0:
                    NotesView(notesManager: notesManager)
                case 1:
                    ClipboardHistoryView(items: $clipboardManager.history, clipboardManager: clipboardManager, notesManager: notesManager, onSwitchToNotes: { switchTab(to: 0) })
                case 2:
                    AuthView()
                case 3:
                    SettingsView(showSetup: Binding(
                        get: { showSetup },
                        set: { showSetup = $0 }
                    ), clipboardManager: clipboardManager)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(activeTab)
            .transition(contentTransition)
            .scrollEdgeFade()

            FooterView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// iOS-style curved corner resize handle that hugs the panel's rounded
/// bottom-right corner, hinting the window can be dragged to resize.
struct ResizeGrip: View {
    var body: some View {
        ZStack {
            // Outer curve following the corner radius.
            grip(inset: 0, length: 15)
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // Inner shorter curve for the fin look.
            grip(inset: 5, length: 9)
                .stroke(.white.opacity(0.30), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }

    private func grip(inset: CGFloat, length: CGFloat) -> Path {
        Path { p in
            let s: CGFloat = 18
            p.move(to: CGPoint(x: s - inset, y: s - inset - length))
            p.addQuadCurve(
                to: CGPoint(x: s - inset - length, y: s - inset),
                control: CGPoint(x: s - inset, y: s - inset)
            )
        }
    }
}

/// The single Liquid Glass surface the whole panel sits on. One uniform tint
/// driven by `glassOpacity` — no stacked materials, no separate dark slab.
struct OxineGlassShell: View {
    let tint: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.28 + tint * 0.42))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    /// Softly fades content under the chrome at top and bottom instead of
    /// cutting it with divider lines.
    func scrollEdgeFade(top: CGFloat = 14, bottom: CGFloat = 16) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        )
    }
}

struct TabBar: View {
    var activeTab: Int
    var onSelect: (Int) -> Void
    @Binding var isPinned: Bool
    var appDelegate: AppDelegate?
    var isAuthLocked: Bool { activeTab == 2 && (appDelegate?.isAuthenticating ?? false) }
    @Namespace private var tabAnimation
    @State private var focusEnabled = FocusModeManager.shared.isEnabled
    /// Collapse tab labels to icons when the panel gets too narrow to fit text.
    @State private var compact = false
    var body: some View {
        HStack(spacing: compact ? 4 : 2) {
            TabBarItem(icon: "square.and.pencil", title: "Notes", isActive: activeTab == 0, compact: compact, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                onSelect(0)
            }
            TabBarItem(icon: "clock.arrow.circlepath", title: "History", isActive: activeTab == 1, compact: compact, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                onSelect(1)
            }
            TabBarItem(icon: "lock.shield", title: "Auth", isActive: activeTab == 2, compact: compact, namespace: tabAnimation) {
                onSelect(2)
            }
            TabBarItem(icon: "gearshape", title: "Settings", isActive: activeTab == 3, compact: compact, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                onSelect(3)
            }
            Spacer(minLength: 0)
            Button(action: {
                FocusModeManager.shared.toggle()
                focusEnabled = FocusModeManager.shared.isEnabled
            }) {
                Image(systemName: focusEnabled ? "moon.fill" : "moon")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(focusEnabled ? 0.6 : 0.25))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help(focusEnabled ? "Disable focus mode" : "Dim background windows")
            Button(action: {
                isPinned.toggle()
                appDelegate?.setPinned(isPinned)
            }) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(isPinned ? 0.6 : 0.2))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help(isPinned ? "Unpin" : "Pin")
        }
        .frame(height: 44)
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let shouldCompact = width < 360
            if shouldCompact != compact {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { compact = shouldCompact }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: activeTab)
    }

}

struct TabBarItem: View {
    let icon: String
    let title: String
    let isActive: Bool
    var compact: Bool = false
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                        Text(title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .foregroundColor(.white.opacity(isActive ? 0.85 : 0.25))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 7 : 5)
            .background(
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.12))
                            .matchedGeometryEffect(id: "tabHighlight", in: namespace)
                            .transition(.identity)
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
    }
}

struct FooterView: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Esc to close")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.2))
            Spacer()
            Text("\(Image(systemName: "command"))\u{21E7}V to open")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.15))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
