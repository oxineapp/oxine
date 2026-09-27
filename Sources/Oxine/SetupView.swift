import SwiftUI
import PanelKit
import NotchKit
import SousKit
import TemperKit

/// The first-run tour. It sets things up rather than describing them: the
/// color and size you pick change the panel as you pick, the notch step puts
/// real notices on the notch, and the last step hands you the real tab bar.
/// Steps: Hello, Look, [Notch], Notes, Battery and fans, Apps, Tabs. The
/// notch step is only on Macs with a notch.
struct SetupView: View {
    @State var currentStep = 0
    @State var isLoading = false
    /// Tracks nav direction so Back slides opposite to Next.
    @State private var goingForward = true
    var onComplete: () -> Void

    enum Step { case hello, look, notch, notes, power, apps, tabs }

    /// Only offer the notch on Macs that physically have one.
    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }
    private var steps: [Step] {
        hasNotch ? [.hello, .look, .notch, .notes, .power, .apps, .tabs] : [.hello, .look, .notes, .power, .apps, .tabs]
    }
    private var step: Step { steps[min(currentStep, steps.count - 1)] }
    private var lastStep: Int { steps.count - 1 }

    /// Steps slide along the nav direction: Next enters from the right, Back from the left.
    private var stepTransition: AnyTransition {
        goingForward
            ? .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                          removal: .opacity.combined(with: .move(edge: .leading)))
            : .asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)),
                          removal: .opacity.combined(with: .move(edge: .trailing)))
    }

    /// True on the final step, where the tour card shrinks to the bottom and the
    /// real editable tab bar leaks through on the glass panel above it.
    private var leaking: Bool { step == .tabs }

    var body: some View {
        Group {
            if leaking { tabLeakLayout } else { standardLayout }
        }
        // Solid for the normal steps; clear on the last step so the panel's glass
        // (and the editable bar laid on it) shows through above the shrunken card.
        .background { if leaking { Color.clear } else { TourBackdrop() } }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: leaking)
    }

    // MARK: layouts

    private var standardLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                progressBar
                skipButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ZStack {
                stepView
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navButtons
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 8)
        }
    }

    @ViewBuilder private var stepView: some View {
        switch step {
        case .hello: TourHello(hasNotch: hasNotch)
        case .look: TourLook()
        case .notch: TourNotch()
        case .notes: TourNotes(isLoading: $isLoading)
        case .power: TourPower()
        case .apps: TourApps(hasNotch: hasNotch)
        case .tabs: EmptyView()
        }
    }

    private var tabLeakLayout: some View {
        ZStack(alignment: .bottom) {
            // The editable bar sits at the TRUE top of the panel — where the tab
            // bar actually lives — with the tray in the revealed space below it.
            // This is the panel leaking through, not a widget boxed in a card.
            VStack(spacing: 0) {
                TabEditor()
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                Spacer(minLength: 0)
            }
            .transition(.opacity)

            // The tour card, shrunk to the bottom and fading in at its top edge so
            // the panel above shows through — the "decrease in height + leak" look.
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("Your tabs")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("Drag them into the bar above, in the order you like.")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                progressBar
                navButtons
            }
            .padding(.horizontal, 22)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(
                TourBackdrop().mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black, location: 1.0)]),
                        startPoint: .top, endPoint: .bottom)
                )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: shared pieces

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(0..<steps.count, id: \.self) { index in
                Capsule()
                    .fill(index <= currentStep ? Color.panelAccent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .shadow(color: Color.panelAccent.opacity(index == currentStep ? 0.5 : 0), radius: 3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
    }

    private var skipButton: some View {
        Button(action: {
            SetupManager.shared.markSetupComplete()
            onComplete()
        }) {
            Text("Skip")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var navButtons: some View {
        HStack(spacing: 10) {
            if currentStep > 0 {
                Button(action: {
                    goingForward = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { currentStep -= 1 }
                }) {
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundColor(.white.opacity(0.75))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Button(action: advance) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small).transition(.scale.combined(with: .opacity))
                    }
                    Text(nextTitle)
                        .font(.system(size: 13, weight: .bold))
                        .contentTransition(.opacity)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.panelAccent.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.panelAccent.opacity(0.35), lineWidth: 0.5))
            .disabled(isLoading)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentStep)
    }

    private var nextTitle: String {
        switch step {
        case .hello: "Set it up"
        case .tabs: "Done"
        default: "Next"
        }
    }

    private func advance() {
        if currentStep < lastStep {
            goingForward = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { currentStep += 1 }
        } else {
            SetupManager.shared.markSetupComplete()
            TourNotch.post(NotchNotice(icon: "checkmark.circle.fill", tint: .panelAccent, title: "You're all set",
                                       subtitle: "Oxine is in the menu bar", iconMotion: .bounce, duration: 5,
                                       group: "tour.hello"))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { onComplete() }
        }
    }
}

// MARK: - Pieces

/// The tour's background: near-black with a faint glow of the accent at the
/// top, so picking a color on the Look step washes the whole tour.
private struct TourBackdrop: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Color(red: 0.06, green: 0.06, blue: 0.08)
            .overlay(alignment: .top) {
                RadialGradient(colors: [theme.accent.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 320)
                    .frame(height: 320)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: theme.accent)
    }
}

