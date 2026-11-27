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
            .wnFont(.custom(size: size * 0.34, weight: .bold))
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
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool
    var isEnabled = true
    /// The unselected ring. Initials avatars pass their accent's border token, which is what makes
    /// a pale fill read as an object against a light window; photo avatars keep `neutralRing`, the
    /// same split the other clients draw between their image and initials avatars.
    var ringColor: Color = neutralRing

    /// Hairline for avatars that are showing a picture rather than initials. `borderTertiary`, the
    /// palette's resting border, rather than the white wash this used to be: a wash lightens
    /// whatever is behind it, so it only read as a hairline in one of the two appearances.
    static let neutralRing = WNColor.borderTertiary

    /// How much the selected avatar grows. Size is the affordance that reads in both appearances,
    /// so it carries selection on its own where the ring cannot, and is applied as a scale so no
    /// neighbour is pushed around when the selection moves.
    static let selectedScale: CGFloat = 1.15

    /// Blur radius of the drop shadow. Named because `overhang(forAvatarSize:)` has to add it —
    /// a literal here and a literal there would drift apart.
    static let shadowRadius: CGFloat = 2

    /// How far this chrome reaches *outside* the avatar's own frame, per side: half of the width
    /// `selectedScale` adds, plus the shadow's blur.
    ///
    /// Both effects draw beyond the frame they are applied to, so an avatar seated flush against
    /// a clipping container's edge loses that much of its ring — a circle with a flat side, which
    /// is what it looks like rather than a subtle one. Any container that clips (a `ScrollView`,
    /// a `clipShape`) has to leave this much slack around an avatar on its edge.
    static func overhang(forAvatarSize size: CGFloat) -> CGFloat {
        size * (selectedScale - 1) / 2 + shadowRadius
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(strokeColor, lineWidth: 3)
                    }
                }
                .shadow(color: WNColor.shadow.opacity(0.1), radius: Self.shadowRadius, y: 1)
                .scaleEffect(isSelected ? Self.selectedScale : 1)
        } else {
            content
        }
    }

    /// The one place in the app that reads the appearance to pick a token, and it is deliberate:
    /// what the selection ring has to contrast with is the avatar's own accent fill, and that fill
    /// is itself inverted between appearances (the ramp's `950` step in dark, `50` in light). In
    /// dark, `borderPrimary` is white and a white ring on a deep fill is the clearest selection
    /// mark in the app. In light the same token is near-black, and a heavy near-black ring around a
    /// pale disc reads as an outlined object rather than a selected one — so light keeps the
    /// avatar's own ring and lets `selectedScale` say which one is active.
    private var strokeColor: Color {
        guard isSelected, colorScheme == .dark else { return ringColor }
        return WNColor.borderPrimary
    }
}

