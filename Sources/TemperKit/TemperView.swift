import SwiftUI
import PanelKit
import TemperShared

/// The Temper tab: a thermal + performance dashboard that works on every Mac
/// (no daemon, no prompt), plus fan control on machines with controllable fans
/// (which installs a small privileged helper, like Sous).
///
/// Layout: a compact instrument header (temperature, thermal pressure, CPU
/// load), one global "Automatic control" widget that drives every fan together,
/// then live read-only RPM rows, then the sensor list.
public struct TemperView: View {
    @ObservedObject var temper: TemperManager
    @State private var draggingWidget: TemperManager.TemperWidget?
    @State private var showSensorPicker = false
    @State private var hoveringTemp = false
    /// Live value while dragging the temperament slider; committed (and pushed to
    /// the daemon) only on release, so a drag doesn't spam XPC/UserDefaults.
    @State private var temperamentDraft: Double?
    private var accent: Color { .panelAccent }

    public init(temper: TemperManager) { self.temper = temper }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header                              // fixed at the top
                if temper.displayFans.isEmpty {
                    passiveCard
                } else {
                    // Rearrangeable cards - drag any one by its grip to reorder,
                    // exactly like the Sous tab.
                    ForEach(temper.widgetOrder) { widget in
                        widgetCard(widget)
                            // Only the grip starts a reorder drag - attaching
                            // .onDrag to the whole card would swallow drags meant
                            // for the sliders / curve points inside it.
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.28))
                                    .padding(10)
                                    .contentShape(Rectangle())
                                    .onDrag {
                                        draggingWidget = widget
                                        return NSItemProvider(object: widget.rawValue as NSString)
                                    }
                                    .help("Drag to reorder")
                            }
                            .opacity(draggingWidget == widget ? 0.35 : 1)
                            .onDrop(of: [.text],
                                    delegate: TemperWidgetDrop(item: widget, temper: temper, dragging: $draggingWidget))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .onAppear { temper.setViewActive(true); temper.refreshNow() }
        .onDisappear { temper.setViewActive(false) }
    }

    /// One rearrangeable card. Sensors collapses to nothing when there are none.
    @ViewBuilder private func widgetCard(_ widget: TemperManager.TemperWidget) -> some View {
        switch widget {
        case .control: controlSection
        case .fans:    fansCard
        case .sensors: if !sensorRows.isEmpty { sensorsCard } else { EmptyView() }
        }
    }

    // MARK: Header - a flat instrument strip, no gauge

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 6) {
                tempPicker
                Spacer()
                statePill
            }
            VStack(spacing: 10) {
                meterRow(title: "Thermal pressure",
                         valueText: temper.thermalState.temperLabel,
                         segments: thermalLevel, tint: stateColor)
                barRow(title: "CPU load", value: temper.metrics.cpuUsage, tint: accent)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Header temperature + sensor picker

    /// The sensor currently chosen to drive the big header number, or nil for the
    /// automatic "hottest" reading.
    private var headerSensor: TempSensor? {
        guard let key = temper.displaySensorKey else { return nil }
        return sensorRows.first { $0.key == key }
    }
    private var headerTempC: Double { headerSensor?.celsius ?? temper.hottestC }
    private var headerSourceLabel: String { headerSensor?.label ?? "Hottest" }
    private var headerTempText: String { headerTempC > 0 ? temper.tempUnit.string(headerTempC) : "··" }

    /// The big temperature, tappable: it highlights (the outline + fill brighten,
    /// and it lifts slightly) while pressed, then opens a picker to choose which
    /// sensor feeds the display, or back to automatic "hottest". Not a system
    /// dropdown - a styled popover with sensor icons.
    private var tempPicker: some View {
        Button { showSensorPicker = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(headerTempText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundColor(.white)
                        .contentTransition(.numericText(value: headerTempC))
                        .animation(.easeOut(duration: 0.4), value: headerTempC)
                    Text(headerTempC > 0 ? temper.tempUnit.symbol : "")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white.opacity(0.4))
                }
                HStack(spacing: 4) {
                    Image(systemName: headerSensor.map { sensorIcon($0.label) } ?? "flame")
                        .font(.system(size: 8, weight: .semibold))
                    Text(headerSourceLabel).font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.42))
            }
        }
        .buttonStyle(TempDisplayButtonStyle(accent: accent, hovering: hoveringTemp))
        .onHover { hoveringTemp = $0 }
        .popover(isPresented: $showSensorPicker, arrowEdge: .bottom) { sensorPickerPopover }
    }

    /// The sensor chooser shown from the temperature display: a styled list with
    /// an icon per sensor and its live reading, plus the automatic "hottest"
    /// option, with a check on the active choice.
    private var sensorPickerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Display sensor")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary).textCase(.uppercase).tracking(0.5)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            sensorPickRow(key: nil, icon: "flame", label: "Hottest", trailing: "auto")
            if !sensorRowsStable.isEmpty { Divider().padding(.horizontal, 8) }
            // Stable (canonical) order so the list doesn't reshuffle as temps move.
            ForEach(sensorRowsStable) { s in
                sensorPickRow(key: s.key, icon: sensorIcon(s.label), label: s.label,
                              trailing: temper.temp(s.celsius))
            }
        }
        .padding(.bottom, 8)
        .frame(width: 230)
    }

    private func sensorPickRow(key: String?, icon: String, label: String, trailing: String) -> some View {
        let active = temper.displaySensorKey == key
        return Button {
            temper.setDisplaySensor(key)
            showSensorPicker = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                    .foregroundColor(active ? accent : .secondary)
                Text(label).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundColor(.primary)
                Spacer(minLength: 10)
                Text(trailing).font(.system(size: 11.5)).monospacedDigit().foregroundColor(.secondary)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent).opacity(active ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statePill: some View {
        Label(thermalCopy.label, systemImage: thermalCopy.icon)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(stateColor)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(stateColor.opacity(0.14)))
    }

    private func meterRow(title: String, valueText: String, segments: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(valueText).font(.system(size: 11, weight: .semibold)).foregroundColor(tint)
            }
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i <= segments ? tint : Color.white.opacity(0.10)).frame(height: 5)
                }
            }
        }
    }

    private func barRow(title: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.85)).contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(tint.opacity(0.7)).frame(width: max(geo.size.width * value, 4))
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: derived display values

    private var stateColor: Color {
        switch temper.thermalState {
        case .nominal:  return .green
        case .fair:     return accent
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .white.opacity(0.5)
        }
    }

    private var thermalCopy: (label: String, icon: String) {
        switch temper.thermalState {
        case .nominal:  return ("Running cool", "checkmark.circle.fill")
        case .fair:     return ("Warming up", "thermometer.medium")
        case .serious:  return ("Throttling", "thermometer.high")
        case .critical: return ("Too hot", "flame.fill")
        @unknown default: return ("Unknown", "thermometer.medium")
        }
    }

    private var thermalLevel: Int {
        switch temper.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }


    // MARK: Automatic-control widget (global - drives every fan together)

    @ViewBuilder private var controlSection: some View {
        switch temper.helper.installState {
        case .installed where temper.status.controllable: controlCard
        case .installed:                                   noControlCard
        case .installing:                                  installingCard
        case .notInstalled, .failed:                       setupCard
        }
    }

    /// All four control modes in the global selector. Picking Manual reveals the
    /// pull bar below; the automatic modes drive every fan together.
    private let controlModes: [FanControlMode] = [.default, .manual, .smart, .curve]

    private var controlCard: some View {
        // The picker reflects the mode all fans share; nil while fans differ
        // (e.g. one fan fine-tuned with its own slider).
        let common = temper.commonMode
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Control")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                Spacer()
                if temper.status.thermalCutout {
                    Label("Max cooling", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
                }
            }
            modeSegments(common)
            Text((common ?? .default).blurb)
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            switch common {
            case .manual:  manualHintDown        // set each fan with its own bar below
            case .smart:   smartControl
            case .curve:   curveControl
            case .none:    manualHint            // fans differ (per-fan fine-tune)
            case .default: EmptyView()
            }
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Manual mode points at the per-fan bars in the Fans card below (no separate
    /// global bar - each fan has its own).
    private var manualHintDown: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundColor(accent)
            Text("Drag each fan's bar below to set its speed. Link them to move together.")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func modeSegments(_ current: FanControlMode?) -> some View {
        HStack(spacing: 4) {
            ForEach(controlModes) { mode in
                let active = current == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { temper.setMode(mode) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.icon).font(.system(size: 13, weight: .semibold))
                        Text(mode.label).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(active ? accent : .white.opacity(0.5))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(active ? accent.opacity(0.15) : .white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(active ? accent.opacity(0.3) : .clear, lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Shown when fans are on per-fan Manual (no shared automatic mode): point the
    /// user at the draggable fan sliders, and offer a one-tap way back to auto.
    private var manualHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundColor(accent)
            Text("Set manually - drag a fan's bar below.")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.5))
            Spacer()
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { temper.setMode(.default) } } label: {
                Text("Reset to Default").font(.system(size: 10.5, weight: .semibold)).foregroundColor(accent)
            }.buttonStyle(.plain)
        }
    }

    /// Smart's control: one Silent ↔ Cool temperament slider (the single knob that
    /// shifts the setpoint + eagerness) over a line on what it's doing right now.
    private var smartControl: some View {
        VStack(alignment: .leading, spacing: 11) {
            TemperamentSelector(
                value: Binding(get: { temperamentDraft ?? temper.temperament },
                               set: { temperamentDraft = $0 }),
                onCommit: {
                    if let v = temperamentDraft { temper.temperament = v; temperamentDraft = nil }
                })
            smartReadout
            if temper.verboseSmart {
                if let d = temper.status.smartDebug {
                    SmartDebugView(d: d, tempFmt: temper.temp, accent: accent)
                } else {
                    Text("Verbose Smart will appear here once the helper is driving a fan on Smart.")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Smart shows no curve and no meter - just a line on what it's doing.
    private var smartReadout: some View {
        let handsOff = temper.smartTargetNow == nil
        return Text(handsOff
                    ? "Cool enough to leave to macOS. Temper takes over and ramps the fans as it heats up or the load climbs."
                    : "Temper is driving the fans now, adapting to temperature and load.")
            .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var curveControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            FanCurveEditor(
                points: Binding(get: { temper.control.curve },
                                set: { temper.setCurve($0) }),
                currentTemp: temper.hottestC, tint: accent, editable: true)
                .frame(height: 150)
            Text("Drag the points to shape the curve. The dot tracks the hottest sensor right now.")
                .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: Fans (live RPM + Sous-style manual sliders)

    private var fansCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fans").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            let fans = temper.displayFans
            ForEach(Array(fans.enumerated()), id: \.element.id) { i, fan in
                fanRow(fan)
                // A link connector sits in the left gutter between the fans (only
                // while they're manually controlled): lines run up to the top fan
                // and down to the bottom one, with a glass toggle in the middle.
                if temper.capable, i == 0, fans.count > 1, temper.commonMode == .manual { linkConnector }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The link control: a liquid-glass circle holding the link glyph, sitting in
    /// the left column (under the fan icons) with connector lines reaching up to
    /// the fan above and down to the fan below. Linked = drag one, move all.
    private var linkConnector: some View {
        let linked = temper.fansLinked
        let lineColor: Color = linked ? accent.opacity(0.5) : .white.opacity(0.14)
        return HStack(spacing: 12) {
            VStack(spacing: 0) {
                Capsule().fill(lineColor).frame(width: 1.5, height: 9)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { temper.fansLinked.toggle() }
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(linked ? accent : .white.opacity(0.45))
                        .frame(width: 24, height: 24)
                        .glassEffect(.regular.tint((linked ? accent : Color.white).opacity(linked ? 0.45 : 0.06)), in: Circle())
                        .overlay(Circle().stroke(linked ? accent.opacity(0.45) : .white.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(linked ? "Fans linked - click to unlink" : "Link the fans so they move together")
                Capsule().fill(lineColor).frame(width: 1.5, height: 9)
            }
            .frame(width: 22)
            Spacer()
        }
        .padding(.vertical, -6)   // pull the lines toward the fan icons above/below
    }

    private func fanRow(_ fan: FanInfo) -> some View {
        let setting = temper.setting(for: fan.index)
        let isManual = setting?.mode == .manual
        // The knob sits at the speed Temper is commanding; when hands-off (Default
        // / idle Smart) it tracks the live fan speed so it isn't misleading.
        let commanded = temper.commandedPercent(for: fan)
        let knobPercent = commanded ?? fan.fraction * 100
        return HStack(spacing: 12) {
            SpinningFan(revsPerSecond: fan.actualRPM > 0 ? 0.1 + fan.fraction * 2.4 : 0, color: accent.opacity(0.85), size: 18)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Fan \(fan.index + 1)").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
                    if isManual {
                        Text("MANUAL").font(.system(size: 8, weight: .bold)).tracking(0.4)
                            .foregroundColor(accent)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(accent.opacity(0.16)))
                    }
                    Spacer()
                    Text("\(Int(fan.actualRPM)) rpm")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.9))
                        .contentTransition(.numericText(value: fan.actualRPM))
                        .animation(.easeOut(duration: 0.4), value: fan.actualRPM)
                }
                // The draggable knob only appears in Manual mode; otherwise the
                // bar is a read-only live RPM gauge.
                FanSpeedSlider(
                    liveFraction: fan.fraction,
                    knobPercent: knobPercent,
                    showKnob: isManual,
                    tint: isManual ? accent : accent.opacity(0.6),
                    onScrub: { temper.scrubManual(fan: fan.index, percent: $0) })
                if fan.minRPM > 0 || fan.maxRPM > 0 {
                    Text("\(Int(fan.minRPM)) to \(Int(fan.maxRPM)) rpm")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.32))
                }
            }
        }
    }

    // MARK: Setup / status cards

    private func card<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30)).foregroundColor(tint)
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        card(icon: "fanblades", tint: accent) {
            Text("Control your fans")
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text("Set the fans to Manual, an adaptive Smart mode, or your own curve. It installs a small background helper that drives the fans, and macOS will ask you to allow it once.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
            if case .failed(let msg) = temper.helper.installState {
                Text(msg).font(.system(size: 10.5)).foregroundColor(.orange).multilineTextAlignment(.center)
            }
            Button { Task { await temper.helper.install(); temper.refreshNow() } } label: {
                Text("Install fan helper")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(accent.opacity(0.14)))
            }.buttonStyle(.plain)
        }
    }

    private var installingCard: some View {
        card(icon: "lock.shield", tint: accent) {
            ProgressView().controlSize(.large)
            Text("Authorizing").font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white)
            Text("Enter your Mac password in the prompt to install the fan helper. This happens once.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
    }

    private var noControlCard: some View {
        card(icon: "fanblades.slash", tint: .white.opacity(0.4)) {
            Text("Fans can't be controlled")
                .font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            Text("This Mac doesn't expose writable fan controls. You can still watch the speeds and temperatures below.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
        }
    }

    private var passiveCard: some View {
        card(icon: "wind", tint: .white.opacity(0.4)) {
            Text("Cooled passively")
                .font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            Text("This Mac has no fans. Temper still tracks its temperatures, thermal pressure and CPU load above.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
        }
    }

    // MARK: Sensors

    /// Sensors in a fixed, canonical order (as the reader enumerates them) plus
    /// battery. Used by the picker so its list never reshuffles as temps move.
    private var sensorRowsStable: [TempSensor] {
        var rows = temper.metrics.sensors
        // Only add the dedicated battery reading if the sensor sweep didn't already
        // surface a Battery sensor (else it shows up twice). The extended set has
        // its own battery group, so the fallback is basic-mode only.
        if !temper.extendedSensors, temper.metrics.batteryTempC > 0,
           !rows.contains(where: { $0.label == "Battery" }) {
            rows.append(TempSensor(key: "TB__", label: "Battery", celsius: temper.metrics.batteryTempC))
        }
        return rows
    }

    /// Same set, sorted hottest-first - used for the sensors card display.
    private var sensorRows: [TempSensor] {
        sensorRowsStable.sorted { $0.celsius > $1.celsius }
    }

    private var sensorsCard: some View {
        VStack(alignment: .leading, spacing: temper.extendedSensors ? 12 : 10) {
            HStack(spacing: 6) {
                Text("Sensors").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                if temper.extendedSensors {
                    Text("extended").font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(accent.opacity(0.7))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(accent.opacity(0.14)))
                }
            }
            if temper.extendedSensors { groupedSensors } else {
                ForEach(sensorRows) { sensorRow($0) }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Extended view: rows bucketed into subsystem sections, hottest-first within
    /// each, in the canonical group order.
    @ViewBuilder private var groupedSensors: some View {
        let byGroup = Dictionary(grouping: sensorRowsStable) { $0.group ?? "Other" }
        let order = TemperSensors.extendedGroupOrder + ["Other"]
        ForEach(order.filter { byGroup[$0]?.isEmpty == false }, id: \.self) { g in
            VStack(alignment: .leading, spacing: 5) {
                Label(g, systemImage: groupIcon(g))
                    .labelStyle(.titleAndIcon).imageScale(.small)
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.32))
                ForEach((byGroup[g] ?? []).sorted { $0.celsius > $1.celsius }) { sensorRow($0, grouped: true) }
            }
        }
    }

    private func sensorRow(_ s: TempSensor, grouped: Bool = false) -> some View {
        HStack(spacing: 9) {
            if grouped {
                // The section header already names the subsystem, so each row just
                // needs a temperature-coloured dot.
                Circle().fill(sensorColor(s.celsius)).frame(width: 6, height: 6).frame(width: 18)
            } else {
                Image(systemName: sensorIcon(s.label))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(sensorColor(s.celsius)).frame(width: 18)
            }
            Text(s.label).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6))
            Spacer(minLength: 12)
            Text(temper.temp(s.celsius))
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundColor(.white.opacity(0.9)).contentTransition(.numericText())
        }
        .padding(.vertical, grouped ? 1 : 2)
    }

    private func groupIcon(_ group: String) -> String {
        switch group {
        case "CPU": return "cpu"
        case "GPU": return "cpu.fill"
        case "SoC": return "square.stack.3d.up"
        case "Memory": return "memorychip"
        case "Power": return "bolt.fill"
        case "Board": return "square.grid.3x3"
        case "Battery": return "minus.plus.batteryblock"
        case "Wireless": return "wifi"
        case "Ambient": return "wind"
        default: return "thermometer.medium"
        }
    }

    /// A distinct SF Symbol per sensor kind so the list is scannable at a glance.
    private func sensorIcon(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("gpu") { return "cpu.fill" }
        if l.contains("cpu") { return "cpu" }
        if l.contains("batt") { return "minus.plus.batteryblock" }
        if l.contains("airflow") || l.contains("wind") { return "wind" }
        if l.contains("ambient") { return "thermometer.sun" }
        if l.contains("enclosure") { return "macbook" }
        if l.contains("wi-fi") || l.contains("wifi") { return "wifi" }
        if l.contains("ssd") || l.contains("drive") { return "internaldrive" }
        if l.contains("mainboard") || l.contains("board") { return "square.grid.3x3" }
        return "thermometer.medium"
    }

    /// Tint a sensor by how hot it is, so the eye lands on the hot ones.
    private func sensorColor(_ c: Double) -> Color {
        switch c {
        case ..<60:  return .white.opacity(0.4)
        case ..<80:  return accent.opacity(0.8)
        case ..<90:  return .orange
        default:     return .red
        }
    }
}