/// A step's title block: a glowing icon, the title, one line of what it's for.
private struct TourHeader: View {
    var icon: String
    var image: NSImage? = nil
    var title: String
    var subtitle: String
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.14))
                    .overlay(Circle().strokeBorder(theme.accent.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: theme.accent.opacity(0.35), radius: 12)
                if let image {
                    Image(nsImage: image).resizable().frame(width: 28, height: 28)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }
            .frame(width: 48, height: 48)
            .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A quiet rounded group.
private struct TourCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

/// A small section label inside a step.
private struct TourLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
    }
}

/// Every step scrolls if the panel is too short for it, and otherwise sits
/// at the top with the same margins.
private struct TourPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) { content }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A done state: green check and a line.
private struct TourDone: View {
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
    }
}

/// A small capsule button in the accent.
private struct TourButton: View {
    var title: String
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.panelAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.panelAccent.opacity(0.13)))
            .overlay(Capsule().strokeBorder(Color.panelAccent.opacity(0.28), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Hello

/// What Oxine is, as the things it holds popping in one after another.
private struct TourHello: View {
    var hasNotch: Bool
    @State private var shown = 0
    @State private var glow = false

    private var things: [(String, String)] {
        var all = [("doc.on.clipboard", "Clipboard"), ("note.text", "Notes"), ("lock.shield", "2FA codes"),
                   ("terminal", "Scripts"), ("heart.badge.bolt", "Battery care"), ("fanblades.fill", "Fans")]
        if hasNotch { all.append(("macbook.gen2", "The notch")); all.append(("square.grid.2x2", "Apps")) }
        return all
    }

    var body: some View {
        TourPage {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.panelAccent.opacity(glow ? 0.55 : 0.2), radius: glow ? 22 : 10)
                    .scaleEffect(glow ? 1.03 : 1)
                Text("Welcome to Oxine")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.white)
                Text("The things you reach for all day, one click away in the menu bar.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(things.enumerated()), id: \.offset) { index, thing in
                    HStack(spacing: 9) {
                        Image(systemName: thing.0)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.panelAccent)
                            .frame(width: 18)
                        Text(thing.1)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                    .opacity(index < shown ? 1 : 0)
                    .scaleEffect(index < shown ? 1 : 0.85)
                    .offset(y: index < shown ? 0 : 8)
                }
            }
            .padding(.top, 4)
        }
        .task {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
            for i in 1...things.count {
                try? await Task.sleep(for: .milliseconds(i == 1 ? 250 : 90))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { shown = i }
            }
        }
    }
}

// MARK: - Look