nonisolated enum AvatarPalette {
    /// The twelve accents in the other clients' `AvatarColor` declaration order.
    /// `accentIndex(for:)` indexes into this array with that client's arithmetic, so reordering
    /// these silently recolors every avatar on one platform.
    ///
    /// The ramp values themselves live once, in `WNAccentColors` — these are the same sets the
    /// palette hands to mentions and anything else that identifies a person, viewed through the
    /// three tokens an avatar needs.
    private static let accents: [WNAccentColorSet] = [
        WNAccentColors.blue,
        WNAccentColors.cyan,
        WNAccentColors.emerald,
        WNAccentColors.fuchsia,
        WNAccentColors.indigo,
        WNAccentColors.lime,
        WNAccentColors.orange,
        WNAccentColors.rose,
        WNAccentColors.sky,
        WNAccentColors.teal,
        WNAccentColors.violet,
        WNAccentColors.amber,
    ]

    /// For seeds that do not start with a hex digit. The other clients log and fall back here too;
    /// the only such seed in this app is the still-unnamed group in the compose flow, which is
    /// keyed on its typed title because it has no group id yet.
    ///
    /// Neutral is the one set drawn from the semantic fills rather than an accent, which is what
    /// `WnAvatar` does with `AvatarColor.neutral`.
    static let neutral = AvatarColorSet(
        fill: WNColor.fillSecondary,
        border: WNColor.borderSecondary,
        content: WNColor.fillContentSecondary)

    static var accentCount: Int { accents.count }

    static func colors(for seed: String) -> AvatarColorSet {
        guard let index = accentIndex(for: seed) else { return neutral }
        return AvatarColorSet(accents[index])
    }

    /// The whole accent set at `index`, for the callers that need a rung the three avatar ones do
    /// not carry, and the only way to enumerate the ramps from outside — which is what the palette
    /// tests walk to hold every accent to the same contrast floor.
    static func accent(at index: Int) -> WNAccentColorSet {
        accents[index]
    }

    /// The other clients' mapping: the value of the seed's **first hex digit**, modulo the accent
    /// count, or `nil` when that character is not one. Only the first character participates — two
    /// pubkeys sharing a leading nibble share a color, by design on every platform.
    ///
    /// Note the inherited skew: a nibble spans 0...15 but there are twelve accents, so `c`-`f` wrap
    /// onto blue, cyan, emerald, and fuchsia, leaving those four twice as likely as the other
    /// eight. Kept as-is deliberately — matching the other clients' assignment is the point, and
    /// `% accents.count` is exactly what they compute.
    static func accentIndex(for seed: String) -> Int? {
        guard let first = seed.first, first.isASCII, let nibble = first.hexDigitValue else { return nil }
        return nibble % accents.count
    }
}

/// The three tokens an avatar needs from its accent ramp. Mirrors the other clients'
/// `AvatarColorSet` minus `contentSecondary`, the `500` step no avatar draws — reach for
/// `WNAccentColors` directly if you need that one.
nonisolated struct AvatarColorSet {
    let fill: Color
    let border: Color
    let content: Color

    init(fill: Color, border: Color, content: Color) {
        self.fill = fill
        self.border = border
        self.content = content
    }

    fileprivate init(_ accent: WNAccentColorSet) {
        self.init(fill: accent.fill, border: accent.border, content: accent.contentPrimary)
    }
}

/// `nonisolated` for the same reason `AttachmentRowPalette` below is: the bubble fills are read
/// while a message's display content is built off the main actor.
nonisolated enum MessagesPalette {
    /// The sent bubble's fill: `fillPrimary`, the same token the primary button takes.
    /// It is inverted against the surface rather than an accent hue, which is why a sent
    /// bubble is near-black in light appearance and white in dark — White Noise has no
    /// blue "my messages" color, on any client.
    static let sentBubble = WNColor.fillPrimary

    /// Content on the sent bubble. Pairs with `sentBubble` and crosses over with it, so it
    /// is white on the light appearance's dark bubble and near-black on the dark
    /// appearance's white one. Never substitute a literal `.white` here.
    static let sentBubbleContent = WNColor.fillContentPrimary

    /// The received bubble's fill, and the content that goes on it.
    static let receivedBubble = WNColor.backgroundMessageIncoming
    static let receivedBubbleContent = WNColor.backgroundContentPrimary

    static func bubbleFill(isOutgoing: Bool) -> Color {
        isOutgoing ? sentBubble : receivedBubble
    }

    static func bubbleContent(isOutgoing: Bool) -> Color {
        isOutgoing ? sentBubbleContent : receivedBubbleContent
    }
}