/// The header temperature is plain text by default - nothing hints it's a
/// control. On hover a subtle outline fades in around it so it reads as
/// clickable; pressing brightens that outline to the accent. No persistent box,
/// no chevron.
struct TempDisplayButtonStyle: ButtonStyle {
    let accent: Color
    var hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let stroke: Color = pressed ? accent.opacity(0.6) : (hovering ? .white.opacity(0.18) : .clear)
        let fill: Color = pressed ? accent.opacity(0.10) : (hovering ? .white.opacity(0.03) : .clear)
        return configuration.label
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(stroke, lineWidth: 1))
            .animation(.easeOut(duration: 0.16), value: hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .fixedSize()
    }
}

/// A fan glyph that spins continuously, its rate set by `revsPerSecond`. Driven
/// by a `TimelineView(.animation)` so the speed varies smoothly without
/// restarting an animation, and costs nothing while the panel is closed.
struct SpinningFan: View {
    var revsPerSecond: Double
    var color: Color
    var size: CGFloat
    @State private var store = SpinStore()
    @ObservedObject private var visibility = PanelVisibility.shared

    /// A stopped fan (0 RPM) shouldn't keep turning. Freeze the blades and pause the
    /// timeline so it costs nothing, exactly like the offscreen case.
    private var isStopped: Bool { revsPerSecond <= 0 }

