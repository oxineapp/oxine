//
// NotchEdge.swift
// DynamicNotchKit (Oxine patch)
//

import SwiftUI

/// The closed island's outline, for drawing along its edge: handed to
/// `DynamicNotch.compactEdge`, whose view is laid over the island in the
/// island's own view and frame, so whatever it draws moves with the island
/// in the same animation.
public struct NotchEdge {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    /// A line of `width` along the edge (the sides and bottom, not the top),
    /// wholly outside the island, so the physical cutout the island covers
    /// never hides part of it. Stroked twice as wide with the inside cut away.
    public func line<S: ShapeStyle>(_ style: S, width: CGFloat) -> some View {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius, open: true)
            .stroke(style, style: StrokeStyle(lineWidth: width * 2, lineCap: .round, lineJoin: .round))
            .mask {
                Rectangle()
                    .padding(-width * 2)
                    .overlay {
                        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
    }
}