/// Color and size, applied as you pick: the accent recolors the tour, and
/// the size resizes the panel it's in.
private struct TourLook: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("panelSizePreset", store: PanelKit.settingsDefaults) private var sizePreset = PanelSize.standard.rawValue

    var body: some View {
        TourPage {
            TourHeader(icon: "paintpalette.fill", title: "Make it look right",
                       subtitle: "Pick a color and a size. Oxine changes as you pick.")
            VStack(spacing: 8) {
                TourLabel(text: "Color")
                TourCard {
                    HStack(spacing: 0) {
                        swatch(nil)
                        ForEach(AccentPalette.swatches, id: \.self) { hex in swatch(hex) }
                    }
                }
            }
            VStack(spacing: 8) {
                TourLabel(text: "Size")
                HStack(spacing: 8) {
                    ForEach([PanelSize.compact, .standard, .tall]) { size in sizeCard(size) }
                }
            }
            Text("Both are in Settings later, with a custom size too.")
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    /// A color dot; nil is "follow macOS".
    private func swatch(_ hex: String?) -> some View {
        let selected = hex.map { !theme.isSystem && theme.mode == $0 } ?? theme.isSystem
        let color = hex.map { Color(hex: $0) } ?? Color(nsColor: .controlAccentColor)
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) { theme.setMode(hex ?? ThemeManager.systemSentinel) }
        } label: {
            ZStack {
                Circle().fill(color)
                if hex == nil {
                    Image(systemName: "apple.logo").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(width: 24, height: 24)
            .padding(3)
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
            .scaleEffect(selected ? 1.08 : 1)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "Match macOS" : "")
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }

    /// A size as a little panel drawn to scale.
    private func sizeCard(_ size: PanelSize) -> some View {
        let selected = sizePreset == size.rawValue
        let dims = size.presetSize ?? .zero
        let scale: CGFloat = 0.085
        return Button {
            sizePreset = size.rawValue
            NotificationCenter.default.post(name: .panelSizeChanged, object: nil)
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.panelAccent.opacity(0.25) : Color.white.opacity(0.06))
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.white.opacity(selected ? 0.5 : 0.2))
                            .frame(width: dims.width * scale * 0.55, height: 2.5).padding(.top, 5)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(selected ? Color.panelAccent : Color.white.opacity(0.2), lineWidth: 1))
                    .frame(width: dims.width * scale, height: dims.height * scale)
                    .frame(height: 58, alignment: .bottom)
                VStack(spacing: 1) {
                    Text(size.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(selected ? 0.95 : 0.7))
                    Text("\(Int(dims.width))×\(Int(dims.height))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.panelAccent.opacity(0.1) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.panelAccent.opacity(0.45) : Color.white.opacity(0.07), lineWidth: selected ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// MARK: - Notch

/// The notch, shown rather than described: a drawing of it, the switch, and
/// buttons that put real notices on the real notch. Arriving here waves from
/// up there.
struct TourNotch: View {
    @AppStorage("notchEnabled", store: UserDefaults(suiteName: "com.oxine.settings")) private var notchEnabled = true
    @State private var waved = false

    /// Posts to the notch only while it's on (off, a notice would float instead).
    static func post(_ notice: NotchNotice, onAction: ((String) -> Void)? = nil) {
        let on = UserDefaults(suiteName: "com.oxine.settings")?.object(forKey: "notchEnabled") as? Bool ?? true
        guard on else { return }
        var notice = notice
        notice.source = "oxine.tour"
        notice.sourceName = "Tour"
        NotchNotices.shared.post(notice, onAction: onAction)
    }

    var body: some View {
        TourPage {
            TourHeader(icon: "macbook.gen2", title: "Meet the notch",
                       subtitle: "What's playing, your coding agents and notices, around the camera. Point at it to open it.")
            MiniNotch(on: notchEnabled)
                .padding(.vertical, 2)
            TourCard {
                Toggle(isOn: $notchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use the notch")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(notchEnabled ? "Look up: it's saying hi." : "You can turn it on in Settings any time.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(.switch)
                .tint(.panelAccent)
            }
            .onChange(of: notchEnabled) { _, on in
                NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
                if on {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { wave() }
                }
            }
            if notchEnabled {
                VStack(spacing: 8) {
                    TourLabel(text: "Try a notice")
                    HStack(spacing: 8) {
                        TourButton(title: "Short one", icon: "bell.fill") {
                            Self.post(NotchNotice(icon: "bell.fill", tint: .panelAccent, title: "Doorbell",
                                                  iconMotion: .bounce,
                                                  actions: [.init(id: "ok", title: "Nice", role: .primary)],
                                                  duration: 8, group: "tour.try"))
                        }
                        TourButton(title: "One with more", icon: "text.alignleft") {
                            Self.post(NotchNotice(icon: "sparkles", tint: .panelAccent, title: "Notices can say more",
                                                  detail: "Point at me to read the rest. One with buttons that you miss waits behind the bell in the open notch.",
                                                  actions: [.init(id: "ok", title: "Got it", role: .primary)],
                                                  duration: 10, group: "tour.more"))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notchEnabled)
        .onAppear {
            guard !waved else { return }
            waved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { wave() }
        }
    }

    private func wave() {
        Self.post(NotchNotice(icon: "hand.wave.fill", tint: .panelAccent, title: "Hi, up here",
                              iconMotion: .wiggle, duration: 5, group: "tour.hello", haptic: true))
    }
}

/// A drawing of the top of the screen: the notch with album art in one ear
/// and the music bars in the other, dimmed when the notch is off.
private struct MiniNotch: View {
    var on: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.panelAccent.opacity(0.35), Color(red: 0.1, green: 0.1, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            // The menu bar.
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: 18)
            HStack(spacing: 0) {
                if on {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.55, green: 0.25, blue: 0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 13, height: 13)
                        .padding(.leading, 9)
                        .transition(.opacity.combined(with: .scale))
                }
                Spacer(minLength: 64)
                if on {
                    Bars().padding(.trailing, 9).transition(.opacity.combined(with: .scale))
                }
            }
            .frame(width: on ? 150 : 80, height: 22)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous).fill(.black))
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(on ? 1 : 0.6)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: on)
    }

    private struct Bars: View {
        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule()
                            .fill(Color.panelAccent)
                            .frame(width: 2.5, height: 4 + 8 * abs(sin(t * (2.2 + Double(i) * 0.7) + Double(i))))
                    }
                }
                .frame(height: 13)
            }
        }
    }
}

