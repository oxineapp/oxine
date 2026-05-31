import SwiftUI

/// Panel size presets. The whole window flows to fill whatever size the panel
/// is, so AppDelegate owns the actual dimensions and these just describe them.
enum OxinePanelSize: String, CaseIterable, Identifiable {
    case compact, standard, tall, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:  return "Compact"
        case .standard: return "Standard"
        case .tall:     return "Tall"
        case .custom:   return "Custom"
        }
    }

    /// Fixed dimensions for the preset, or nil for `.custom` (user-resized).
    var presetSize: CGSize? {
        switch self {
        case .compact:  return CGSize(width: 360, height: 460)
        case .standard: return CGSize(width: 380, height: 560)
        case .tall:     return CGSize(width: 400, height: 660)
        case .custom:   return nil
        }
    }
}

/// Single source of truth for the panel's geometry, persisted in the shared
/// settings suite so both SwiftUI (@AppStorage) and AppDelegate agree.
enum OxinePanelLayout {
    static var suite: UserDefaults { UserDefaults(suiteName: "com.menubar.settings") ?? .standard }

    /// Floor so a stray drag can't shrink the panel down to nothing.
    static let minSize = CGSize(width: 300, height: 340)
    static let maxSize = CGSize(width: 560, height: 920)
    static let defaultCustom = CGSize(width: 380, height: 560)

    static let presetKey = "panelSizePreset"
    static let customWidthKey = "panelCustomWidth"
    static let customHeightKey = "panelCustomHeight"
    static let customLockedKey = "panelCustomLocked"

    static var preset: OxinePanelSize {
        OxinePanelSize(rawValue: suite.string(forKey: presetKey) ?? OxinePanelSize.standard.rawValue) ?? .standard
    }

    static var customSize: CGSize {
        let w = suite.object(forKey: customWidthKey) as? Double ?? Double(defaultCustom.width)
        let h = suite.object(forKey: customHeightKey) as? Double ?? Double(defaultCustom.height)
        return CGSize(width: clamp(w, minSize.width, maxSize.width),
                      height: clamp(h, minSize.height, maxSize.height))
    }

    static func setCustomSize(_ size: CGSize) {
        suite.set(Double(clamp(size.width, minSize.width, maxSize.width)), forKey: customWidthKey)
        suite.set(Double(clamp(size.height, minSize.height, maxSize.height)), forKey: customHeightKey)
    }

    /// When a custom size is locked the panel can't be dragged-resized.
    static var customLocked: Bool {
        get { suite.bool(forKey: customLockedKey) }
        set { suite.set(newValue, forKey: customLockedKey) }
    }

    /// The size the panel should currently be.
    static var current: CGSize {
        preset.presetSize ?? customSize
    }

    static var isCustom: Bool { preset == .custom }

    /// Edge-dragging is only allowed for an unlocked custom size.
    static var isResizable: Bool { isCustom && !customLocked }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
    private static func clamp(_ v: Double, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        clamp(CGFloat(v), lo, hi)
    }
}

extension Notification.Name {
    /// Posted when the user changes the size preset so the panel re-lays out.
    static let panelSizeChanged = Notification.Name("panelSizeChanged")
}
