import SwiftUI

struct MainView: View {
    @StateObject var clipboardManager = ClipboardManager()
    @StateObject var notesManager = QuickNotesManager()
    @State var activeTab: Int = 0
    @State var showSetup = SetupManager.shared.isFirstLaunch
    @State var isPinned: Bool = false
    @State var didStart = false
    var appDelegate: AppDelegate?

    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.menubar.settings")) var glassOpacity = 0.7

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
        .frame(width: 360, height: 470)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear {
            appDelegate?.isAuthVisible = (activeTab == 2)
            guard !didStart else { return }
            didStart = true
            clipboardManager.startMonitoring()
        }
        .onChange(of: activeTab) { oldTab, newTab in
            appDelegate?.isAuthVisible = (newTab == 2)
            if oldTab != 2 && newTab == 2 {
                NotificationCenter.default.post(name: .authTabActivated, object: nil)
            }
        }
    }

    var mainContent: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .opacity(glassOpacity * 0.55)

            VStack(spacing: 0) {
                TabBar(activeTab: $activeTab, isPinned: $isPinned, appDelegate: appDelegate)

                Group {
                    switch activeTab {
                    case 0:
                        NotesView(notesManager: notesManager)
                    case 1:
                        ClipboardHistoryView(items: $clipboardManager.history, clipboardManager: clipboardManager, notesManager: notesManager)
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
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity)

                FooterView()
            }
        }
        .frame(width: 360, height: 470)
    }
}

struct TabBar: View {
    @Binding var activeTab: Int
    @Binding var isPinned: Bool
    var appDelegate: AppDelegate?
    var isAuthLocked: Bool { activeTab == 2 && (appDelegate?.isAuthenticating ?? false) }
    @Namespace private var tabAnimation
    @State private var focusEnabled = FocusModeManager.shared.isEnabled
    var body: some View {
        HStack(spacing: 2) {
            TabBarItem(icon: "square.and.pencil", title: "Notes", isActive: activeTab == 0, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                activeTab = 0
            }
            TabBarItem(icon: "clock.arrow.circlepath", title: "History", isActive: activeTab == 1, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                activeTab = 1
            }
            TabBarItem(icon: "lock.shield", title: "Auth", isActive: activeTab == 2, namespace: tabAnimation) {
                activeTab = 2
            }
            TabBarItem(icon: "gearshape", title: "Settings", isActive: activeTab == 3, namespace: tabAnimation) {
                guard !isAuthLocked else { return }
                activeTab = 3
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
        .frame(height: 40)
        .padding(.horizontal, 6)
        .glassEffect(.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.05))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: activeTab)
    }

}

struct TabBarItem: View {
    let icon: String
    let title: String
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(.white.opacity(isActive ? 0.85 : 0.25))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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
        }
        .buttonStyle(.plain)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.clear)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.04))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
        }
    }
}