    var body: some View {
        // Pause the timeline when the panel is hidden or the fan is stopped:
        // `TimelineView(.animation)` otherwise redraws at the display refresh rate
        // forever, even off-screen or for a motionless fan.
        TimelineView(.animation(paused: !visibility.isOpen || isStopped)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            // Integrate angle over real elapsed time and ease the rate toward its
            // target, so a new RPM reading changes the *speed* smoothly and never
            // jumps the *position* (which is what made it look jittery).
            let dt = min(max(store.last.map { now - $0 } ?? 0, 0), 0.1)   // clamp across sleeps
            store.last = now
            if isStopped {
                store.rate = 0                         // hold position; spin up smoothly later
            } else {
                store.rate += (revsPerSecond - store.rate) * min(dt * 4, 1)
                store.phase = (store.phase + dt * store.rate).truncatingRemainder(dividingBy: 1)
            }
            return Image(systemName: "fanblades.fill")
                .font(.system(size: size))
                .foregroundStyle(color)
                .rotationEffect(.degrees(store.phase * 360))
        }
    }
}

/// Mutable spin state for `SpinningFan`, held by reference so the `TimelineView`
/// closure can integrate phase/rate across frames without re-rendering the view.
final class SpinStore { var phase = 0.0; var rate = 0.0; var last: TimeInterval? }

