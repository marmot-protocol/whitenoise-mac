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
        let colors = AvatarPalette.colors(for: seed)

        return Text(DisplayText.initials(for: initials, fallback: seed))
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(colors.content)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(colors.fill)
            }
            .modifier(
                AvatarChromeModifier(isSelected: isSelected, isEnabled: drawsChrome, ringColor: colors.border))
    }
}

/// Applies the shared avatar ring + drop shadow. Centralized so `AvatarView` and
/// `ProfileImageAvatarView` stay visually identical and only one of them draws it.
struct AvatarChromeModifier: ViewModifier {
    let isSelected: Bool
    var isEnabled = true
    /// The unselected ring. Initials avatars pass their accent's border token, which is what makes
    /// a pale fill read as an object against a light window; photo avatars keep
    /// `neutralRing`, the same split the Flutter client draws between its image and initials
    /// avatars. Selection still wins over both — the ring is a focus affordance first.
    var ringColor: Color = neutralRing

    /// Hairline for avatars that are showing a picture rather than initials.
    static let neutralRing = Color.white.opacity(0.2)

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? MessagesPalette.sentBubble : ringColor,
                            lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        } else {
            content
        }
    }
}

/// The avatar fills, ported from the Flutter client's design system (`lib/utils/avatar_color.dart`
/// + `lib/theme/semantic_colors.dart`): twelve Tailwind accent ramps, selected by the same
/// arithmetic on the same seed, so a person or group wears one color across both apps. The seeds
/// already agree — a DM keys on the peer's account id hex, a group on its group id hex, on both
/// sides.
///
/// Each accent contributes three tokens rather than a single hue, and the assignment inverts
/// between appearances, which is the whole character of the treatment: a **pale fill with deep
/// tinted initials** in Aqua, a **deep fill with pale tinted initials** in Dark Aqua, ringed in
/// both by the ramp's `200` step.
///
/// | token | Aqua | Dark Aqua |
/// | --- | --- | --- |
/// | fill | `50` | `950` |
/// | content (initials) | `900` | `50` |
/// | border | `200` | `200` |
///
/// Three things worth knowing before touching this, all measured:
///
/// 1. **The initials are the most legible part, and that is where identity lives.** Ink over fill
///    runs 8.4:1 to 14.7:1 across all twelve accents in both appearances, because the two tokens
///    swap ends of the ramp together. But the *fills alone barely differ* — the `50` steps of
///    twelve Tailwind ramps are all near-white, with blue and sky only 0.016 apart in summed
///    channel distance. What tells two people apart is the ink and the ring, not the disc.
/// 2. **This appearance-dependence is designed, unlike an opacity flip.** Two full token sets are
///    specified per ramp, so contrast is preserved by construction rather than by luck. That is the
///    opposite of resolving one translucent color against two different backdrops, the trap
///    documented on `MentionChipPalette` below.
/// 3. **The disc is deliberately soft in Aqua, and softer here than in Flutter.** The Flutter
///    client draws these on pure white/black; `windowBackgroundColor` is `#ECECEC`/`#323232`. In
///    Dark Aqua the `200` ring sits 8.6:1–11:1 against the window, a crisp outline. In Aqua both
///    fill and ring land within 1.01–1.26 of the window, so the edge is carried by hue plus the
///    drop shadow in `AvatarChromeModifier` rather than by luminance. That shadow, which Flutter
///    has no equivalent of, is doing real work on the gray macOS window — do not drop it.
///
/// `AvatarChromeModifier` therefore takes the `200` step as its `ringColor` for initials avatars,
/// keeping the neutral hairline for the ones showing a picture.
enum AvatarPalette {
    /// The twelve accents in the Flutter client's `AvatarColor` declaration order. `accentIndex(for:)`
    /// indexes into this array with that client's arithmetic, so reordering these silently recolors
    /// every avatar on one platform.
    private static let accents: [AvatarColorSet] = [
        accent("blue", step50: 0xEFF6FF, step200: 0xBFDBFE, step900: 0x1E3A8A, step950: 0x172554),
        accent("cyan", step50: 0xECFEFF, step200: 0xA5F3FC, step900: 0x164E63, step950: 0x083344),
        accent("emerald", step50: 0xECFDF5, step200: 0xA7F3D0, step900: 0x064E3B, step950: 0x022C22),
        accent("fuchsia", step50: 0xFDF4FF, step200: 0xF5D0FE, step900: 0x701A75, step950: 0x4A044E),
        accent("indigo", step50: 0xEEF2FF, step200: 0xC7D2FE, step900: 0x312E81, step950: 0x1E1B4B),
        accent("lime", step50: 0xF7FEE7, step200: 0xD9F99D, step900: 0x365314, step950: 0x1A2E05),
        accent("orange", step50: 0xFFF7ED, step200: 0xFED7AA, step900: 0x7C2D12, step950: 0x431407),
        accent("rose", step50: 0xFFF1F2, step200: 0xFECDD3, step900: 0x881337, step950: 0x4C0519),
        accent("sky", step50: 0xF0F9FF, step200: 0xBAE6FD, step900: 0x0C4A6E, step950: 0x082F49),
        accent("teal", step50: 0xF0FDFA, step200: 0x99F6E4, step900: 0x134E4A, step950: 0x042F2E),
        accent("violet", step50: 0xF5F3FF, step200: 0xDDD6FE, step900: 0x4C1D95, step950: 0x2E1065),
        accent("amber", step50: 0xFFFBEB, step200: 0xFDE68A, step900: 0x78350F, step950: 0x451A03),
    ]