/// Which text bubble a view is drawn on, and the foreground set that goes with it (F02, T02, T07).
///
/// Everything drawn inside a text bubble takes its color from here: body, footer metadata, the
/// quoted-reply inset and its text, links, and Markdown's secondary runs. A role from the window's
/// own family looks right on one bubble and fails on the other, because the sent bubble inverts
/// against the window and the received one does not.
///
/// The received bubble uses native roles (`secondarySystemFill`, `labelColor`,
/// `secondaryLabelColor`, `systemFill`, `linkColor`). The sent bubble keeps the inverted primary
/// fill and its paired content, with its secondary roles crossing over the same way.
/// Rich message cards (polls, unsupported events, link/Nostr previews) and attachment rows share
/// these same roles across both polarities (#1113).
nonisolated enum MessageBubblePolarity: Hashable, Sendable {
    case sent
    case received

    init(isOutgoing: Bool) {
        self = isOutgoing ? .sent : .received
    }

    var fill: Color { Color(nsColor: nsFill) }

    /// The body text and any glyph that has to read at full strength.
    var content: Color { Color(nsColor: nsContent) }

    /// Footer metadata, the quoted body, a deleted message's label, and Markdown's quieter runs.
    var secondaryContent: Color { Color(nsColor: nsSecondaryContent) }

    var quoteFill: Color { Color(nsColor: nsQuoteFill) }

    var link: Color { Color(nsColor: nsLink) }

    /// The single dynamic `NSColor` mapping for each bubble role, shared by both SwiftUI views
    /// (via `Color(nsColor:)`) and contrast tests.
    var nsFill: NSColor {
        switch self {
        case .sent: WNNSColor.fillPrimary
        case .received: WNNSColor.messageReceivedFill
        }
    }

    var nsContent: NSColor {
        switch self {
        case .sent: WNNSColor.fillContentPrimary
        case .received: WNNSColor.textPrimary
        }
    }

    var nsSecondaryContent: NSColor {
        switch self {
        case .sent: WNNSColor.messageSentSecondaryContent
        case .received: WNNSColor.messageReceivedSecondaryContent
        }
    }

    var nsQuoteFill: NSColor {
        switch self {
        case .sent: WNNSColor.messageSentQuoteFill
        case .received: WNNSColor.messageReceivedQuoteFill
        }
    }

    var nsLink: NSColor {
        switch self {
        case .sent: WNNSColor.messageSentLink
        case .received: WNNSColor.messageReceivedLink
        }
    }
}

extension EnvironmentValues {
    /// The bubble the text below is drawn on, set by `MessageBubble` around its text content. Nil
    /// outside a bubble, where text keeps the window's roles.
    @Entry var messageBubblePolarity: MessageBubblePolarity? = nil
}

/// The native text styles of a chat message (F04, T02). Every caller that draws a message's text
/// or reserves room for it reads its style from here, so the visible footer and the transparent
/// copy that reserves its width on the last line use the same font. The transcript measures each
/// row through SwiftUI at the column width, so these sizes and the cached row heights always agree.
nonisolated enum MessageTypography {
    static let body: Font = .body
    static let bodySemibold: Font = .body.weight(.semibold)
    static let senderName: Font = .callout.weight(.medium)
    static let footer: Font = .caption
    static let quoteSender: Font = .callout.weight(.semibold)
    static let quoteBody: Font = .callout
    static let dayDivider: Font = .subheadline.weight(.semibold)
}

/// Shared color roles for cards embedded inside a message bubble (link previews, Nostr event
/// previews), falling back to standard surface tokens when rendered outside a bubble (#1113).
nonisolated struct MessageEmbeddedCardPalette {
    let polarity: MessageBubblePolarity?

    var surfaceFill: Color { polarity?.quoteFill ?? WNColor.backgroundPrimary }
    var primaryContent: Color { polarity?.content ?? WNColor.textPrimary }
    var secondaryContent: Color { polarity?.secondaryContent ?? WNColor.messageReceivedSecondaryContent }
    var imageSlotFill: Color { polarity.map { $0.content.opacity(0.08) } ?? WNColor.fillSecondary }
    var hairlineStroke: Color { polarity.map { $0.content.opacity(0.12) } ?? WNColor.borderTertiary }
}