/// A fan's speed control, modelled on Sous's charge slider: one bar that is both
/// a live gauge and a manual control. The Liquid-Glass fill shows the *actual*
/// current RPM; the light knob marks the speed Temper is commanding, and dragging
/// it scrubs the fan to a manual speed. The knob hides until the helper is
/// installed (read-only gauge until then).
/// Smart's temperament as a row of snapping *profile stops* rather than a bare
/// slider. The track is a fixed warm→cool spectrum (so it reads as a selector, not
/// a fill-to-here bar); the glass thumb springs magnetically between discrete
/// setpoints with a soft haptic tick, and a live profile name + the temperature it
/// aims to hold crossfades below. Silent (hotter, quieter) sits warm on the left;
/// Cool (lower setpoint, eager) sits icy on the right - the same axis the daemon's
/// controller reads, and the aim temp comes straight from `TemperSmart.targetTempC`.
struct TemperamentSelector: View {
    @Binding var value: Double
    var onCommit: () -> Void

    private let stops: [(v: Double, name: String)] = [
        (0.00, "Silent"), (0.25, "Quiet"), (0.50, "Balanced"),
        (0.75, "Brisk"), (1.00, "Cool"),
    ]
    private let trackH: CGFloat = 16
    private let thumbW: CGFloat = 22