    /// For seeds that do not start with a hex digit. The Flutter client logs and falls back here
    /// too; the only such seed in this app is the still-unnamed group in the compose flow, which is
    /// keyed on its typed title because it has no group id yet.
    static let neutral = AvatarColorSet(
        // neutral100 / neutral800, neutral500 / neutral400, neutral950 / white.
        fill: dynamic("avatarFill.neutral", light: 0xF5F5F5, dark: 0x262626),
        border: dynamic("avatarBorder.neutral", light: 0x737373, dark: 0xA3A3A3),
        content: dynamic("avatarContent.neutral", light: 0x0A0A0A, dark: 0xFFFFFF))

    static var accentCount: Int { accents.count }

    static func colors(for seed: String) -> AvatarColorSet {
        guard let index = accentIndex(for: seed) else { return neutral }
        return accents[index]
    }

    /// The Flutter client's mapping: the value of the seed's **first hex digit**, modulo the accent
    /// count, or `nil` when that character is not one. Only the first character participates — two
    /// pubkeys sharing a leading nibble share a color, by design on both platforms.
    ///
    /// Note the inherited skew: a nibble spans 0...15 but there are twelve accents, so `c`-`f` wrap
    /// onto blue, cyan, emerald, and fuchsia, leaving those four twice as likely as the other
    /// eight. Kept as-is deliberately — matching the other client's assignment is the point, and
    /// `% accents.count` is exactly what it computes.
    static func accentIndex(for seed: String) -> Int? {
        guard let first = seed.first, first.isASCII, let nibble = first.hexDigitValue else { return nil }
        return nibble % accents.count
    }

    private static func accent(
        _ name: String, step50: UInt32, step200: UInt32, step900: UInt32, step950: UInt32
    ) -> AvatarColorSet {
        AvatarColorSet(
            fill: dynamic("avatarFill.\(name)", light: step50, dark: step950),
            // The one token the design system holds constant across appearances.
            border: Color(nsColor: NSColor(rgb: step200)),
            content: dynamic("avatarContent.\(name)", light: step900, dark: step50))
    }

    /// A single token that resolves per appearance at draw time. `NSColor(name:)` rather than an
    /// `@Environment(\.colorScheme)` read so that `AvatarPalette` stays a plain static API that
    /// non-`View` callers and tests can ask for colors without building a view hierarchy.
    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: name) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(rgb: dark) : NSColor(rgb: light)
            })
    }
}

/// The three tokens an avatar needs from its accent ramp. Mirrors the Flutter client's
/// `AvatarColorSet` minus `contentSecondary`, which only feeds widgets this app does not have.
struct AvatarColorSet {
    let fill: Color
    let border: Color
    let content: Color
}

