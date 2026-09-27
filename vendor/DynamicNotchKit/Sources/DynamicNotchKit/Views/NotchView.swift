//
//  NotchView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI

struct NotchView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var compactLeadingWidth: CGFloat = 0
    @State private var compactTrailingWidth: CGFloat = 0
    @State private var compactBottomHeight: CGFloat = 0

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var expandedNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        if case let .notch(topCornerRadius, bottomCornerRadius) = dynamicNotch.style {
            (top: topCornerRadius, bottom: bottomCornerRadius)
        } else {
            (top: 15, bottom: 20)
        }
    }

    private var compactNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        (top: 6, bottom: 14)
    }

    private var minWidth: CGFloat {
        dynamicNotch.notchSize.width + (topCornerRadius * 2)
    }

    private var topCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.top : compactNotchCornerRadii.top
    }

    private var bottomCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.bottom : compactNotchCornerRadii.bottom
    }

    private var xOffset: CGFloat {
        if dynamicNotch.state != .compact {
            0
        } else {
            compactXOffset
        }
    }

    private var compactXOffset: CGFloat {
        (compactTrailingWidth - compactLeadingWidth) / 2
    }

    var body: some View {
        notchContent()
            .background {
                Rectangle()
                    .foregroundStyle(.black)
                    .padding(-50) // The opening/closing animation can overshoot, so this makes sure that it's still black
            }
            .mask {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .padding(.horizontal, 0.5)
                .frame(
                    width: dynamicNotch.state != .hidden ? nil : minWidth,
                    height: dynamicNotch.state != .hidden ? nil : dynamicNotch.notchSize.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // The edge draws along the same shape in the same frame as the
            // mask, so it moves exactly as the island does.
            .overlay {
                if dynamicNotch.state == .compact, let edge = dynamicNotch.compactEdge {
                    edge(NotchEdge(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
                        .padding(.horizontal, 0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .offset(x: xOffset)
            .animation(.smooth, value: [compactLeadingWidth, compactTrailingWidth, compactBottomHeight])
    }

    private func notchContent() -> some View {
        ZStack {
            compactContent()
                .fixedSize()
                .offset(x: dynamicNotch.state == .compact ? 0 : compactXOffset)
                .frame(
                    width: dynamicNotch.state == .compact ? nil : dynamicNotch.notchSize.width,
                    height: compactHeight
                )

            expandedContent()
                .fixedSize()
                .frame(
                    maxWidth: dynamicNotch.state == .expanded ? nil : 0,
                    maxHeight: dynamicNotch.state == .expanded ? nil : 0
                )
                .offset(x: dynamicNotch.state == .compact ? -compactXOffset : 0)
        }
        .padding(.horizontal, topCornerRadius)
        .fixedSize()
        .frame(minWidth: minWidth, minHeight: dynamicNotch.notchSize.height)
        .onHover(perform: dynamicNotch.updateHoverState)
    }

    /// The ears' height, plus the bottom row while it shows (Oxine patch).
    private var compactHeight: CGFloat {
        guard dynamicNotch.state == .compact else { return dynamicNotch.notchSize.height }
        if compactBottomHeight > 0 { return dynamicNotch.notchSize.height + compactBottomHeight }
        return dynamicNotch.isHovering ? dynamicNotch.menubarHeight : dynamicNotch.notchSize.height
    }

    func compactContent() -> some View {
        VStack(spacing: 0) {
            // Fixed so the ears never take extra width from the row below:
            // they'd stretch, measure wider, widen the row, and latch wide.
            compactEars()
                .fixedSize()
            if dynamicNotch.state == .compact, let bottom = dynamicNotch.compactBottom {
                bottom
                    .environment(\.notchCompactWidth, compactLeadingWidth + dynamicNotch.notchSize.width + compactTrailingWidth)
                    .frame(minWidth: compactLeadingWidth + dynamicNotch.notchSize.width + compactTrailingWidth)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { compactBottomHeight = $0 }
            }
        }
        .onChange(of: dynamicNotch.state) { _ in
            if dynamicNotch.state != .compact { compactBottomHeight = 0 }
        }
    }

    func compactEars() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactLeading {
                dynamicNotch.compactLeadingContent
                    .environment(\.notchSection, .compactLeading)
                    .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactLeadingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .trailing)).combined(with: .opacity))
            }

            Spacer()
                .frame(width: dynamicNotch.notchSize.width)

            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactTrailing {
                dynamicNotch.compactTrailingContent
                    .environment(\.notchSection, .compactTrailing)
                    .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactTrailingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .leading)).combined(with: .opacity))
            }
        }
        .frame(height: dynamicNotch.notchSize.height)
        .onChange(of: dynamicNotch.disableCompactLeading) { _ in
            if dynamicNotch.disableCompactLeading {
                compactLeadingWidth = 0
            }
        }
        .onChange(of: dynamicNotch.disableCompactTrailing) { _ in
            if dynamicNotch.disableCompactTrailing {
                compactTrailingWidth = 0
            }
        }
    }

    func expandedContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .expanded {
                dynamicNotch.expandedContent
                    .transition(.blur(intensity: 10).combined(with: .scale(y: 0.6, anchor: .top)).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: dynamicNotch.notchSize.height) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: dynamicNotch.expandedInset) }
        .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: dynamicNotch.expandedInset) }
        .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: dynamicNotch.expandedInset) }
        .frame(minWidth: dynamicNotch.notchSize.width)
    }
}
