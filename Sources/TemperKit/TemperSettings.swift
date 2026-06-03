import SwiftUI
import PanelKit
import TemperShared

/// The Temper fan controls for a settings screen: default control mode, manual
/// level / curve thresholds, and helper repair/remove. Drop it inside a
/// `SettingSection(title: "Temper · Thermal & Fans")`. Monitoring (temps, thermal
/// pressure, load, fan speeds) needs no setup - it’s always live in the tab.
public struct TemperSettings: View {
    @ObservedObject var temper: TemperManager

    public init(temper: TemperManager) { self.temper = temper }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Temperature unit").foregroundColor(.white.opacity(0.85))
                    Text("Show temperatures in Celsius or Fahrenheit.")
                        .font(.caption2).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Picker("", selection: Binding(get: { temper.tempUnit },
                                              set: { temper.tempUnit = $0 })) {
                    ForEach(TemperManager.TempUnit.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 110)
            }
            Divider().overlay(Color.white.opacity(0.06))

            if temper.capable {
                Text("Set each fan's mode, manual speed and temperature curve in the Temper tab. The helper drives the fans in the background.")
                    .font(.caption2).foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.white.opacity(0.06))
                Button {
                    Task { await temper.helper.install(); temper.refreshNow() }
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
                    Task { await temper.helper.uninstall() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Remove fan helper").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundColor(.red.opacity(0.85)).font(.system(size: 12))
                    .background(Color.red.opacity(0.08)).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.18), lineWidth: 0.5))
                }.buttonStyle(.plain)
            } else if temper.fansPresent {
                Text("Open the Temper tab to set up fan control.")
                    .font(.caption).foregroundColor(.white.opacity(0.5))
            } else {
                Text("Temper shows temperatures, thermal pressure and CPU load in its tab. This Mac has no controllable fans.")
                    .font(.caption).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
