//
//  EnvironmentValues+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-03-26.
//

import SwiftUI

extension EnvironmentValues {
    @Entry var notchStyle: DynamicNotchStyle = .auto
    @Entry var notchSection: DynamicNotchSection = .expanded
    /// Oxine patch: the compact island's content width (ears plus cutout),
    /// given to `compactBottom` so it can match the notch instead of widening it.
    @Entry public var notchCompactWidth: CGFloat = 0
}

enum DynamicNotchSection {
    case expanded
    case compactLeading
    case compactTrailing
}
