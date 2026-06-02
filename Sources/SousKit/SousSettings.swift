import SwiftUI
import PanelKit

/// The Sous battery controls for a settings screen: sailing range, heat
/// protection, MagSafe LED, auto-calibration, and helper repair/remove. Drop it
/// inside a `SettingSection(title: "Sous · Battery")`. Shared by Oxine and the
/// standalone sous-vide app so the controls stay identical.
public struct SousSettings: View {
    @ObservedObject var sous: SousManager

    public init(sous: SousManager) { self.sous = sous }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sous.helper.installState == .installed {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sailing range").foregroundColor(.white.opacity(0.85))
                        Text("Let the charge drop this far below the limit before recharging — avoids constant micro-charging.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Stepper(value: Binding(get: { sous.config.sailingRange },
                                           set: { sous.setSailing($0) }), in: 0...15) {
                        Text("\(sous.config.sailingRange)%")
                            .foregroundColor(.white.opacity(0.7)).font(.caption).monospacedDigit()
                    }.fixedSize()
                }
                Divider().overlay(Color.white.opacity(0.06))
                Toggle(isOn: Binding(get: { sous.config.heatProtectEnabled },
                                     set: { sous.setHeatProtect($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heat protection").foregroundColor(.white.opacity(0.85))
                        Text("Pause charging when the battery runs hot.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                }.toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                if sous.config.heatProtectEnabled {
                    HStack {
                        Text("Max temperature").foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Stepper(value: Binding(get: { sous.config.maxTempC },
                                               set: { sous.setMaxTemp($0) }), in: 25...45, step: 1) {
                            Text(String(format: "%.0f°C", sous.config.maxTempC))
                                .foregroundColor(.white.opacity(0.7)).font(.caption).monospacedDigit()
                        }.fixedSize()
                    }
                }
                if sous.canControlLED {
                    Divider().overlay(Color.white.opacity(0.06))
                    Toggle(isOn: Binding(get: { sous.config.controlLED },
                                         set: { sous.setControlLED($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Control MagSafe LED").foregroundColor(.white.opacity(0.85))
                            Text("Green when held at your limit, amber while charging toward it.")
                                .font(.caption2).foregroundColor(.white.opacity(0.5))
                        }
                    }.toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
                }
                Divider().overlay(Color.white.opacity(0.06))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-calibrate").foregroundColor(.white.opacity(0.85))
                        Text("Run a full calibration cycle on a schedule to keep the gauge accurate.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { sous.calibrationSchedule },
                                                  set: { sous.setCalibrationSchedule($0) })) {
                        ForEach(SousManager.CalibrationSchedule.allCases) { Text($0.label).tag($0) }
                    }.frame(width: 130)
                }
                if sous.calibrationSchedule != .off, let next = sous.nextCalibrationDue {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                        Text("Next calibration \(next.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundColor(.white.opacity(0.45))
                    }
                }
                Divider().overlay(Color.white.opacity(0.06))
                Button {
                    Task { await sous.helper.install(); sous.refreshNow() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Reinstall / repair helper").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundColor(Color.panelAccent).font(.system(size: 12))
                    .background(Color.panelAccent.opacity(0.10)).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.panelAccent.opacity(0.2), lineWidth: 0.5))
                }.buttonStyle(.plain)
                Button {
                    Task { await sous.helper.uninstall() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Remove battery helper").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundColor(.red.opacity(0.85)).font(.system(size: 12))
                    .background(Color.red.opacity(0.08)).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.18), lineWidth: 0.5))
                }.buttonStyle(.plain)
            } else {
                Text("Open the Sous tab to set up battery charge control.")
                    .font(.caption).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