extension NSColor {
    /// `0xRRGGBB` in sRGB, so the ramp tables above read as the hex the design system publishes.
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

enum MessagesPalette {
    static let sentBubble = Color(nsColor: .systemBlue)
}

/// Surface for the non-visual attachment rows: the audio player, the download/failed status rows,
/// and the document row.
///
/// Unlike the reply quote, these rows sit *beside* the bubble in `MessageBubble`'s stack rather than
/// inside it, so they never inherit `BubbleBackground`'s fill and have to bring their own.
nonisolated enum AttachmentRowPalette {
    /// The accent itself — the same fill the sent bubble uses, which is what the row's white content
    /// (play button, waveform, detail text) is drawn for.
    ///
    /// It has to stay **opaque**. A translucent white wash composites against whatever is behind the
    /// row, and what is behind it is the window background: dark in dark appearance, light in light
    /// appearance. That is how sent voice notes and documents came to render white-on-white and
    /// vanish in light mode while looking correct in dark.
    static let outgoingFill = MessagesPalette.sentBubble

    /// Received rows stay on a wash, which is safe here because `.primary` flips with the
    /// appearance — it darkens the light backdrop and lightens the dark one.
    static let incomingFill = Color.primary.opacity(0.06)

    static func fill(isOutgoing: Bool) -> Color {
        isOutgoing ? outgoingFill : incomingFill
    }
}

/// The background chip drawn behind an `@mention`'s glyphs, Signal's treatment: the mention keeps
/// the body font, weight, and inherited foreground, and is set off by its fill alone. Each chip is
/// the bubble's own fill pushed a step further, never a different hue — a mention should look like
/// part of the bubble, not like something pasted into it.
///
/// The chip has to hold up over four different fills — the accent-filled sent bubble, plus the light
/// and dark neutral fills shared by received bubbles, agent rows, and the composer. No single
/// translucent wash does that, which is why the previous `primary.opacity(0.14)` read as smudged
/// text everywhere: `.primary` flips direction between the appearances, so it darkened one neutral
/// fill and lightened the other, too faintly to register either way.
///
/// Direction is per fill, and it is not a free choice. The sent bubble and the light neutral fill
/// both take a darker chip. The dark neutral fill cannot: it is already close to black, so even a
/// 45%-black wash only reaches 1.43 contrast against it, while a light step of the same gray reaches
/// 1.86. There it steps lighter instead — same achromatic family, just the only direction with room.
///
/// Measured against the fill behind it (WCAG contrast, chip vs. bubble), every combination lands at
/// 1.84–1.87 where the old chip managed 1.19–1.55, and the inherited body text keeps 6.1:1 or
/// better against the chip:
///
/// | fill | chip | chip ÷ fill | was | text ÷ chip |
/// | --- | --- | --- | --- | --- |
/// | sent, light | `#0053AD` | 1.84 | 1.29 | 7.39 |
/// | sent, dark | `#075AAD` | 1.87 | 1.19 | 6.83 |
/// | received, light | `#AEAEAE` | 1.86 | 1.37 | 9.47 |
/// | received, dark | `#616161` | 1.86 | 1.55 | 6.19 |
///
/// `nonisolated` because a message's attributed string is built off-main while mapping a timeline
/// window (whitenoise-mac#285), so these must be reachable from outside the main actor.
nonisolated enum MentionChipPalette {
    /// Over the accent-filled sent bubble: the same blue, pushed distinctly darker. One value for
    /// both appearances, because that fill is blue in either.
    static let onSentBubble = Color.black.opacity(0.32)

    /// Over a neutral fill: the same gray, one step away. Which way depends on the appearance — the
    /// light fill has room to go darker, the dark fill only has room to go lighter — so this is a
    /// dynamic color resolved at draw time rather than a fixed overlay.
    static let neutralFillTextBackground = NSColor(name: "mentionChipOnNeutralFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.20)
            : NSColor(white: 0.0, alpha: 0.26)
    }

    /// SwiftUI twin of `neutralFillTextBackground`. The composer's `NSTextView` draft token takes
    /// the AppKit one; both are the same chip, because the draft sits on the same neutral surface a
    /// received bubble does.
    static let onNeutralFill = Color(nsColor: neutralFillTextBackground)

    static func color(on fill: MarkdownMentionFill) -> Color {
        switch fill {
        case .neutral: onNeutralFill
        case .sentBubble: onSentBubble
        }
    }
}

enum MessagesLayout {
    static let accountRailWidth: CGFloat = 80
    static let accountRailControlSize: CGFloat = 44
    static let accountRailAvatarSize: CGFloat = 46
    static let accountRailAvatarFrameSize: CGFloat = 58
    static let sidebarTitlebarTopPadding: CGFloat = 42
}

/// Semantic type ramp for the messenger chrome, so text stays on the system typeface at the
/// platform's native sizes and tracks the user's text-size settings, instead of per-view
/// hardcoded pixel sizes.
enum MessagesType {
    static let paneTitle = Font.title2.weight(.semibold)
    static let rowTitle = Font.body.weight(.semibold)
    static let rowLabel = Font.body
    static let preview = Font.callout
    static let meta = Font.subheadline
    static let sectionHeader = Font.subheadline.weight(.semibold)
    static let badge = Font.subheadline.weight(.semibold)
}

struct MessagesSearchField: View {
    @Binding var text: String
    var accessibilityIdentifier: String?
    var placeholder = L10n.string("Search")
    var autofocus = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .accessibilityIdentifier(accessibilityIdentifier ?? "search.field")

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            MessagesSearchFieldBackground()
        }
        .task {
            if autofocus {
                isFocused = true
            }
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

/// The shared "liquid glass" recipe used by every chrome surface: a blurred
/// material under a scheme-aware tint. Each surface wraps this with its own
/// background-extension / safe-area composition (the order differs between the
/// `Messages*` and `Glass*` families), so only the duplicated inner fill lives
/// here.
struct GlassFill: View {
    @Environment(\.colorScheme) private var colorScheme
    var material: Material = .regularMaterial
    var darkOpacity: Double
    var lightOpacity: Double
    var lightTint: NSColor = .windowBackgroundColor

    var body: some View {
        ZStack {
            Rectangle()
                .fill(material)
            Color(nsColor: colorScheme == .dark ? .black : lightTint)
                .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
        }
    }
}

struct MessagesWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color(red: 0.055, green: 0.055, blue: 0.058)
                    : Color(red: 0.975, green: 0.975, blue: 0.965)
            )
            .ignoresSafeArea()
    }
}