// MARK: - Notes

/// Where notes live and what opens them, plus justtype sync.
private struct TourNotes: View {
    @Binding var isLoading: Bool
    @State private var vaultReady = false
    @State private var errorMessage: String?
    @StateObject private var sync = JustTypeSyncManager()
    /// Re-read NotesEditor when the choice changes (the Obsidian row comes and goes).
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) private var editorBundleID = ""
    @State private var editorTick = 0

    var body: some View {
        TourPage {
            TourHeader(icon: "note.text", image: NotesEditor.appIcon(), title: "Your notes",
                       subtitle: "Plain Markdown files in \(NotesLocation.displayPath), opened in the app you like.")
            VStack(spacing: 8) {
                TourLabel(text: "Opens in")
                EditorChip()
                if NotesEditor.isObsidian { obsidianRow }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: 8) {
                TourLabel(text: "Sync")
                TourCard {
                    HStack(spacing: 11) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.panelAccent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("justtype")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text(sync.isConfigured ? sync.status : "Your notes as private slates, on the web and your phone. Allow private slate access when it asks.")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if sync.isConfigured {
                            TourDone(text: "Connected")
                        } else {
                            TourButton(title: sync.isSigningIn ? "Connecting…" : "Connect") { sync.signIn() }
                                .disabled(sync.isSigningIn)
                        }
                    }
                }
            }
        }
        .id(editorTick)
        .onReceive(NotificationCenter.default.publisher(for: .notesEditorChanged)) { _ in editorTick &+= 1 }
    }

    private var obsidianRow: some View {
        TourCard(padding: 10) {
            HStack {
                Text("Obsidian gets a vault with tags and links.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer(minLength: 6)
                if vaultReady {
                    TourDone(text: "Vault ready")
                } else {
                    TourButton(title: isLoading ? "Setting up…" : "Set up vault", action: setupObsidian)
                        .disabled(isLoading)
                }
            }
        }
    }

    private func setupObsidian() {
        errorMessage = nil
        isLoading = true
        ObsidianVaultManager.shared.createVaultInObsidian { success, message in
            DispatchQueue.main.async {
                isLoading = false
                if success { vaultReady = true } else { errorMessage = message }
            }
        }
    }
}

// MARK: - Battery and fans

/// Sous and Temper side by side, each with its helper's state and the one
/// button it needs.
private struct TourPower: View {
    @ObservedObject private var sous = SousManager.shared
    @ObservedObject private var temper = TemperManager.shared