/// Surface for the non-visual attachment rows: the audio player, the download/failed status rows,
/// and the document row.
///
/// Unlike the reply quote, these rows sit *beside* the bubble in `MessageBubble`'s stack rather than
/// inside it, so they never inherit `BubbleBackground`'s fill and have to bring their own.
nonisolated enum AttachmentRowPalette {
    static func fill(isOutgoing: Bool) -> Color {
        Color(nsColor: nsFill(isOutgoing: isOutgoing))
    }

    static func content(isOutgoing: Bool) -> Color {
        Color(nsColor: nsContent(isOutgoing: isOutgoing))
    }

    /// The disc behind a play/status glyph, and the unplayed waveform. Derived from the row's own
    /// content color so it steps away from the fill in whichever direction that fill has room —
    /// the alternative, a fixed white or black wash, is only correct in one of the four
    /// fill × appearance combinations.
    ///
    /// The opacities below are set against measured contrast, not by eye. `content` over `fill` is
    /// a ~14:1 pair in all four fill × appearance combinations, so an opacity here reads almost
    /// directly as a fraction of that: 0.14 left the disc at 1.4:1, invisible enough that the well
    /// the play button sits in read as an artifact of the fill rather than as a control.
    static let controlFillOpacity = 0.24

    static func controlFill(isOutgoing: Bool) -> Color {
        content(isOutgoing: isOutgoing).opacity(controlFillOpacity)
    }

    /// 0.58 is the iOS client's own figure for this bar, and it is the step that clears 3:1
    /// against every bubble fill — 0.42 held only where the content color was the light one
    /// (4.05:1 outgoing in light appearance) and fell to 2.84:1 where it was the dark one, which
    /// is how a waveform came to read as washed-out grey on half the rows in the app.
    static let waveformBarOpacity = 0.58

    static func waveformBar(isOutgoing: Bool) -> Color {
        content(isOutgoing: isOutgoing).opacity(waveformBarOpacity)
    }

    static let waveformPlayedBarOpacity = 0.9

    static func waveformPlayedBar(isOutgoing: Bool) -> Color {
        content(isOutgoing: isOutgoing).opacity(waveformPlayedBarOpacity)
    }

    /// Detail text inside an attachment row — file size, duration — stepped back from the row's
    /// primary content at 0.72 opacity so both outgoing and incoming rows clear WCAG AA 4.5:1
    /// contrast in both appearances.
    static let detailContentOpacity = 0.72

    static func nsFill(isOutgoing: Bool) -> NSColor {
        MessageBubblePolarity(isOutgoing: isOutgoing).nsFill
    }

    static func nsContent(isOutgoing: Bool) -> NSColor {
        MessageBubblePolarity(isOutgoing: isOutgoing).nsContent
    }

    static func nsDetailContent(isOutgoing: Bool) -> NSColor {
        NSColor(name: nil) { _ in
            nsContent(isOutgoing: isOutgoing).withAlphaComponent(detailContentOpacity)
        }
    }

    static func detailContent(isOutgoing: Bool) -> Color {
        Color(nsColor: nsDetailContent(isOutgoing: isOutgoing))
    }
}

enum MessagesLayout {
    /// Room a top-of-window header leaves for the traffic lights, which float over the content
    /// in a `.hiddenTitleBar` window.
    static let sidebarTitlebarTopPadding: CGFloat = 42
    /// The same header once a window-level notice band holds the top edge. The band contains the
    /// traffic lights, so a header below it needs only its own breathing room — keeping the full
    /// clearance would open 42pt of dead air under the band.
    static let sidebarTitlebarPaddingBelowNoticeBand: CGFloat = 12
    /// Least height at which a full-width top notice still covers the traffic lights rather than
    /// being crossed by them: measured with `standardWindowButton`, the buttons run from 9pt to
    /// 23pt below the window's top edge, so this leaves 15pt under them. A *minimum* — the
    /// notice's own padding wins when its content is taller.
    static let windowTopNoticeBandMinimumHeight: CGFloat = 38
    /// Horizontal strip the traffic lights own: they end 69pt in, plus their own 9pt margin
    /// again on the far side. Centred notice content is held out of it so a narrow window
    /// slides the text right rather than under the buttons.
    static let windowTrafficLightZoneWidth: CGFloat = 78
    static let chatRowAvatarSize: CGFloat = 38
    /// The active profile's avatar in Settings' sidebar.
    ///
    /// Deliberately the same value as `chatRowAvatarSize`: those are the app's identity rows, and
    /// an identity should not be a different size depending on which list it is standing in.
    static let settingsProfileAvatarSize: CGFloat = 38
    /// Footprint of `GlassCircleCloseButton`. Named because a pane header has to reserve the
    /// same width on the opposite side to keep its title centred in the pane.
    static let circleControlSize: CGFloat = 28
    /// The group's avatar at the top of group info.
    static let groupDetailsAvatarSize: CGFloat = 72