    /// Warm (amber, quiet/hot) → cool (ice, eager/cold) blended at fraction `f`,
    /// so the track is literally a temperature spectrum coloured from both ends.
    private func spectrum(_ f: Double) -> Color {
        let t = min(max(f, 0), 1)
        return Color(red: 0.98 + (0.42 - 0.98) * t,
                     green: 0.60 + (0.80 - 0.60) * t,
                     blue:  0.26 + (1.00 - 0.26) * t)
    }
    private func nearestIndex(to f: Double) -> Int {
        stops.indices.min(by: { abs(stops[$0].v - f) < abs(stops[$1].v - f) }) ?? 0
    }
    private var active: Int { nearestIndex(to: value) }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(spectrum(0).opacity(0.9))
                track
                Image(systemName: "snowflake")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(spectrum(1).opacity(0.9))
            }
            caption
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = geo.size.height / 2
            let cx = min(max(CGFloat(value) * w, thumbW / 2), w - thumbW / 2)
            ZStack {
                // Glass base + always-on spectrum: the bar shows the whole range,
                // not a fill to the current value.
                Capsule().fill(.white.opacity(0.06)).frame(height: trackH)
                Capsule()
                    .fill(LinearGradient(colors: [spectrum(0), spectrum(0.5), spectrum(1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackH)
                    .opacity(0.6)
                    .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5).frame(height: trackH))

                // Setpoint ticks; the active one lights up.
                ForEach(stops.indices, id: \.self) { i in
                    let sx = min(max(CGFloat(stops[i].v) * w, thumbW / 2), w - thumbW / 2)
                    Circle()
                        .fill(.white.opacity(i == active ? 0.95 : 0.3))
                        .frame(width: i == active ? 5 : 4, height: i == active ? 5 : 4)
                        .position(x: sx, y: cy)
                }

                // Liquid-glass thumb: spectrum-tinted (which profile), with a plain
                // neutral ring — no situation glow.
                Color.clear
                    .frame(width: thumbW, height: trackH + 10)
                    .glassEffect(.regular.tint(spectrum(value).opacity(0.7)), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(x: cx, y: cy)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(min(max(g.location.x / w, 0), 1))
                        let i = nearestIndex(to: f)
                        if stops[i].v != value {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.6)) { value = stops[i].v }
                            tick()
                        }
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: trackH + 10)
    }

    private var caption: some View {
        let aim = Int(TemperSmart.targetTempC(temperament: value).rounded())
        return HStack(spacing: 5) {
            Text(stops[active].name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .id(active)
                .transition(.opacity)
            Text("· holds ~\(aim)°C")
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: active)
    }

    /// A soft alignment tap as the thumb crosses into a new setpoint.
    private func tick() {
        #if canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}

/// The "Verbose Smart output" diagram (Settings-gated): a compact x-ray of one
/// Smart tick. Three rows top-down, in the order the controller reasons: where the
/// control temperature sits relative to the target it holds, how the fan demand is
/// built (reactive feedback + power feedforward, with the learned-plant floor and
/// the slewed output marked), and the raw signals feeding it all.
struct SmartDebugView: View {
    let d: SmartDebug
    let tempFmt: (Double) -> String
    let accent: Color

    private let fbColor = Color(red: 0.40, green: 0.70, blue: 1.0)   // reactive feedback
    private var commandPct: Double { d.output >= 0 ? d.output : d.demand }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            controlBar
            demandBar
            signals
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").font(.system(size: 9))
            Text("Smart reasoning").font(.system(size: 10, weight: .semibold))
            Spacer()
            Text(d.handsOff ? "hands off" : "driving \(Int(commandPct.rounded()))%")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(d.handsOff ? .white.opacity(0.4) : accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((d.handsOff ? Color.white : accent).opacity(d.handsOff ? 0.06 : 0.16)))
        }
        .foregroundColor(.white.opacity(0.6))
    }

    // Where the control temperature sits inside its target band.
    private var controlBar: some View {
        let band = 20 - d.temperament * 6
        let lo = d.setpointC - band, hiEnd = d.setpointC + 4
        let span = max(hiEnd - lo, 1)
        let frac = min(max((d.controlTempC - lo) / span, 0), 1)
        let setFrac = min(max((d.setpointC - lo) / span, 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Controlling on").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                Text(tempFmt(d.controlTempC)).font(.system(size: 9.5, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                Spacer()
                Text("holds \(tempFmt(d.setpointC))").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07)).frame(height: 8)
                    Capsule()
                        .fill(LinearGradient(colors: [fbColor.opacity(0.5), accent.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(CGFloat(frac) * w, 4), height: 8)
                    // target line
                    Rectangle().fill(.white.opacity(0.55)).frame(width: 1.5, height: 14)
                        .position(x: CGFloat(setFrac) * w, y: 4)
                }
            }
            .frame(height: 8)
        }
    }

    // How the demand is assembled: feedback + feedforward, plant-floor tick, output knob.
    private var demandBar: some View {
        let fb = min(max(d.feedback, 0), 100)
        let ff = min(max(d.feedforward, 0), max(0, 100 - fb))
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                let plantX = CGFloat(min(max(d.plantFloor, 0), 100) / 100) * w
                let outX = CGFloat(min(max(commandPct, 0), 100) / 100) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07)).frame(height: 8)
                    HStack(spacing: 0) {
                        Capsule().fill(fbColor.opacity(0.85)).frame(width: CGFloat(fb / 100) * w, height: 8)
                        Capsule().fill(accent.opacity(0.85)).frame(width: CGFloat(ff / 100) * w, height: 8)
                    }
                    if d.plantFloor >= 0 {
                        Rectangle().fill(.white.opacity(0.75)).frame(width: 1.5, height: 13)
                            .position(x: min(max(plantX, 1), w - 1), y: 4)
                    }
                    Capsule().fill(.white).frame(width: 6, height: 15)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .position(x: min(max(outX, 3), w - 3), y: 4)
                }
            }
            .frame(height: 15)
            HStack(spacing: 10) {
                legend(fbColor, "feedback \(Int(fb.rounded()))%")
                legend(accent, "load \(Int(ff.rounded()))%")
                if d.plantFloor >= 0 { legend(.white.opacity(0.75), "plant \(Int(d.plantFloor.rounded()))%") }
                Spacer()
                Text("output \(Int(commandPct.rounded()))%")
                    .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
        }
    }

    // Raw inputs feeding the tick.
    private var signals: some View {
        let rise = String(format: "%@%.1f°/s", d.risePerSec >= 0 ? "+" : "", d.risePerSec)
        let accum = String(format: "+%.1f°", d.accumulation)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 7) {
            chip("Power", "\(Int(d.powerW.rounded()))W", "base \(Int(d.powerBaselineW.rounded()))W")
            chip("Ambient", tempFmt(d.ambientC), nil)
            chip("Build-up", accum, nil)
            chip("Rise", rise, nil)
            chip("Idle floor", tempFmt(d.idleFloorC), nil)
            chip("Temperament", "\(Int((d.temperament * 100).rounded()))%", nil)
        }
    }

    private func chip(_ title: String, _ value: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.35))
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(.white.opacity(0.85))
            if let sub { Text(sub).font(.system(size: 7.5)).foregroundColor(.white.opacity(0.3)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5).padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.03)))
    }
}

