import SwiftUI
import PanelKit
import SousShared
import UniformTypeIdentifiers

/// The Sous tab: battery charge-health control. Adapts between "needs setup"
/// (install / approve the helper), "unsupported" (Intel / no battery), and the
/// live control surface.
public struct SousView: View {
    @ObservedObject var sous: SousManager
    @State private var alert: String?
    @State private var draggingWidget: SousManager.SousWidget?
    @State private var showCalibInfo = false
    private var accent: Color { .panelAccent }

    public init(sous: SousManager) { self.sous = sous }

    public var body: some View {
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
        HStack(spacing: 8) {
            statePill
            Text("\(sous.displayPercent)%")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.85))
                .contentTransition(.numericText())
            if sous.tempC > 0 {
                Label(String(format: "%.0f°C", sous.tempC), systemImage: "thermometer.medium")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(sous.status.heatThrottled ? .orange : .white.opacity(0.5))
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
        case .calibrating: return ("Calibrating", accent, "arrow.triangle.2.circlepath")
        }
    }

    // MARK: Live controls

    private var controls: some View {
        VStack(spacing: 16) {
            limiterCard
                .disabled(sous.isCalibrating)
            // Power Flow is fixed (no casing, not reorderable).
            powerFlowSection
            // Rearrangeable cards — drag any one by its grip to reorder.
            ForEach(sous.widgetOrder) { widget in
                widgetCard(widget)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.22))
                            .padding(11)
                    }
                    .opacity(draggingWidget == widget ? 0.35 : 1)
                    .onDrag {
                        draggingWidget = widget
                        return NSItemProvider(object: widget.rawValue as NSString)
                    }
                    .onDrop(of: [.text],
                            delegate: WidgetDropDelegate(item: widget, sous: sous, dragging: $draggingWidget))
            }
        }
    }

    @ViewBuilder private func widgetCard(_ widget: SousManager.SousWidget) -> some View {
        switch widget {
        case .battery:     batteryDetailCard
        case .calibration: calibrationCard
        case .stats:       statsCard
        }
    }

    /// AlDente-style compact limiter: a `Limit: X%` pill (tap to toggle) with the
    /// Top Up / Discharge actions on the right, above a prominent charge slider.
    private var limiterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { sous.setEnabled(!sous.config.enabled) } label: {
                    Text(sous.config.enabled ? "Limit: \(sous.config.chargeLimit)%" : "Limit: Off")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(sous.config.enabled ? "Turn charge limiting off" : "Turn charge limiting on")
                Spacer()
                if sous.config.topUpActive {
                    miniAction("Stop", "xmark", accent) { sous.cancelTransient() }
                } else {
                    miniAction("Top Up", "plus", accent) { if let m = sous.topUp() { alert = m } }
                }
                if sous.config.dischargeActive {
                    miniAction("Stop", "xmark", .orange) { sous.cancelTransient() }
                } else {
                    miniAction("Discharge", "arrow.down.right", .orange) { if let m = sous.discharge() { alert = m } }
                }
            }
            ChargeLimitSlider(
                // Dragging always sets the limit and (re-)enables limiting.
                limit: Binding(get: { sous.config.chargeLimit },
                               set: { sous.setLimit($0); sous.setEnabled(true) }),
                sailingRange: sous.config.sailingRange,
                currentCharge: sous.displayPercent,
                active: sous.config.enabled,
                fillTint: sliderTint,
                showPlug: sliderShowsPlug
            )
            if sous.config.enabled, sous.config.sailingRange > 0 {
                Text("Resumes charging at \(max(sous.config.chargeLimit - sous.config.sailingRange, 0))% · sailing \(sous.config.sailingRange)%")
                    .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Liquid-glass fill tint for the charge bar, by what the battery is doing:
    /// blue while filling, orange while discharging, green once held at the point,
    /// neutral on battery.
    private var sliderTint: Color {
        switch sous.displayState {
        case .charging, .toppingUp:  return accent          // filling → blue
        case .discharging:           return .orange
        case .heatProtect:           return .orange
        case .holding, .sailing:     return .green          // reached the point
        case .calibrating, .off:     return accent
        case .unplugged:             return .white.opacity(0.6)   // battery mode
        }
    }

    /// Show the plug glyph in the fill only while it's actively charging.
    private var sliderShowsPlug: Bool {
        switch sous.displayState {
        case .charging, .toppingUp: return true
        default:                    return false
        }
    }

    private func miniAction(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(color.opacity(0.14)))
                .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: Battery-life detail

    private var batteryDetailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            HStack(spacing: 0) {
                detailMetric(title: estimateTitle, value: estimateValue)
                detailDivider
                detailMetric(title: "Health", value: healthValue)
                detailDivider
                detailMetric(title: "Cycles", value: sous.lifeMetrics.cycleCount > 0 ? "\(sous.lifeMetrics.cycleCount)" : "—")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detailMetric(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundColor(.white)
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var detailDivider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 28)
    }

    /// Header changes with the power direction: time left, time to full, or a
    /// neutral label when Sous is holding (no meaningful projection).
    private var estimateTitle: String {
        if sous.lifeMetrics.secondsToEmpty != nil { return "Time left" }
        if sous.lifeMetrics.secondsToFull != nil { return "To full" }
        return "Estimate"
    }

    private var estimateValue: String {
        if let s = sous.lifeMetrics.secondsToEmpty { return Self.duration(s) }
        if let s = sous.lifeMetrics.secondsToFull { return Self.duration(s) }
        if sous.lifeMetrics.externalConnected { return "On AC" }
        return "—"
    }

    private var healthValue: String {
        guard let h = sous.lifeMetrics.healthFraction else { return "—" }
        return "\(Int((h * 100).rounded()))%"
    }

    /// Seconds → compact "4h 30m" / "45m".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(accent)
                Text("Calibration").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Button { showCalibInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("What is calibration?")
                .popover(isPresented: $showCalibInfo, arrowEdge: .bottom) { calibInfoPopover }
                Spacer()
                if !sous.isCalibrating, let last = sous.lastCalibration {
                    Text(last.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                }
            }
            if sous.isCalibrating { calibrationRunning } else { calibrationIdle }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var calibrationIdle: some View {
        // The step flow only appears once a run starts; idle is just the button.
        Button {
            if let m = sous.startCalibration() { alert = m }
        } label: {
            Label("Calibrate now", systemImage: "play.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Capsule().fill(accent.opacity(0.12)))
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    /// The five-phase cycle as a horizontal step flow. The current phase is
    /// highlighted in green; before a run starts it's shown dimmed as a preview.
    /// The last step's target is the user's own charge limit.
    private var calibrationFlow: some View {
        let steps: [(phase: CalibrationPhase, title: String, value: String)] = [
            (.chargingToFull,   "Charge",    "100%"),
            (.dischargingToLow, "Discharge", "\(SafetyFloors.calibrationLowTarget)%"),
            (.recharging,       "Charge",    "100%"),
            (.holdingAtFull,    "Hold",      "1h"),
            (.restoring,        "Discharge", "\(sous.config.chargeLimit)%"),
        ]
        let activeIndex = steps.firstIndex { $0.phase == sous.calibrationPhase }
        return HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                let isActive = (i == activeIndex)
                VStack(spacing: 1) {
                    Text(step.title)
                    Text(step.value).monospacedDigit()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundColor(isActive ? .green : .white.opacity(0.4))
                .padding(.horizontal, 6).padding(.vertical, 5)
                .modifier(StepGlassHighlight(active: isActive))
                .frame(maxWidth: .infinity)
                if i < steps.count - 1 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
        }
    }

    /// Explainer shown from the calibration card's ⓘ button.
    private var calibInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Battery calibration", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
            Text("Calibration runs one full cycle — charge to 100%, drain to \(SafetyFloors.calibrationLowTarget)%, recharge to 100%, then hold — so macOS re-learns your battery's true capacity. The percentage and time-remaining estimates drift over months of partial charging; a calibration corrects them.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
            Text("It takes several hours. Keep the charger connected the whole time; your charge limit is ignored until it finishes. Once a month or two is plenty.")
                .font(.system(size: 11.5)).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var calibrationRunning: some View {
        VStack(alignment: .leading, spacing: 12) {
            calibrationFlow
            HStack(spacing: 6) {
                Text(sous.calibrationPhase.label)
                    .font(.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.7))
                Spacer()
                if let secs = sous.status.calibrationHoldRemaining {
                    Label(Self.duration(Double(secs)), systemImage: "timer")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
                }
            }
            Button {
                sous.cancelCalibration()
            } label: {
                Label("Stop calibration", systemImage: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
            }.buttonStyle(.plain)
        }
    }

    /// Fixed, casing-less Power Flow. No glass card around it (avoids the muddy
    /// glass-on-glass look) and it isn't part of the reorderable set.
    private var powerFlowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power Flow").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            PowerFlowView(metrics: sous.metrics, state: sous.displayState)
                .frame(height: 110)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Stats

    private var statsCard: some View {
        let m = sous.lifeMetrics
        return VStack(alignment: .leading, spacing: 12) {
            Text("Stats").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            statGroup("Battery", [
                ("bolt.fill", "Current", String(format: "%.2f A", abs(m.amperageA))),
                ("powerplug.fill", "Voltage", m.voltageV > 0 ? String(format: "%.2f V", m.voltageV) : nil),
                ("bolt.circle.fill", "Power", String(format: "%.2f W", abs(m.batteryPowerW))),
                ("laptopcomputer", "System load", m.systemLoadW.map { String(format: "%.2f W", $0) }),
                ("leaf.fill", "Low Power Mode", m.lowPowerMode ? "Enabled" : "Disabled"),
                ("number", "Serial", m.batterySerial),
            ])
            if m.externalConnected {
                statGroup("Power adapter", [
                    ("bolt.fill", "Current", m.adapterCurrentA > 0 ? String(format: "%.2f A", m.adapterCurrentA) : nil),
                    ("powerplug.fill", "Voltage", m.adapterVoltageV > 0 ? String(format: "%.2f V", m.adapterVoltageV) : nil),
                    ("bolt.circle.fill", "Power", adapterPowerText(m)),
                    ("tag.fill", "Name", m.adapterName),
                    ("building.2.fill", "Manufacturer", m.adapterManufacturer),
                    ("number", "Serial", m.adapterSerial),
                ])
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func adapterPowerText(_ m: BatteryMetrics) -> String? {
        guard let inW = m.adapterInputW else { return nil }
        if m.adapterMaxWatts > 0 { return String(format: "%.1f W of %.0f W", inW, m.adapterMaxWatts) }
        return String(format: "%.1f W", inW)
    }

    private func statGroup(_ title: String, _ rows: [(String, String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase).tracking(0.6)
                .padding(.bottom, 5)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = row.2 {
                    HStack(spacing: 8) {
                        Image(systemName: row.0)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 16, alignment: .center)
                        Text(row.1).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.55))
                        Spacer(minLength: 12)
                        Text(value)
                            .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
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

/// Liquid Glass pill behind the active calibration step — a green-tinted glass
/// chip that refracts the card beneath it, instead of a flat fill.
private struct StepGlassHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.glassEffect(.regular.tint(.green.opacity(0.32)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content
        }
    }
}

/// Reorders the Sous cards as one is dragged over another. Mutates the manager's
/// persisted `widgetOrder` live on hover; clears the drag state on drop.
private struct WidgetDropDelegate: DropDelegate {
    let item: SousManager.SousWidget
    let sous: SousManager
    @Binding var dragging: SousManager.SousWidget?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = sous.widgetOrder.firstIndex(of: dragging),
              let to = sous.widgetOrder.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            sous.widgetOrder.move(fromOffsets: IndexSet(integer: from),
                                  toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// The signature charge-limit control: a track filled to the limit, a draggable
/// knob, the live charge level as a tick, and a dashed marker at the sailing
/// lower bound (where charging resumes).
struct ChargeLimitSlider: View {
    @Binding var limit: Int
    var sailingRange: Int
    var currentCharge: Int
    /// Whether limiting is on (dims the handle when off). The slider is always
    /// draggable, and dragging re-enables limiting (see the binding in limiterCard).
    var active: Bool
    /// Liquid-glass tint of the fill (= current battery), chosen by charge state.
    var fillTint: Color
    /// Show the plug glyph in the fill (while charging).
    var showPlug: Bool

    /// The track is an honest 0–100 battery gauge, so the current-charge fill
    /// reads true. The *limit* knob, however, can't be dragged below `minLimit`.
    private let lo = 0
    private let hi = 100
    private let minLimit = 25
    private let barH: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = geo.size.height / 2
            let chargeX = x(for: currentCharge, width: w)   // fill = current battery level
            let knobX = x(for: limit, width: w)             // handle = limit point
            let lowerX = x(for: max(limit - sailingRange, lo), width: w)
            let fillW = max(chargeX, barH)

            ZStack(alignment: .leading) {
                // Track.
                Capsule().fill(.white.opacity(0.10)).frame(height: barH)
                // Fill = current battery, as a Liquid Glass tile tinted by state.
                Color.clear
                    .frame(width: fillW, height: barH)
                    .glassEffect(.regular.tint(fillTint.opacity(0.55)), in: Capsule())
                // Plug glyph inside the fill while charging.
                if showPlug, fillW > 54 {
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .position(x: fillW / 2, y: cy)
                }
                // Sailing lower-bound: a dotted marker (where charging resumes).
                if active, sailingRange > 0 {
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(.white.opacity(0.55)).frame(width: 2.5, height: 2.5)
                        }
                    }
                    .position(x: lowerX, y: cy)
                }
                // Limit point handle — a tall light capsule.
                Capsule().fill(.white)
                    .frame(width: 9, height: barH + 16)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .opacity(active ? 1 : 0.6)
                    .position(x: min(max(knobX, 5), w - 5), y: cy)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let frac = min(max(v.location.x / w, 0), 1)
                // Map the drag across the full 0–100 track, then floor the limit at
                // minLimit (the left quarter of the track is a no-go for the knob).
                limit = max(minLimit, min(Int((frac * Double(hi)).rounded()), hi))
            })
        }
        .frame(height: barH + 18)
    }

    private func x(for value: Int, width: CGFloat) -> CGFloat {
        let frac = Double(min(max(value, lo), hi) - lo) / Double(hi - lo)
        return CGFloat(frac) * width
    }
}
