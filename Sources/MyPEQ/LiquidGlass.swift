//  LiquidGlass.swift
//  Apple Liquid Glass design primitives honoring Light/Dark Mode, Reduce Transparency,
//  Reduce Motion, Dynamic Type, and native iOS 26 `.glassEffect()` with iOS 17-18 fallbacks.

import AVKit
import SwiftUI

public struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            if !reduceTransparency {
                RadialGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [
                        Color.cyan.opacity(colorScheme == .dark ? 0.16 : 0.08),
                        Color.clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 40,
                    endRadius: 460
                )
            }
        }
        .ignoresSafeArea()
    }
}

public struct SpecularGlassBorder: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let cornerRadius: CGFloat
    private let isHighlighted: Bool

    public init(cornerRadius: CGFloat = 24, isHighlighted: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHighlighted = isHighlighted
    }

    public func body(content: Content) -> some View {
        let highContrast = colorSchemeContrast == .increased
        let topOpacity: Double = isHighlighted
            ? 0.80
            : (colorScheme == .dark ? (highContrast ? 0.42 : 0.28) : (highContrast ? 0.65 : 0.72))
        let midOpacity: Double = isHighlighted
            ? 0.35
            : (colorScheme == .dark ? 0.08 : 0.18)
        let bottomOpacity: Double = isHighlighted
            ? 0.48
            : (colorScheme == .dark ? 0.16 : 0.25)

        let colors: [Color] = isHighlighted
            ? [
                Color.accentColor.opacity(topOpacity),
                Color.white.opacity(midOpacity),
                Color.accentColor.opacity(bottomOpacity)
            ]
            : [
                Color.white.opacity(topOpacity),
                Color.primary.opacity(midOpacity),
                Color.white.opacity(bottomOpacity)
            ]

        return content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHighlighted ? 1.5 : (highContrast ? 1.25 : 0.9)
                )
        }
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat
    private let isHighlighted: Bool

    public init(cornerRadius: CGFloat = 24, isHighlighted: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isHighlighted = isHighlighted
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                if reduceTransparency {
                    shape.fill(Color(.secondarySystemGroupedBackground))
                } else {
                    shape.fill(isHighlighted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
                }
            }
            .modifier(SpecularGlassBorder(cornerRadius: cornerRadius, isHighlighted: isHighlighted))
            .shadow(
                color: isHighlighted
                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16)
                    : Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: isHighlighted ? 14 : 10,
                x: 0,
                y: 4
            )
    }
}

public struct FloatingLiquidGlassBarModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 24) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .background(shape.fill(Color(.secondarySystemGroupedBackground)))
                .modifier(SpecularGlassBorder(cornerRadius: cornerRadius))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                legacyBar(content: content, shape: shape)
            }
            #else
            legacyBar(content: content, shape: shape)
            #endif
        }
    }

    private func legacyBar<S: Shape>(content: Content, shape: S) -> some View {
        content
            .background(shape.fill(.regularMaterial))
            .modifier(SpecularGlassBorder(cornerRadius: cornerRadius))
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.10),
                radius: 14,
                x: 0,
                y: 6
            )
    }
}

public extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 24, isHighlighted: Bool = false) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isHighlighted: isHighlighted))
    }

    func floatingLiquidGlassBar(cornerRadius: CGFloat = 24) -> some View {
        modifier(FloatingLiquidGlassBarModifier(cornerRadius: cornerRadius))
    }
}

public struct AirPlayRoutePickerButton: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .systemBlue
        picker.accessibilityLabel = "Select Audio Output Route"
        return picker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .label
        uiView.activeTintColor = .systemBlue
    }
}