struct FanSpeedSlider: View {
    var liveFraction: Double          // 0–1, actual RPM in the fan's range
    var knobPercent: Double           // 0–100, the commanded target
    var showKnob: Bool
    var tint: Color
    var onScrub: (Double) -> Void

    private let barH: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = geo.size.height / 2
            let fillW = max(CGFloat(min(max(liveFraction, 0), 1)) * w, barH)
            let knobX = CGFloat(min(max(knobPercent, 0), 100) / 100) * w
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10)).frame(height: barH)
                Color.clear
                    .frame(width: fillW, height: barH)
                    .glassEffect(.regular.tint(tint.opacity(0.55)), in: Capsule())
                    .animation(.easeOut(duration: 0.5), value: fillW)   // glide to each reading
                if showKnob {
                    Capsule().fill(.white)
                        .frame(width: 8, height: barH + 12)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .position(x: min(max(knobX, 4), w - 4), y: cy)
                }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            // Draggable only when the knob is shown (Manual mode); otherwise the
            // bar is a read-only gauge and shouldn't intercept drags.
            .gesture(showKnob ? DragGesture(minimumDistance: 0).onChanged { v in
                onScrub(Double(min(max(v.location.x / w, 0), 1)) * 100)
            } : nil)
        }
        .frame(height: barH + 14)
    }
}

