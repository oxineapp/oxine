import SwiftUI
import AppKit

struct MainView: View {
    @StateObject var clipboardManager = ClipboardManager()
    @StateObject var notesManager = QuickNotesManager()
    /// Observed so a tint change in Settings re-renders the whole tree and every
    /// computed `accent` picks up the new colour.
    @ObservedObject private var theme = ThemeManager.shared
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
    @AppStorage("requireBiometricsForClipboard", store: UserDefaults(suiteName: "com.menubar.settings")) var requireClipboardAuth = false
    @AppStorage("requireBiometricsForNotes", store: UserDefaults(suiteName: "com.menubar.settings")) var requireNotesAuth = false

    /// Per-session unlock for tabs that require Touch ID. Reset whenever the user
    /// navigates away, so each visit re-authenticates.
    @State private var clipboardUnlocked = false
    @State private var notesUnlocked = false
    /// The content tab to return to when leaving Settings (which is opened from
    /// the footer gear rather than living in the tab bar).
    @State private var preSettingsTab = 0

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
            if newTab != 1 { clipboardUnlocked = false }
            if newTab != 0 { notesUnlocked = false }
            if oldTab != 2 && newTab == 2 {
                NotificationCenter.default.post(name: .authTabActivated, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelSizeChanged)) { _ in
            // Match the window's eased resize (see AppDelegate.applyPanelSize) so
            // the content frame tracks the window instead of snapping ahead of it.
            withAnimation(.easeInOut(duration: OxinePanelLayout.resizeDuration)) {
                panelSize = OxinePanelLayout.current
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            // Follow live custom drag-resizes so the content keeps filling the panel.
            // Skip while a preset change is animating the window — otherwise this
            // snaps the content frame to each animation tick and fights the eased
            // `panelSizeChanged` animation (the preset→custom jump).
            guard OxinePanelLayout.isResizable,
                  appDelegate?.isProgrammaticResize == false,
                  let window = note.object as? NSWindow, window == appDelegate?.panel else { return }
            panelSize = window.frame.size
        }
    }

    func toggleSettings() {
        if activeTab == 4 {
            switchTab(to: preSettingsTab)
        } else {
            preSettingsTab = activeTab
            switchTab(to: 4)
        }
    }

    var mainContent: some View {
        VStack(spacing: 0) {
            TabBar(activeTab: activeTab, onSelect: switchTab, appDelegate: appDelegate)

            Group {
                switch activeTab {
                case 0:
                    if requireNotesAuth && !notesUnlocked {
                        BiometricLockView(
                            title: "Notes Locked",
                            subtitle: "Authenticate to view your notes.",
                            reason: "Unlock to view your notes",
                            onUnlock: { notesUnlocked = true }
                        )
                    } else {
                        NotesView(notesManager: notesManager)
                    }
                case 1:
                    if requireClipboardAuth && !clipboardUnlocked {
                        BiometricLockView(
                            title: "Clipboard Locked",
                            subtitle: "Authenticate to view your clipboard history.",
                            reason: "Unlock to view your clipboard history",
                            onUnlock: { clipboardUnlocked = true }
                        )
                    } else {
                        ClipboardHistoryView(items: $clipboardManager.history, clipboardManager: clipboardManager, notesManager: notesManager, onSwitchToNotes: { switchTab(to: 0) })
                    }
                case 2:
                    AuthView()
                case 3:
                    PluginsView(clipboardManager: clipboardManager, notesManager: notesManager)
                case 4:
                    VStack(spacing: 0) {
                        SettingsBackBar(onBack: { switchTab(to: preSettingsTab) })
                        SettingsView(showSetup: Binding(
                            get: { showSetup },
                            set: { showSetup = $0 }
                        ), clipboardManager: clipboardManager)
                    }
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(activeTab)
            .transition(contentTransition)
            .scrollEdgeFade()

            FooterView(
                isPinned: $isPinned,
                isSettingsOpen: activeTab == 4,
                appDelegate: appDelegate,
                onToggleSettings: toggleSettings
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin header shown above Settings (which now opens from the footer gear, not a
/// tab) giving an explicit way back to wherever you were.
struct SettingsBackBar: View {
    let onBack: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
    var appDelegate: AppDelegate?
    var isAuthLocked: Bool { activeTab == 2 && (appDelegate?.isAuthenticating ?? false) }
    @Namespace private var tabAnimation
    /// Natural width of the labelled row, measured once by a hidden probe. The
    /// only measured value; the available width comes free from the layout.
    @State private var labeledWidth: CGFloat = 0

    /// Only content tabs now — utilities (focus/pin) and Settings moved to the
    /// footer so the top bar is pure navigation and can breathe.
    private let tabs: [(icon: String, title: String, index: Int)] = [
        ("square.and.pencil", "Notes", 0),
        ("clock.arrow.circlepath", "History", 1),
        ("lock.shield", "Auth", 2),
        ("puzzlepiece.extension", "Plugins", 3),
    ]

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width
            let compact = labeledWidth == 0 || labeledWidth > available
            tabRow(compact: compact)
                .frame(width: available, height: geo.size.height)
                .animation(.spring(response: 0.36, dampingFraction: 0.72), value: compact)
        }
        .frame(height: 46)
        .padding(.horizontal, 10)
        // Hidden probe: the labelled row at its natural width drives the fit
        // decision above.
        .background(
            labelledProbe
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labeledWidth = $0 }
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: activeTab)
    }

    /// One row of tabs that stretches each item (`maxWidth: .infinity`) to fill
    /// the width it's given — so the tabs use all the space they have instead of
    /// sitting at natural size.
    private func tabRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 3) {
            ForEach(tabs, id: \.index) { tab in
                TabBarItem(icon: tab.icon, title: tab.title, isActive: activeTab == tab.index, compact: compact, namespace: tabAnimation) {
                    if tab.index == 2 { onSelect(2) }          // Auth is reachable even while locked
                    else if !isAuthLocked { onSelect(tab.index) }
                }
            }
        }
    }

    /// Off-screen labelled row at natural width (drives `labeledWidth`).
    private var labelledProbe: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.index) { tab in
                TabBarItem(icon: tab.icon, title: tab.title, isActive: false, compact: false, namespace: tabAnimation, action: {})
            }
        }
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
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
            HStack(spacing: compact ? 0 : 4) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 14.5 : 12.5))
                if !compact {
                    Text(title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.4, anchor: .leading)),
                            removal: .opacity.combined(with: .scale(scale: 0.4, anchor: .leading))
                        ))
                }
            }
            .foregroundColor(.white.opacity(isActive ? 0.9 : 0.28))
            .padding(.horizontal, compact ? 8 : 8)
            .padding(.vertical, compact ? 7 : 7)
            // Compact: let the padded content fill the whole slot so the active
            // pill becomes a slot-wide pill (not a circle round the icon).
            .frame(maxWidth: compact ? .infinity : nil)
            .background(
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(Color.oxineAccent.opacity(0.12))
                            .matchedGeometryEffect(id: "tabHighlight", in: namespace)
                    }
                }
            )
            // Spread every slot evenly across the row (both modes).
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Suppress the macOS keyboard focus ring — on tabs with no focusable
        // content (e.g. clipboard) focus defaulted to the first tab and drew a
        // stray blue outline around "Notes".
        .focusEffectDisabled()
        .help(compact ? title : "")
    }
}

