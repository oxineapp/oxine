import SwiftUI
import SousShared

/// The Sous tab: battery charge-health control. Adapts between "needs setup"
/// (install / approve the helper), "unsupported" (Intel / no battery), and the
/// live control surface.
struct SousView: View {
    @ObservedObject var sous: SousManager
    @State private var alert: String?
    private var accent: Color { .oxineAccent }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                switch sous.helper.installState {
                case .unsupported: unsupportedCard
                case .notInstalled, .failed: setupCard
                case .installing: installingCard
                case .installed:
                    if sous.metrics.hasBattery { controls }
                    else { unsupportedCard }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .onAppear { sous.setViewActive(true); sous.refreshNow() }
        .onDisappear { sous.setViewActive(false) }
        .alert("Not possible", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alert ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("\(sous.displayPercent)%")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .contentTransition(.numericText())
            HStack(spacing: 8) {
                statePill
                if sous.tempC > 0 {
                    Label(String(format: "%.0f°C", sous.tempC), systemImage: "thermometer.medium")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(sous.status.heatThrottled ? .orange : .white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statePill: some View {
        let (label, color, icon) = stateAppearance
        return Label(label, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var stateAppearance: (String, Color, String) {
        switch sous.displayState {
        case .off:         return ("Charging normally", .white.opacity(0.5), "bolt")
        case .charging:    return ("Charging", accent, "bolt.fill")
        case .holding:     return ("Held at limit", .green, "pause.fill")
        case .sailing:     return ("Sailing", .green, "sailboat.fill")
        case .discharging: return ("Discharging", .orange, "arrow.down.right")
        case .toppingUp:   return ("Topping up", accent, "arrow.up.to.line")
        case .heatProtect: return ("Heat protection", .orange, "thermometer.high")
        case .unplugged:   return ("On battery", .white.opacity(0.6), "battery.75")
        }
    }

    // MARK: Live controls

    private var controls: some View {
        VStack(spacing: 16) {
            limiterCard
            actionRow
            powerFlowCard
        }
    }

    private var limiterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: Binding(get: { sous.config.enabled }, set: { sous.setEnabled($0) })) {
                    Text("Limit charging").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.switch)
                .tint(accent)
            }
            ChargeLimitSlider(
                limit: Binding(get: { sous.config.chargeLimit }, set: { sous.setLimit($0) }),
                sailingRange: sous.config.sailingRange,
                currentCharge: sous.displayPercent,
                enabled: sous.config.enabled
            )
            HStack {
                Text("Hold at")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                Spacer()
                stepper
            }
            if sous.config.sailingRange > 0 {
                Text("Resumes charging at \(max(sous.config.chargeLimit - sous.config.sailingRange, 0))% · sailing \(sous.config.sailingRange)%")
                    .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(sous.config.enabled ? 1 : 0.55)
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            roundButton("minus") { sous.setLimit(sous.config.chargeLimit - 1) }
            Text("\(sous.config.chargeLimit)%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundColor(.white)
                .frame(width: 46)
            roundButton("plus") { sous.setLimit(sous.config.chargeLimit + 1) }
        }
        .disabled(!sous.config.enabled)
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if sous.config.topUpActive {
                actionButton("Stop top-up", "xmark", accent) { sous.cancelTransient() }
            } else {
                actionButton("Top Up", "arrow.up.to.line", accent) { if let m = sous.topUp() { alert = m } }
            }
            if sous.config.dischargeActive {
                actionButton("Stop discharge", "xmark", .orange) { sous.cancelTransient() }
            } else {
                actionButton("Discharge", "arrow.down.right", .orange) { if let m = sous.discharge() { alert = m } }
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    private var powerFlowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power Flow").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            PowerFlowView(metrics: sous.metrics, state: sous.displayState)
                .frame(height: 110)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Setup / status cards

    private func card<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundColor(tint)
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        card(icon: "bolt.heart", tint: accent) {
            Text("Set up Sous")
                .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            Text("Sous keeps your battery healthy by capping how much it charges. It installs a small background helper that controls charging — macOS will ask you to allow it.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            if case .failed(let msg) = sous.helper.installState {
                Text(msg).font(.system(size: 10.5)).foregroundColor(.orange).multilineTextAlignment(.center)
            }
            Button {
                Task { await sous.helper.install(); sous.refreshNow() }
            } label: {
                Text("Install helper")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(accent.opacity(0.14)))
            }.buttonStyle(.plain)
        }
    }

    private var installingCard: some View {
        card(icon: "lock.shield", tint: accent) {
            ProgressView().controlSize(.large)
            Text("Authorizing…")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Text("Enter your Mac password in the prompt to install the battery helper. This happens once.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var unsupportedCard: some View {
        card(icon: "exclamationmark.triangle", tint: .white.opacity(0.4)) {
            Text(BatteryReader.isAppleSilicon ? "No battery detected" : "Apple Silicon only")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            Text(BatteryReader.isAppleSilicon
                 ? "Sous needs a MacBook battery to manage."
                 : "Sous controls charging through Apple Silicon hardware and isn’t available on Intel Macs.")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
    }
}

/// The signature charge-limit control: a track filled to the limit, a draggable
/// knob, the live charge level as a tick, and a dashed marker at the sailing
/// lower bound (where charging resumes).
struct ChargeLimitSlider: View {
    @Binding var limit: Int
    var sailingRange: Int
    var currentCharge: Int
    var enabled: Bool
    private var accent: Color { .oxineAccent }

    private let lo = SafetyFloors.minChargeLimit   // 50
    private let hi = 100

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobX = x(for: limit, width: w)
            let lowerX = x(for: max(limit - sailingRange, lo), width: w)
            let chargeX = x(for: min(max(currentCharge, 0), 100), width: w)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10)).frame(height: 10)
                Capsule().fill(enabled ? accent.opacity(0.85) : .white.opacity(0.25))
                    .frame(width: max(knobX, 10), height: 10)
                // Sailing lower-bound marker.
                if sailingRange > 0 {
                    Rectangle().fill(.white.opacity(0.5))
                        .frame(width: 2, height: 16)
                        .position(x: lowerX, y: geo.size.height / 2)
                }
                // Live charge tick.
                Circle().fill(.white).frame(width: 5, height: 5)
                    .position(x: chargeX, y: geo.size.height / 2)
                // Knob.
                Circle().fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard enabled else { return }
                let frac = min(max(v.location.x / w, 0), 1)
                limit = Int((Double(lo) + frac * Double(hi - lo)).rounded())
            })
        }
        .frame(height: 24)
    }

    private func x(for value: Int, width: CGFloat) -> CGFloat {
        let frac = Double(min(max(value, lo), hi) - lo) / Double(hi - lo)
        return CGFloat(frac) * width
    }
}