/// A fan curve plotted as temperature (X, 30–100°C) against fan speed (Y, 0–100%).
/// The line is a smooth monotone spline (the same one the daemon uses to resolve
/// speed, so the picture matches the behaviour). When `editable`, drag any point
/// to reshape it; the ends pin to the temperature range. A live dot rides the
/// curve at the current temperature.
struct FanCurveEditor: View {
    @Binding var points: [FanCurvePoint]
    var currentTemp: Double
    var tint: Color
    var editable: Bool = true

    private let tMin = 30.0
    private let tMax = 100.0
    private let space = "fancurve"

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                grid(w, h)
                smoothPath(w, h, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
                smoothPath(w, h, closed: false)
                    .stroke(tint.opacity(editable ? 0.95 : 0.5),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                nowMarker(w, h)
                if editable { handles(w, h) } else { staticDots(w, h) }
            }
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: points)
        }
    }

    private func px(_ temp: Double, _ w: CGFloat) -> CGFloat { CGFloat((temp - tMin) / (tMax - tMin)) * w }
    private func py(_ pct: Double, _ h: CGFloat) -> CGFloat { h - CGFloat(pct / 100) * h }
    private func temp(_ x: CGFloat, _ w: CGFloat) -> Double { tMin + Double(x / max(w, 1)) * (tMax - tMin) }
    private func pct(_ y: CGFloat, _ h: CGFloat) -> Double { (1 - Double(y / max(h, 1))) * 100 }

    private func grid(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.03))
            ForEach(1..<4, id: \.self) { r in
                Rectangle().fill(.white.opacity(0.05)).frame(height: 0.5)
                    .position(x: w / 2, y: h * CGFloat(r) / 4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 0.5))
    }

    /// Sample the shared smooth interpolation across the width for a fluid line.
    private func smoothPath(_ w: CGFloat, _ h: CGFloat, closed: Bool) -> Path {
        var path = Path()
        guard w > 1 else { return path }
        let steps = max(Int(w / 2), 24)
        func point(_ i: Int) -> CGPoint {
            let x = CGFloat(i) / CGFloat(steps) * w
            return CGPoint(x: x, y: py(FanSetting.interpolate(points, at: temp(x, w)), h))
        }
        if closed { path.move(to: CGPoint(x: 0, y: h)); path.addLine(to: point(0)) }
        else { path.move(to: point(0)) }
        for i in 1...steps { path.addLine(to: point(i)) }
        if closed { path.addLine(to: CGPoint(x: w, y: h)); path.closeSubpath() }
        return path
    }

    @ViewBuilder private func nowMarker(_ w: CGFloat, _ h: CGFloat) -> some View {
        if currentTemp > 0 {
            let t = min(max(currentTemp, tMin), tMax)
            let cx = px(t, w)
            let cy = py(FanSetting.interpolate(points, at: t), h)
            ZStack {
                Path { p in p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: h)) }
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Circle().fill(.white).frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(x: cx, y: cy)
            }
        }
    }

    private func staticDots(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(points.indices, id: \.self) { idx in
            let p = points[idx]
            Circle().fill(tint.opacity(0.7)).frame(width: 6, height: 6)
                .position(x: px(p.tempC, w), y: py(p.percent, h))
        }
    }

    private func handles(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(points.indices, id: \.self) { idx in
            let p = points[idx]
            Circle().fill(tint)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .position(x: px(p.tempC, w), y: py(p.percent, h))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { v in drag(idx, to: v.location, w, h) })
        }
    }

    /// Move point `idx` to a dragged location. Ends pin to the temperature range;
    /// middle points clamp between neighbours to keep the array ordered.
    private func drag(_ idx: Int, to loc: CGPoint, _ w: CGFloat, _ h: CGFloat) {
        guard points.indices.contains(idx) else { return }
        var pts = points
        let lo = idx > 0 ? pts[idx - 1].tempC + 2 : tMin
        let hi = idx < pts.count - 1 ? pts[idx + 1].tempC - 2 : tMax
        var newTemp = min(max(temp(loc.x, w), lo), hi)
        if idx == 0 { newTemp = tMin }
        if idx == pts.count - 1 { newTemp = tMax }
        pts[idx] = FanCurvePoint(tempC: newTemp, percent: min(max(pct(loc.y, h), 0), 100))
        points = pts
    }
}

/// Reorders the Temper cards as one is dragged over another, mutating the
/// manager's persisted `widgetOrder` live on hover. Mirrors Sous's delegate.
private struct TemperWidgetDrop: DropDelegate {
    let item: TemperManager.TemperWidget
    let temper: TemperManager
    @Binding var dragging: TemperManager.TemperWidget?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = temper.widgetOrder.firstIndex(of: dragging),
              let to = temper.widgetOrder.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            temper.widgetOrder.move(fromOffsets: IndexSet(integer: from),
                                    toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
