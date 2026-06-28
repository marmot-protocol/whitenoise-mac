//
//  MessengerDesign.swift
//  whitenoise-mac
//
//  Shared design-system components: avatars, palettes, Messages-style
//  backgrounds, and the Glass* chrome + View modifiers. Extracted verbatim
//  from MessengerShellView.swift (no behavior change).
//

import AppKit
import SwiftUI

struct AvatarView: View {
    let seed: String
    let initials: String
    let size: CGFloat
    let isSelected: Bool
    /// Whether this view draws its own ring + drop shadow. Set to `false` when a wrapper
    /// (e.g. `ProfileImageAvatarView`) already owns the chrome, to avoid double-drawing it.
    var drawsChrome = true

    var body: some View {
        Text(DisplayText.initials(for: initials, fallback: seed))
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(AvatarPalette.gradient(for: seed))
            }
            .modifier(AvatarChromeModifier(isSelected: isSelected, isEnabled: drawsChrome))
    }
}

/// Applies the shared avatar ring + drop shadow. Centralized so `AvatarView` and
/// `ProfileImageAvatarView` stay visually identical and only one of them draws it.
struct AvatarChromeModifier: ViewModifier {
    let isSelected: Bool
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? MessagesPalette.sentBubble : Color.white.opacity(0.2),
                            lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        } else {
            content
        }
    }
}

enum AvatarPalette {
    private static let palettes: [[Color]] = [
        [Color(white: 0.24), Color(white: 0.46)],
        [Color(white: 0.30), Color(white: 0.58)],
        [Color(white: 0.18), Color(white: 0.42)],
        [Color(white: 0.36), Color(white: 0.64)],
        [Color(white: 0.22), Color(white: 0.54)],
    ]

    static func gradient(for seed: String) -> LinearGradient {
        // Use a deterministic hash so a given seed always maps to the same
        // palette across launches. `String.hashValue` is seeded with
        // per-process randomness (unstable colors) and `abs(_:)` traps on
        // `Int.min`; an unsigned FNV-1a over the UTF-8 bytes avoids both.
        let index = Int(stableHash(seed) % UInt64(palettes.count))
        return LinearGradient(colors: palettes[index], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// FNV-1a (64-bit) over the seed's UTF-8 bytes. Deterministic across
    /// launches and overflow-safe via wrapping arithmetic.
    private static func stableHash(_ seed: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3  // FNV prime
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

enum MessagesPalette {
    static let sentBubble = Color(nsColor: .systemBlue)
}

struct MessagesSearchField: View {
    @Binding var text: String
    var accessibilityIdentifier: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityIdentifier(accessibilityIdentifier ?? "search.field")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            MessagesSearchFieldBackground()
        }
    }
}

struct MessagesCircleControlBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var isSelected = false
    var isActive = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay {
                Circle()
                    .stroke(strokeColor, lineWidth: 1)
            }
            .nativeBackgroundExtensionEffect()
    }

    private var fillColor: Color {
        if isActive {
            return Color.red.opacity(colorScheme == .dark ? 0.28 : 0.18)
        }
        if isSelected {
            return Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18)
    }

    private var strokeColor: Color {
        if isActive {
            return Color.red.opacity(colorScheme == .dark ? 0.42 : 0.30)
        }
        return Color.white.opacity(colorScheme == .dark ? 0.08 : 0.32)
    }
}

struct MessagesSidebarRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                isSelected
                    ? Color.white.opacity(colorScheme == .dark ? 0.13 : 0.28)
                    : Color.clear
            )
    }
}

struct MessagesSearchFieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28), lineWidth: 1)
            }
    }
}

struct MessagesSendButtonBackground: View {
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(isEnabled ? MessagesPalette.sentBubble : Color.white.opacity(0.08))
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
            }
    }
}

struct MessagesComposerFieldBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.32), lineWidth: 1)
            }
    }
}

struct MessagesWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.52 : 0.2)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

struct MessagesTranscriptBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .textBackgroundColor)
                .opacity(colorScheme == .dark ? 0.72 : 0.52)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

struct MessagesSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Level {
        case rail
        case drawer
    }

    let level: Level

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(backgroundOpacity)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }

    private var backgroundOpacity: Double {
        if colorScheme == .dark {
            switch level {
            case .rail: 0.5
            case .drawer: 0.44
            }
        } else {
            switch level {
            case .rail: 0.16
            case .drawer: 0.1
            }
        }
    }
}

struct MessagesHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.34 : 0.18)
        }
        .nativeBackgroundExtensionEffect()
        .ignoresSafeArea()
    }
}

struct MessagesComposerBarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.42 : 0.2)
        }
        .nativeBackgroundExtensionEffect()
    }
}

struct GlassSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .vertical

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.08))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18))
            }
    }
}

struct GlassPaneBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let opacity: Double

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? opacity * 0.42 : opacity * 0.32)
        }
        .ignoresSafeArea()
    }
}

struct GlassToolbarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.24 : 0.34)
        }
    }
}

struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            background
                .backgroundExtensionEffect()
        } else {
            background
        }
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.18 : 0.28)
        }
        .ignoresSafeArea()
    }
}

struct GlassRoundedBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 8
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor ?? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34), lineWidth: 1)
            }
            .nativeBackgroundExtensionEffect()
    }
}

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    func body(content: Content) -> some View {
        content
            .background {
                GlassRoundedBackground(
                    cornerRadius: cornerRadius,
                    material: material,
                    borderColor: borderColor
                )
            }
    }
}

struct GlassCapsuleBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var borderColor: Color?

    var body: some View {
        // Flat translucent fill instead of `.ultraThinMaterial`. A material capsule renders a
        // `CABackdropLayer` blur per instance — fine once, but these are per-row chrome
        // (reactions, system notices), and rendering every visible one was a measurable slice
        // of initial-render / scroll cost (Instruments: CA::Render::copy_image / -[CAFilter
        // CA_copyRenderValue]). `.quaternary` is a solid, adaptive hierarchical fill that reads
        // almost identically without the backdrop pass. See the #205 scroll-performance work.
        Capsule(style: .continuous)
            .fill(.quaternary)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(borderColor ?? Color.white.opacity(colorScheme == .dark ? 0.14 : 0.3), lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(
        cornerRadius: CGFloat = 8,
        material: Material = .ultraThinMaterial,
        borderColor: Color? = nil
    ) -> some View {
        modifier(
            GlassCardModifier(
                cornerRadius: cornerRadius,
                material: material,
                borderColor: borderColor
            ))
    }

    @ViewBuilder
    func nativeGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// A circular glass icon button (e.g. close / cancel "✕" controls).
    @ViewBuilder
    func nativeGlassCircleButtonStyle() -> some View {
        self
            .buttonBorderShape(.circle)
            .nativeGlassButtonStyle()
    }

    @ViewBuilder
    func nativeGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func nativeBackgroundExtensionEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }

    @ViewBuilder
    func nativeWindowGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self
                .containerBackground(.windowBackground, for: .window)
                .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        } else {
            self.background(.regularMaterial)
        }
    }
}