struct MessagesTranscriptBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color(red: 0.055, green: 0.055, blue: 0.058)
                    : Color(nsColor: .textBackgroundColor)
            )
            .ignoresSafeArea()
    }
}

struct MessagesSidebarBackground: View {
    enum Level {
        case rail
        case drawer
    }

    let level: Level
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(backgroundColor)
            .ignoresSafeArea()
    }

    private var backgroundColor: Color {
        if colorScheme == .dark {
            switch level {
            case .rail:
                return Color(red: 0.18, green: 0.18, blue: 0.18)
            case .drawer:
                return Color(red: 0.145, green: 0.145, blue: 0.145)
            }
        } else {
            switch level {
            case .rail:
                return Color(red: 0.84, green: 0.84, blue: 0.82)
            case .drawer:
                return Color(red: 0.90, green: 0.90, blue: 0.88)
            }
        }
    }
}

struct MessagesHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color(red: 0.055, green: 0.055, blue: 0.058)
                    : Color(nsColor: .textBackgroundColor)
            )
    }
}

struct MessagesComposerBarBackground: View {
    var body: some View {
        GlassFill(material: .ultraThinMaterial, darkOpacity: 0.42, lightOpacity: 0.2)
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
    let opacity: Double

    var body: some View {
        GlassFill(darkOpacity: opacity * 0.42, lightOpacity: opacity * 0.32)
            .ignoresSafeArea()
            .nativeBackgroundExtensionEffect()
    }
}

struct GlassToolbarBackground: View {
    var body: some View {
        GlassFill(material: .ultraThinMaterial, darkOpacity: 0.24, lightOpacity: 0.34)
            .nativeBackgroundExtensionEffect()
    }
}

struct LiquidGlassBackground: View {
    var body: some View {
        GlassFill(darkOpacity: 0.18, lightOpacity: 0.28)
            .ignoresSafeArea()
            .nativeBackgroundExtensionEffect()
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
    func menuLabelIcons() -> some View {
        labelStyle(.titleAndIcon)
    }

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

/// Shared 28×28 circular glass dismiss/back control for sheet and column chrome.
struct GlassCircleCloseButton: View {
    let symbol: String
    let helpText: String
    let action: () -> Void

    init(
        symbol: String = "xmark",
        help: String = "Close",
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.helpText = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .nativeGlassCircleButtonStyle()
        .help(L10n.string(helpText))
    }
}