    var body: some View {
        TourPage {
            TourHeader(icon: "bolt.heart.fill", title: "Battery and fans",
                       subtitle: "Sous stops charging at a limit to keep the battery healthy. Temper watches heat and runs the fans.")
            VStack(spacing: 8) {
                row(icon: "heart.badge.bolt", tint: AppArt.tint(for: "oxine.sous"), name: "Sous",
                    line: sousLine) { sousAction }
                row(icon: "fanblades.fill", tint: AppArt.tint(for: "oxine.temper"), name: "Temper",
                    line: temperLine) { temperAction }
            }
            Text("Each control needs a small helper. macOS asks for your password once for each.")
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            sous.refreshNow()
            temper.setViewActive(true)
            temper.refreshNow()
        }
        .onDisappear { temper.setViewActive(false) }
    }

    private func row<Action: View>(icon: String, tint: Color, name: String, line: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        TourCard {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Text(line)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                action()
            }
        }
    }

    private var sousLine: String {
        switch sous.helper.installState {
        case .unsupported:
            return BatteryReader.isAppleSilicon ? "No battery here, so nothing to do." : "Needs an Apple silicon Mac."
        case .installed: return "Set your limit in the Sous tab."
        case .installing: return "Enter your password in the prompt."
        case .failed(let message): return message
        case .notInstalled: return "Caps charging, holds it there, pauses when hot."
        }
    }

    @ViewBuilder private var sousAction: some View {
        switch sous.helper.installState {
        case .unsupported: EmptyView()
        case .installed: TourDone(text: "Ready")
        case .installing: ProgressView().controlSize(.small)
        case .notInstalled, .failed:
            TourButton(title: "Install") { Task { await sous.helper.install(); sous.refreshNow() } }
        }
    }

    private var temperLine: String {
        guard temper.fansPresent else { return "No fans to run here. Temps and load are in its tab." }
        switch temper.helper.installState {
        case .installed: return "Pick Smart, a curve or manual in the Temper tab."
        case .installing: return "Enter your password in the prompt."
        case .failed(let message): return message
        default: return "Readings work already; fan control needs the helper."
        }
    }

    @ViewBuilder private var temperAction: some View {
        if !temper.fansPresent {
            TourDone(text: "Ready")
        } else {
            switch temper.helper.installState {
            case .installed: TourDone(text: "Ready")
            case .installing: ProgressView().controlSize(.small)
            default: TourButton(title: "Install") { Task { await temper.helper.install(); temper.refreshNow() } }
            }
        }
    }
}

// MARK: - Apps

/// The apps you can add, as a short list with Get right on each, and the
/// ones already in as one line.
private struct TourApps: View {
    var hasNotch: Bool
    @ObservedObject private var manager = AppsManager.shared

    private var extras: [BundledApps.Entry] {
        (hasNotch ? ["oxine.screenlyrics", "oxine.earson", "oxine.decant", "oxine.fngestures"]
                  : ["oxine.earson", "oxine.decant", "oxine.fngestures"])
            .compactMap(BundledApps.entry)
    }
    private var builtins: [OxApp] {
        ["oxine.sous", "oxine.temper", "oxine.caffeine", "oxine.focus"].compactMap(manager.app)
    }

    var body: some View {
        TourPage {
            TourHeader(icon: "square.grid.2x2.fill", title: "Apps",
                       subtitle: "Extras with their own page. Get one now, or later in Settings → Apps.")
            VStack(spacing: 0) {
                ForEach(Array(extras.enumerated()), id: \.element.manifest.id) { index, entry in
                    if index > 0 { Divider().overlay(Color.white.opacity(0.04)).padding(.leading, 56) }
                    appRow(entry)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            if !builtins.isEmpty {
                VStack(spacing: 8) {
                    TourLabel(text: "Already in")
                    HStack(spacing: 6) {
                        ForEach(builtins) { app in
                            HStack(spacing: 5) {
                                Image(systemName: app.icon).font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(AppArt.tint(for: app.id).opacity(1))
                                Text(app.name).font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func appRow(_ entry: BundledApps.Entry) -> some View {
        let m = entry.manifest
        let tint = AppArt.tint(for: m.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: m.icon ?? "shippingbox").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text(m.tagline ?? "")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            StoreActionButton(action: action(entry))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func action(_ entry: BundledApps.Entry) -> StoreAction {
        let installed = manager.app(entry.manifest.id) != nil
        if entry.manifest.id == "oxine.fngestures", installed, !FnGestureEngine.accessibilityGranted {
            return .grant { FnGestureEngine.requestAccessibility() }
        }
        if installed { return .installed }
        return .get {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { manager.installBundled(entry) }
        }
    }
}