    /// Top padding for a header on the window's top edge, given whether a window-level notice
    /// band is already there holding the traffic lights.
    nonisolated static func sidebarTitlebarPadding(hasWindowTopNoticeBand: Bool) -> CGFloat {
        hasWindowTopNoticeBand ? sidebarTitlebarPaddingBelowNoticeBand : sidebarTitlebarTopPadding
    }
}

/// Semantic type ramp for the messenger chrome, naming the roles the shell uses so a view
/// asks for "the row title" rather than for a size.
enum MessagesType {
    static let paneTitle = WNTextStyle.semiBold18
    static let rowTitle = WNTextStyle.semiBold14
    static let rowLabel = WNTextStyle.medium14
    static let preview = WNTextStyle.medium12
    static let meta = WNTextStyle.medium12
    static let sectionHeader = WNTextStyle.semiBold12
    static let badge = WNTextStyle.semiBold12
}

struct MessagesSearchField: View {
    @Binding var text: String
    var accessibilityIdentifier: String?
    var placeholder = L10n.string("Search")
    var autofocus = false
    /// Each new value puts focus back in the field, for a search reopened while already showing.
    var focusRequest: UUID?
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    /// The field had focus when a `.disabled` ancestor took it. AppKit resigns a disabled field's
    /// editor and SwiftUI never hands it back, so without this the user has to click back in after
    /// every disable (the add-members sheet disables the field while Invite resolves a paste).
    @State private var regainsFocusWhenEnabled = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.primary)
                .focused($isFocused)
                // Searches take names, npubs and pasted keys: a correction or a capitalized first
                // letter offered over "npub1…" is never what the user meant.
                .autocorrectionDisabled()
                .accessibilityIdentifier(accessibilityIdentifier ?? "search.field")

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
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
        .onChange(of: focusRequest) { _, _ in
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                regainsFocusWhenEnabled = true
            } else if isEnabled {
                // Lost while enabled: the user moved on, so a later re-enable must not pull focus back.
                regainsFocusWhenEnabled = false
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled, regainsFocusWhenEnabled {
                isFocused = true
            }
        }
    }
}

/// The round icon controls in the composer, the account rail, and the conversation header.
///
/// These are the other clients' `WnIconButton` in its `outline` form: a `fillSecondary` disc inside a
/// `borderTertiary` ring, stepping to the active fill when selected. There is no destructive form:
/// a live microphone replaces the whole composer with `VoiceRecordingComposerView` rather than
/// recoloring this control, and nothing else here is destructive.
struct MessagesCircleControlBackground: View {
    var isSelected = false

    var body: some View {
        Circle()
            .fill(isSelected ? WNColor.fillSecondaryActive : WNColor.fillSecondary)
            .overlay {
                Circle()
                    .stroke(WNColor.borderTertiary, lineWidth: 1)
            }
    }
}

struct MessagesSearchFieldBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            }
    }
}

