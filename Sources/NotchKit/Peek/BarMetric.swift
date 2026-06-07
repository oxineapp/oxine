import SwiftUI

/// A live metric the notch bar can fill to (left → right). CPU and GPU are read
/// internally by `SystemUsageMonitor` (permission-free); fan speed comes from a
/// host-injected provider (NotchKit stays dependency-neutral, so the Temper SMC
/// read lives in the host); the Claude 5-hour figure comes from `ccusage`.
public enum BarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, fan, claude

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cpu:    return "CPU usage"
        case .gpu:    return "GPU usage"
        case .fan:    return "Fan speed"
        case .claude: return "Claude 5h limit"
        }
    }

    /// The fill colour for this metric.
    @MainActor public var color: Color {
        switch self {
        case .cpu:    return .panelAccent
        case .gpu:    return Color(red: 0.61, green: 0.45, blue: 0.95)   // violet
        case .fan:    return Color(red: 0.30, green: 0.74, blue: 0.92)   // cyan
        case .claude: return Color(red: 0.85, green: 0.52, blue: 0.23)   // amber
        }
    }

    /// The persisted choice for the bar fill (the left half when split).
    public static var selected: BarMetric {
        BarMetric(rawValue: NotchKit.settingsDefaults.string(forKey: "notchBarMetric") ?? "") ?? .cpu
    }

    /// Whether the bar is split into two independent halves.
    public static var splitEnabled: Bool {
        NotchKit.settingsDefaults.bool(forKey: "notchBarSplit")
    }

    /// The metric shown in the right half when `splitEnabled`. Defaults to GPU so a
    /// fresh split shows two different things rather than CPU twice.
    public static var secondary: BarMetric {
        BarMetric(rawValue: NotchKit.settingsDefaults.string(forKey: "notchBarMetricRight") ?? "") ?? .gpu
    }

    /// Every metric the bar is currently drawing (one, or two when split).
    public static var active: [BarMetric] {
        splitEnabled ? [selected, secondary] : [selected]
    }
}

/// What a metric resolves to for rendering: a clamped 0…1 fill plus a short label
/// (e.g. "63%", "2400 rpm"). `nil` from a provider means "no data" — the bar then
/// sits empty rather than guessing.
public struct MetricReadout: Sendable, Equatable {
    public var fraction: Double
    public var text: String

    public init(fraction: Double, text: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.text = text
    }
}

public extension NotchKit {
    /// Host-supplied fan readout. Oxine wires this to `TemperManager` so NotchKit
    /// needn't depend on TemperKit / the SMC. `nil` when no fan data is available.
    /// Read on the main actor.
    @MainActor static var fanReadout: (() -> MetricReadout?)?
}
