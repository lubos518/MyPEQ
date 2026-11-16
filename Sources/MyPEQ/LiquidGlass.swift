//  LiquidGlass.swift
//  Clean native iOS grouped surfaces honoring Light/Dark Mode and system contrast.

import SwiftUI

public struct LiquidGlassBackground: View {
    public init() {}

    public var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
}

public struct SpecularGlassBorder: ViewModifier {
    private let cornerRadius: CGFloat
    private let isHighlighted: Bool

    public init(cornerRadius: CGFloat = 20, isHighlighted: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHighlighted = isHighlighted
    }

    public func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor : Color(.separator),
                    lineWidth: isHighlighted ? 1.5 : 0.5
                )
        }
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let isHighlighted: Bool

    public init(cornerRadius: CGFloat = 20, isHighlighted: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHighlighted = isHighlighted
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background(shape.fill(Color(.secondarySystemGroupedBackground)))
            .modifier(SpecularGlassBorder(cornerRadius: cornerRadius, isHighlighted: isHighlighted))
    }
}

public struct FloatingLiquidGlassBarModifier: ViewModifier {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 20) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background(shape.fill(Color(.secondarySystemGroupedBackground)))
            .modifier(SpecularGlassBorder(cornerRadius: cornerRadius))
    }
}

public extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 20, isHighlighted: Bool = false) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isHighlighted: isHighlighted))
    }

    func floatingLiquidGlassBar(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingLiquidGlassBarModifier(cornerRadius: cornerRadius))
    }
}
