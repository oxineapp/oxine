import SwiftUI

/// Panel size presets. The whole window flows to fill whatever size the panel
/// is, so the host's AppDelegate owns the actual dimensions and these just
/// describe them.
public enum PanelSize: String, CaseIterable, Identifiable {
    case compact, standard, tall, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact:  return "Compact"
        case .standard: return "Standard"
        case .tall:     return "Tall"
        case .custom:   return "Custom"
        }
    }

    /// Fixed dimensions for the preset, or nil for `.custom` (user-resized).
    public var presetSize: CGSize? {
        switch self {
        case .compact:  return CGSize(width: 360, height: 500)
        case .standard: return CGSize(width: 480, height: 560)
        case .tall:     return CGSize(width: 480, height: 660)
        case .custom:   return nil
        }
    }
}

/// Single source of truth for the panel's geometry, persisted in the host's
/// configured settings suite so both SwiftUI (@AppStorage) and AppDelegate agree.
public enum PanelLayout {
    public static var suite: UserDefaults { PanelKit.settingsDefaults }

    /// Floor so a stray drag can't shrink the panel down to nothing.
    public static let minSize = CGSize(width: 300, height: 340)
    public static let maxSize = CGSize(width: 560, height: 920)
    public static let defaultCustom = CGSize(width: 380, height: 560)

    /// Shared duration for preset resizes so the window (AppKit) and the content
    /// (SwiftUI) animate in lockstep — otherwise the content snaps and looks jagged.
    public static let resizeDuration: TimeInterval = 0.34

    public static let presetKey = "panelSizePreset"
    public static let customWidthKey = "panelCustomWidth"
    public static let customHeightKey = "panelCustomHeight"
    public static let customLockedKey = "panelCustomLocked"

    public static var preset: PanelSize {
        PanelSize(rawValue: suite.string(forKey: presetKey) ?? PanelSize.standard.rawValue) ?? .standard
    }

    public static var customSize: CGSize {
        let w = suite.object(forKey: customWidthKey) as? Double ?? Double(defaultCustom.width)
        let h = suite.object(forKey: customHeightKey) as? Double ?? Double(defaultCustom.height)
        return CGSize(width: clamp(w, minSize.width, maxSize.width),
                      height: clamp(h, minSize.height, maxSize.height))
    }

    public static func setCustomSize(_ size: CGSize) {
        suite.set(Double(clamp(size.width, minSize.width, maxSize.width)), forKey: customWidthKey)
        suite.set(Double(clamp(size.height, minSize.height, maxSize.height)), forKey: customHeightKey)
    }

    /// When a custom size is locked the panel can't be dragged-resized.
    public static var customLocked: Bool {
        get { suite.bool(forKey: customLockedKey) }
        set { suite.set(newValue, forKey: customLockedKey) }
    }

    /// The size the panel should currently be.
    public static var current: CGSize {
        preset.presetSize ?? customSize
    }

    public static var isCustom: Bool { preset == .custom }

    /// Edge-dragging is only allowed for an unlocked custom size.
    public static var isResizable: Bool { isCustom && !customLocked }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
    private static func clamp(_ v: Double, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        clamp(CGFloat(v), lo, hi)
    }
}

public extension Notification.Name {
    /// Posted when the user changes the size preset so the panel re-lays out.
    static let panelSizeChanged = Notification.Name("panelSizeChanged")
}