/// The bottom chrome. Hosts the secondary utility cluster (focus, pin, settings)
/// that used to orphan the top bar, plus the keyboard hints. Demoting these here
/// keeps the top bar pure navigation.
struct FooterView: View {
    @Binding var isPinned: Bool
    var isSettingsOpen: Bool
    var appDelegate: AppDelegate?
    var onToggleSettings: () -> Void
    @State private var focusEnabled = FocusModeManager.shared.isEnabled
    private var accent: Color { .oxineAccent }

    var body: some View {
        HStack(spacing: 4) {
            Text("Esc")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.2))
                .padding(.trailing, 4)

            utilityButton(
                icon: focusEnabled ? "moon.fill" : "moon",
                on: focusEnabled,
                help: focusEnabled ? "Disable focus mode" : "Dim background windows"
            ) {
                FocusModeManager.shared.toggle()
                focusEnabled = FocusModeManager.shared.isEnabled
            }
            utilityButton(
                icon: isPinned ? "pin.fill" : "pin",
                on: isPinned,
                help: isPinned ? "Unpin" : "Pin"
            ) {
                isPinned.toggle()
                appDelegate?.setPinned(isPinned)
            }
            utilityButton(
                icon: "gearshape",
                on: isSettingsOpen,
                help: "Settings",
                action: onToggleSettings
            )

            Spacer()

            Text("\(Image(systemName: "command"))\u{21E7}V to open")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.15))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func utilityButton(icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(on ? 0.85 : 0.32))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? accent.opacity(0.14) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown in place of a tab's content when "Require Touch ID" is on and the tab
/// hasn't been unlocked this visit. Auto-prompts on appear; offers a manual
/// retry if the user cancels. Reused by the clipboard and notes tabs so both
/// lock screens are identical.
struct BiometricLockView: View {
    let title: String
    let subtitle: String
    let reason: String
    let onUnlock: () -> Void
    @State private var authing = false
    @State private var failed = false
    private var accent: Color { .oxineAccent }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Button(action: authenticate) {
                HStack(spacing: 6) {
                    if authing {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "touchid")
                    }
                    Text(authing ? "Authenticating…" : (failed ? "Try Again" : "Unlock with Touch ID"))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(accent)
                .background(Capsule().fill(accent.opacity(0.12)))
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(authing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        guard !authing else { return }
        authing = true
        failed = false
        confirmWithBiometrics(reason: reason) { ok in
            authing = false
            if ok { onUnlock() } else { failed = true }
        }
    }
}