/// The composer's text field: a Liquid Glass pill on macOS 26+ (material fallback on macOS 15.6)
/// so scrolled transcript content refracts softly behind the floating composer.
struct MessagesComposerFieldBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
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
    /// The wash laid over the material. `backgroundPrimary` already inverts between
    /// appearances — white over the light material, black over the dark one — so only the
    /// strength of the wash still has to be chosen per appearance.
    var tint: Color = WNColor.backgroundPrimary

    var body: some View {
        ZStack {
            Rectangle()
                .fill(material)
            tint
                .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
        }
    }
}

/// The window's base surface, behind every pane (F02/F03: native `windowBackgroundColor`).
struct MessagesWindowBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
    }
}

/// The transcript, the detail panes, and the settings pages: native macOS window reading surface.
struct MessagesTranscriptBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
    }
}

/// The conversation header, which reads as part of the transcript below it.
struct MessagesHeaderBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
    }
}

struct MessagesComposerBarBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
    }
}

/// The app's hairline. `borderTertiary` is the resting border on every other client — by a wide
/// margin the most-used border token there — and a separator is exactly that: a border with nothing
/// on either side of it.
struct GlassSeparator: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .vertical

    var body: some View {
        Rectangle()
            .fill(WNColor.borderTertiary)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

struct LiquidGlassBackground: View {
    var body: some View {
        GlassFill(darkOpacity: 0.18, lightOpacity: 0.28)
            .ignoresSafeArea()
    }
}

struct GlassRoundedBackground: View {
    var cornerRadius: CGFloat = 8
    var material: Material = .ultraThinMaterial
    var borderColor: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor ?? WNColor.borderTertiary, lineWidth: 1)
            }
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
    /// The pill's surface. Defaults to the secondary fill, which is what a day header or a system
    /// notice sits on; a reaction chip overrides it because it is drawn *on a bubble* rather than
    /// on the app surface, and `fillSecondary` is the received bubble's own value.
    var fill: Color = WNColor.fillSecondary
    var borderColor: Color?

    var body: some View {
        // Flat fill instead of `.ultraThinMaterial`. A material capsule renders a
        // `CABackdropLayer` blur per instance — fine once, but these are per-row chrome
        // (day headers, system notices), and rendering every visible one was a measurable slice
        // of initial-render / scroll cost (Instruments: CA::Render::copy_image / -[CAFilter
        // CA_copyRenderValue]). See the #205 scroll-performance work. `fillSecondary` keeps that
        // property — it is a plain opaque color, so there is no backdrop pass at all — and it is
        // the token the other clients put behind a pill, where `.quaternary` was the system's
        // hierarchical gray and belonged to no palette.
        Capsule(style: .continuous)
            .fill(fill)
            .overlay {
                if let borderColor {
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
            }
    }
}

/// The chat bubble's silhouette: one continuous radius on all four corners, clamped to half the
/// bubble's height so a short message resolves to a capsule.
///
/// This replaced an `UnevenRoundedRectangle` that tucked the sender's bottom corner in to 6pt —
/// a tail. The iOS prototype draws no tail: both bubbles are the same symmetric shape and the
/// side they are pinned to is what says who sent them. Clamping is why the shape is a `Shape`
/// rather than a rounded rectangle at a fixed radius — the radius depends on the rect, and a
/// one-line bubble is exactly the case the clamp is for.
struct MessageBubbleShape: Shape {
    /// The resting radius, for content tall enough to take it.
    static let cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: min(rect.height / 2, Self.cornerRadius),
            style: .continuous
        )
        .path(in: rect)
    }
}

/// The pin marker on a pinned chat's avatar: the glyph on a `backgroundPrimary` disc inside a
/// `borderTertiary` hairline, nudged onto the avatar's bottom-trailing corner.
///
/// It sits on the avatar rather than beside the title — the prototype's placement — for two
/// reasons. The title line is where a chat's *name* competes with its timestamp and its status
/// capsules, and pinning is the one row state that is true of the whole row rather than of its
/// last message; and the avatar corner is a slot the collapsed row already uses, so the same mark
/// survives the drawer narrowing to avatars.
///
/// The disc is opaque `backgroundPrimary` rather than a wash because it is drawn over an avatar
/// whose fill is an accent ramp step — a translucent mark would take that accent's hue and stop
/// reading as chrome.
struct ChatAvatarPinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .padding(3)
            .background {
                Circle()
                    .fill(WNColor.backgroundPrimary)
                    .overlay {
                        Circle()
                            .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
                    }
            }
            .offset(x: 2, y: 2)
            .accessibilityLabel(L10n.string("Pinned"))
    }
}

extension View {
    func menuLabelIcons() -> some View {
        labelStyle(.titleAndIcon)
    }

    /// Native macOS 26+ Liquid Glass floating control chrome with a clean material fallback on
    /// macOS 15.6 (no hard dark ring around translucent controls).
    @ViewBuilder
    func wnFloatingGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        }
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

/// Shared 28×28 circular dismiss/back control for sheet and column chrome.
///
/// Two appearances, because the two jobs are not the same weight. A **close** ✕ is the only
/// control in its corner and takes the glass disc. A **back** ‹ is navigation sitting beside a
/// title, and glass gives it the emphasis of a filled control — so it takes `outline` instead:
/// `MessagesCircleControlBackground`, the `WnIconButton.outline` disc this app already draws for
/// the composer and account-rail controls. That puts every back affordance on the secondary tier,
/// matching the settings header's chevron and `.wnSecondaryButtonStyle()`.
///
/// Note that circle control still strokes `borderTertiary`, which is the same value as its own
/// `fillSecondary` in Dark Aqua — so its ring is invisible there. The push tier moved to native
/// `.bordered` chrome (`.wnSecondaryButtonStyle()`). The demotion from glass holds either way; giving
/// the discs a visible edge — or a lift — is a separate change, because it also restyles the
/// composer and the account rail.
struct GlassCircleCloseButton: View {
    enum Appearance {
        /// The glass disc. For a ✕ that dismisses and is meant to read as prominent.
        case glass
        /// The palette's outline circle. For a ‹ that navigates back, or a ✕ that should not
        /// compete with the content it sits above.
        case outline
    }

    let symbol: String
    let helpText: String
    let appearance: Appearance
    let action: () -> Void

    init(
        symbol: String = "xmark",
        help: String = "Close",
        appearance: Appearance = .glass,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.helpText = help
        self.appearance = appearance
        self.action = action
    }

    var body: some View {
        switch appearance {
        case .glass:
            Button(action: action) {
                Image(systemName: symbol)
                    .wnFont(.semiBold12)
                    .frame(width: MessagesLayout.circleControlSize, height: MessagesLayout.circleControlSize)
            }
            // Named for the same reason `WNPrimaryButton` names it: `.glass` carries no colour and
            // tints from the environment, whose only app-wide source is `ContentView`. Every
            // caller of this branch is inside a `sheet`, which inherits none of it — so the disc
            // did not draw at all and the ✕ was left as a bare glyph.
            .tint(WNColor.fillPrimary)
            .nativeGlassCircleButtonStyle()
            .help(L10n.string(helpText))

        case .outline:
            Button(action: action) {
                Image(systemName: symbol)
                    .wnFont(.semiBold12)
                    // Named rather than inherited: the glyph sits on `fillSecondary`, so it is
                    // the `fill` family's content token that pairs with it. The app-wide default
                    // is `backgroundContentPrimary`, which currently resolves to the same value —
                    // true by coincidence, not by construction. See the pairing rule in `WNNSColor`.
                    .foregroundStyle(WNColor.fillContentSecondary)
                    .frame(width: MessagesLayout.circleControlSize, height: MessagesLayout.circleControlSize)
                    .background { MessagesCircleControlBackground() }
            }
            .buttonStyle(.plain)
            .help(L10n.string(helpText))
        }
    }
}
