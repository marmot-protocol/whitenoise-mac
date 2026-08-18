//
//  SettingsViews.swift
//  whitenoise-mac
//
//  The settings surface: SettingsPanelView and every settings page/row
//  (profile, identity keys, appearance, preferences, privacy/security, audit logs,
//  notifications, developer mode, relays, key packages). Switching between
//  identities is not a page here — it lives in the switcher at the top of the
//  settings drawer, in SettingsAccountSwitcherViews.swift.
//

import AppKit
import CoreImage
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPanelView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var page: SettingsPage {
        if case .settings(let page) = workspace.selection { return page }
        return .overview
    }

    var body: some View {
        Group {
            switch page {
            case .overview:
                ProfileSettingsView()
            case .preferences:
                PreferencesSettingsView()
            case .profile:
                ProfileSettingsView()
            case .identityKeys:
                IdentityKeysSettingsView()
            case .relays:
                RelaySettingsView()
            case .keyPackages:
                KeyPackageSettingsView()
            case .appearance:
                AppearanceSettingsView()
            case .privacySecurity:
                PrivacySecuritySettingsView()
            case .notifications:
                NotificationsSettingsView()
            case .storage:
                StorageSettingsView()
            case .developerMode:
                DeveloperModeSettingsView()
            }
        }
        // The same surface the transcript and the group/contact detail panes draw on, rather than
        // the glass wash this used to be. A settings page is a reading surface in the content
        // column, so it takes the reading surface: `backgroundPrimary`. The glass wash never
        // reached that value in light appearance — a material over `backgroundSecondary` with a
        // partial white tint lands visibly grayer than the chat beside it, which is the whole
        // complaint. Glass stays where it belongs in settings: the header (`GlassToolbarBackground`)
        // and the sheets that lift off this pane.
        .background {
            MessagesTranscriptBackground()
        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadSettingsData()
        }
    }
}

/// The small day-to-day choices that are not about how the app looks: startup, and which
/// six emoji the message actions offer. Quick reactions used to sit under Appearance, next
/// to theme and language, where a choice about interaction was hard to find.
struct PreferencesSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Preferences"),
            subtitle: L10n.string("Choose how White Noise starts up and how it behaves in chats.")
        ) {
            Section(L10n.string("Startup")) {
                Toggle(
                    L10n.string("Launch White Noise at Login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                Text(L10n.string("Open the White Noise window automatically when you log in to your Mac."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)

                launchAtLoginStatus

                Divider()

                Toggle(
                    L10n.string("Restore last selected chat"),
                    isOn: Binding(
                        get: { workspace.restoreLastSelectedChat },
                        set: { workspace.setRestoreLastSelectedChat($0) }
                    )
                )

                Text(
                    L10n.string(
                        "Return to the last conversation selected for this account, both on launch and when you switch accounts."
                    )
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            QuickReactionsSettingsSection()
        }
        .onAppear {
            launchAtLogin.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Login Items can be changed outside White Noise. Treat ServiceManagement as
            // the source of truth whenever the app returns from System Settings.
            launchAtLogin.refresh()
        }
    }

    @ViewBuilder
    private var launchAtLoginStatus: some View {
        if let error = launchAtLogin.errorMessage {
            SettingsErrorView(error: error)
        }

        switch launchAtLogin.status {
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    L10n.string("White Noise needs approval in Login Items before it can open at login."),
                    systemImage: "exclamationmark.triangle"
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)

                Button(L10n.string("Open Login Items Settings")) {
                    launchAtLogin.openSystemSettings()
                }
                .buttonStyle(.wnSecondary)
            }
        case .notFound:
            Label(
                L10n.string("macOS could not find White Noise's login item."),
                systemImage: "exclamationmark.triangle"
            )
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
        case .notRegistered, .enabled:
            EmptyView()
        }
    }
}

/// Lives in `PreferencesSettingsView`, as its own view so that page stays readable.
struct QuickReactionsSettingsSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var quickReactionBeingReplaced: Int?

    var body: some View {
        Section(L10n.string("Quick reactions")) {
            Text(L10n.string("Choose and order the six reactions shown in message actions."))
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            ForEach(Array(workspace.quickReactions.enumerated()), id: \.offset) { index, emoji in
                HStack(spacing: 12) {
                    Button {
                        quickReactionBeingReplaced = index
                    } label: {
                        Text(emoji)
                            .wnFont(.medium24)
                            .frame(width: 38, height: 32)
                            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: L10n.string("Replace quick reaction %d, currently %@"),
                            index + 1,
                            emoji
                        )
                    )
                    .popover(isPresented: replacementPopoverBinding(for: index), arrowEdge: .leading) {
                        ChatEmojiPicker(disabledEmoji: unavailableReplacementEmoji(for: index)) { replacement in
                            guard workspace.replaceQuickReaction(at: index, with: replacement) else { return }
                            quickReactionBeingReplaced = nil
                        }
                    }

                    Text(String(format: L10n.string("Quick reaction %d"), index + 1))
                        .foregroundStyle(WNColor.backgroundContentSecondary)

                    Spacer()

                    Button {
                        workspace.moveQuickReaction(at: index, by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == workspace.quickReactions.startIndex)
                    .help(L10n.string("Move earlier"))

                    Button {
                        workspace.moveQuickReaction(at: index, by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == workspace.quickReactions.index(before: workspace.quickReactions.endIndex))
                    .help(L10n.string("Move later"))
                }
            }

            Button(L10n.string("Restore defaults")) {
                workspace.restoreDefaultQuickReactions()
            }
            .buttonStyle(.wnSecondary)
            .disabled(workspace.quickReactions == ChatReactionDefaults.quick)
        }
    }

    private func replacementPopoverBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { quickReactionBeingReplaced == index },
            set: { isPresented in
                if !isPresented, quickReactionBeingReplaced == index {
                    quickReactionBeingReplaced = nil
                }
            }
        )
    }

    private func unavailableReplacementEmoji(for index: Int) -> Set<String> {
        Set(
            workspace.quickReactions.enumerated().compactMap { offset, emoji in
                offset == index ? nil : emoji
            }
        )
    }
}

struct SettingsHeader: View {
    let title: String
    var subtitle: String?
    var backAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let backAction {
                    Button(action: backAction) {
                        Image(systemName: "chevron.left")
                            .wnFont(.semiBold14)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.wnSecondary)
                    .help(L10n.string("Back to settings"))
                }

                Text(title)
                    .wnFont(.semiBold18)

                Spacer()
            }

            if let subtitle {
                Text(subtitle)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background {
            GlassToolbarBackground()
        }
    }
}

struct SettingsNativeForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsScaffold<Content: View>: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: String
    var subtitle: String?
    var errorSectionTitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        errorSectionTitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.errorSectionTitle = errorSectionTitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: title, subtitle: subtitle)
            Divider()

            SettingsNativeForm {
                content
                errorSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = workspace.lastError {
            if let errorSectionTitle {
                Section(errorSectionTitle) {
                    SettingsErrorView(error: error)
                }
            } else {
                Section {
                    SettingsErrorView(error: error)
                }
            }
        }
    }
}

/// The scaffold for a settings page that lays its own controls out rather than filling native
/// grouped `Form` rows: same header, same error surface, but the content sits in a plain
/// scrolling column. A page built from `WNCallout`, `WNCopyCard` and `SettingsLabeledField` needs
/// this — those controls draw their own box, and a grouped `Section` would put a second one
/// around each.
struct SettingsStackScaffold<Content: View>: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: String
    var subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: title, subtitle: subtitle)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content

                    if let error = workspace.lastError {
                        SettingsErrorView(error: error)
                    }
                }
                // A form reads badly when its fields stretch the full width of a wide window,
                // so the column is capped and centred while the scroll view keeps the pane.
                .frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RemoveAccountConfirmationModifier: ViewModifier {
    let account: AccountItem?
    @Binding var isPresented: Bool
    let isRemoveDisabled: Bool
    let onRemove: () -> Void

    private static var message: String {
        L10n.string(
            "This deletes the private key and local message history for this identity from this Mac. This cannot be undone."
        )
    }

    private static func title(for account: AccountItem?) -> String {
        guard let account else { return L10n.string("Remove account?") }
        return String(format: L10n.string("Remove %@?"), account.displayName)
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Self.title(for: account),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Account"), role: .destructive) {
                onRemove()
            }
            .disabled(isRemoveDisabled)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(Self.message)
        }
    }
}

extension View {
    func removeAccountConfirmation(
        account: AccountItem?,
        isPresented: Binding<Bool>,
        isRemoveDisabled: Bool,
        onRemove: @escaping () -> Void
    ) -> some View {
        modifier(
            RemoveAccountConfirmationModifier(
                account: account,
                isPresented: isPresented,
                isRemoveDisabled: isRemoveDisabled,
                onRemove: onRemove
            )
        )
    }
}

/// How prominent the QR affordance is at a given call site.
enum PublicIdentityQRCodeButtonStyle {
    /// A bare glyph sitting inside a row of other text — an account switcher entry, a key row.
    case inline
    /// A tile that stands next to a `WNCopyCard` and matches its height, for the screens where
    /// handing your identity to someone else is the point rather than an aside.
    case tile
}

struct PublicIdentityQRCodeButton: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isPresented = false
    @State private var isHovering = false
    let accountIdHex: String
    let displayName: String
    var style: PublicIdentityQRCodeButtonStyle = .inline

    private var npub: String {
        workspace.npub(forAccountIdHex: accountIdHex)
    }

    var body: some View {
        // The two styles differ in their button style as well as their label, and `buttonStyle`
        // has to be applied to the `Button` itself, so the branch covers the whole control.
        Group {
            switch style {
            case .inline:
                Button {
                    isPresented = true
                } label: {
                    Image(systemName: "qrcode")
                        .wnFont(.semiBold14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            case .tile:
                Button {
                    isPresented = true
                } label: {
                    Image(systemName: "qrcode")
                        .wnFont(.medium24)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .frame(width: 56)
                        .frame(maxHeight: .infinity)
                        .background(
                            isHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary,
                            in: .rect(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(.rect(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
            }
        }
        .help(L10n.string("Show npub QR code"))
        .accessibilityLabel(Text(L10n.string("Show npub QR code")))
        .sheet(isPresented: $isPresented) {
            PublicIdentityQRCodeSheet(displayName: displayName, npub: npub)
        }
    }
}

struct PublicIdentityQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let displayName: String
    let npub: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .wnFont(.semiBold16)
                        .lineLimit(1)
                    Text(L10n.string("Public identity"))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                // Outline rather than glass: the ✕ is the only way out of this sheet, but it is
                // not the thing to look at — the code is. See `GlassCircleCloseButton.Appearance`.
                GlassCircleCloseButton(appearance: .outline) {
                    dismiss()
                }
            }

            ZStack {
                // The same surface the code's own quiet zone is rendered in, so the padding around
                // it is continuous with it rather than a border. See `QRCodePalette`.
                WNColor.backgroundPrimary
                // Encode the marmot:// profile link form so scanners can route the
                // scheme; the visible text and Copy button keep the bare npub.
                QRCodeImageView(payload: MarmotProfileLink.qrPayload(npub: npub))
                    .padding(22)
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WNColor.borderTertiary, lineWidth: 1)
            }

            // Head and tail are cut to what fits beside the copy glyph on one line at this
            // sheet's width; the button still copies the whole npub. Same shape as
            // `CopyableKeyLabel`, which cannot be reused here because the sheet is handed a
            // resolved npub rather than an account id.
            HStack(spacing: 8) {
                Text(DisplayText.short(npub, head: 20, tail: 16))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(
                            isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background {
            LiquidGlassBackground()
        }
    }
}

private nonisolated struct RenderedQRCodeImage: @unchecked Sendable {
    let nsImage: NSImage
}

/// One appearance's resolved QR colors, flattened to components so the Core Image work can happen
/// off the main actor. Resolved rather than carried as a dynamic `NSColor` deliberately: a QR code
/// is rasterized once into a bitmap that has no appearance of its own, so the two colors have to be
/// pinned at render time and the bitmap re-rendered when the appearance changes.
struct QRCodeInk: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? .black
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
    }

    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue) }

    /// The resolved color as AppKit sees it — a static color, since the whole point of this type is
    /// that the appearance has already been chosen.
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The palette's own QR pair: `qrCode` modules on `backgroundPrimary`. Both invert with the
/// appearance, which is the point — a code pinned to black-on-white sits as a lit card in a dark
/// window. A conforming decoder reads either polarity (asserted in `SemanticPaletteTests`); what it
/// cannot read is a tinted or low-contrast code, which is why neither of these is an accent.
struct QRCodePalette: Equatable, Sendable {
    let modules: QRCodeInk
    let background: QRCodeInk

    @MainActor
    static func resolved(for colorScheme: ColorScheme) -> QRCodePalette {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        var modules = QRCodeInk(WNNSColor.qrCode)
        var background = QRCodeInk(WNNSColor.backgroundPrimary)
        // Resolving under the *view's* scheme rather than the drawing appearance already current:
        // the two can disagree while an appearance override is settling, and a code rendered under
        // the wrong one would sit inverted against the sheet until the payload changed.
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            modules = QRCodeInk(WNNSColor.qrCode)
            background = QRCodeInk(WNNSColor.backgroundPrimary)
        }
        return QRCodePalette(modules: modules, background: background)
    }
}

struct QRCodeImageView: View {
    let payload: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedPayload: String?
    @State private var renderedPalette: QRCodePalette?
    @State private var renderedImage: NSImage?

    private var isRendered: Bool {
        renderedPayload == payload && renderedPalette == QRCodePalette.resolved(for: colorScheme)
    }

    var body: some View {
        Group {
            if isRendered, let renderedImage {
                Image(nsImage: renderedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else if isRendered {
                ContentUnavailableView("QR code unavailable", systemImage: "qrcode")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        // Keyed on the appearance as well as the payload: the rasterized code carries no appearance
        // of its own, so switching Aqua and Dark Aqua has to re-render it rather than re-resolve it.
        .task(id: QRCodeRenderKey(payload: payload, palette: QRCodePalette.resolved(for: colorScheme))) {
            let palette = QRCodePalette.resolved(for: colorScheme)
            let image = await Task.detached(priority: .utility) {
                Self.image(for: payload, palette: palette)
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = image?.nsImage
            renderedPayload = payload
            renderedPalette = palette
        }
    }

    nonisolated static func ciImage(for payload: String, palette: QRCodePalette) -> CIImage? {
        guard !payload.isEmpty,
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        // `CIQRCodeGenerator` hands back opaque black modules on an opaque white quiet zone, so the
        // `backgroundPrimary` behind this view never showed through — recoloring is what actually
        // puts the code on the app's surface instead of on a white card.
        guard let falseColor = CIFilter(name: "CIFalseColor") else { return scaledImage }
        falseColor.setValue(scaledImage, forKey: kCIInputImageKey)
        falseColor.setValue(palette.modules.ciColor, forKey: "inputColor0")
        falseColor.setValue(palette.background.ciColor, forKey: "inputColor1")
        return falseColor.outputImage ?? scaledImage
    }

    nonisolated private static func image(for payload: String, palette: QRCodePalette) -> RenderedQRCodeImage? {
        guard let ciImage = ciImage(for: payload, palette: palette) else { return nil }
        let representation = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return RenderedQRCodeImage(nsImage: image)
    }
}

private struct QRCodeRenderKey: Equatable {
    let payload: String
    let palette: QRCodePalette
}

struct SettingsErrorView: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .textSelection(.enabled)
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsStackScaffold(
            title: L10n.string("Profile"),
            subtitle: L10n.string("Publish the profile other people see for this identity.")
        ) {
            if let account = workspace.activeAccount {
                ProfileIdentityHeaderView(
                    account: account,
                    displayName: profilePreviewName(fallback: account)
                )
            }

            WNCallout(
                title: L10n.string("Your profile is public"),
                message: L10n.string(
                    "Name, photo, and bio are visible on the global Nostr network. Use what you're comfortable sharing."
                ),
                intent: .info
            )

            SettingsLabeledField(label: L10n.string("Name")) {
                TextField(L10n.string("Enter your name"), text: $workspace.profileDraft.displayName)
            }

            SettingsLabeledField(label: L10n.string("About"), minHeight: 88) {
                TextField(
                    L10n.string("Introduce yourself"),
                    text: $workspace.profileDraft.about,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }

            HStack {
                WNPrimaryButton(
                    workspace.isSavingProfile ? L10n.string("Saving...") : L10n.string("Save profile"),
                    systemImage: "checkmark.circle",
                    size: .large
                ) {
                    Task { await workspace.saveProfile() }
                }
                .disabled(workspace.isSavingProfile || workspace.activeAccount == nil)

                if workspace.isLoadingSettings {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $workspace.isProfileImagePickerPresented) {
            ProfileImagePickerSheet()
        }
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            account.displayName,
        ]) ?? account.displayName
    }
}

/// The top of the profile form: the avatar, centred and large enough to be the subject of the
/// page, over the npub and its QR code. The name is not repeated here — the Name field is the
/// next thing on the page and carries the same value live.
struct ProfileIdentityHeaderView: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem
    let displayName: String

    private let avatarSize: CGFloat = 96

    private var npub: String {
        workspace.npub(forAccountIdHex: account.accountIdHex)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                workspace.showProfileImagePicker()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: displayName,
                        sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                        isOwnAccountImage: true,
                        size: avatarSize,
                        isSelected: false
                    )

                    Image(systemName: "camera.fill")
                        .wnFont(.semiBold12)
                        .foregroundStyle(WNColor.fillContentQuaternary)
                        .frame(width: 30, height: 30)
                        .background(WNColor.overlayTertiary, in: .circle)
                }
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Change profile image"))
            .accessibilityLabel(L10n.string("Change profile image"))

            HStack(spacing: 8) {
                WNCopyCard(
                    displayText: DisplayText.grouped(npub),
                    value: npub,
                    actionDescription: L10n.string("Copy npub")
                )

                PublicIdentityQRCodeButton(
                    accountIdHex: account.accountIdHex,
                    displayName: displayName,
                    style: .tile
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}

struct ProfileImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isFileImporterPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 12)
    ]

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let account = workspace.activeAccount {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.displayName,
                        sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                        isOwnAccountImage: true,
                        size: 46,
                        isSelected: false
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Profile image"))
                        .wnFont(.semiBold14)
                    Text(L10n.string("Choose from your Mac or search the web"))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                GlassCircleCloseButton {
                    workspace.closeProfileImagePicker()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(L10n.string("Choose from Mac"), systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isUploadingProfileImage)

                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(L10n.string("Search images"), text: $workspace.profileImageSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await workspace.searchProfileImages() }
                        }

                    if workspace.isSearchingProfileImages || workspace.isUploadingProfileImage {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.searchProfileImages() }
                    } label: {
                        Label(L10n.string("Search"), systemImage: "magnifyingglass")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspace.isSearchingProfileImages
                            || workspace.isUploadingProfileImage
                    )
                }

                Text(
                    L10n.string("Search terms are sent to Openverse. Selected images are copied to Blossom before use.")
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsErrorView(error: workspace.lastError)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

                ScrollView {
                    if workspace.profileImageResults.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .wnFont(.medium28)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                            Text(
                                workspace.isSearchingProfileImages ? L10n.string("Searching") : L10n.string("No images")
                            )
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(workspace.profileImageResults) { result in
                                Button {
                                    Task { await workspace.setProfileImage(result) }
                                } label: {
                                    GroupImageResultTile(result: result)
                                }
                                .buttonStyle(.plain)
                                .disabled(workspace.isUploadingProfileImage)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
        .background {
            LiquidGlassBackground()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await workspace.setProfileImage(fileURL: url) }
            case .failure(let error):
                workspace.reportUserActionError(error.localizedDescription)
            }
        }
    }
}

struct IdentityKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveAccountConfirmation = false
    @State private var showKeyBackup = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Identity & Keys"),
            subtitle: L10n.string("Public identity details and local signing state.")
        ) {
            if let account = workspace.activeAccount {
                Section(L10n.string("Account")) {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.initials,
                            sanitizedPictureURL: account.sanitizedPictureURL,
                            isOwnAccountImage: true,
                            size: 52,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .wnFont(.semiBold14)
                                .lineLimit(1)
                            Text(accountSigningDescription(for: account))
                                .wnFont(.medium10)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                    }
                }

                Section(L10n.string("Public Identity")) {
                    let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
                    LabeledContent(L10n.string("npub")) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(npub)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            CopyToClipboardButton(
                                value: npub,
                                actionDescription: L10n.string("Copy npub")
                            ) { isConfirming in
                                Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(
                                        isConfirming
                                            ? WNColor.intentionSuccessContent
                                            : WNColor.backgroundContentPrimary)
                            }
                            .buttonStyle(.borderless)

                            PublicIdentityQRCodeButton(
                                accountIdHex: account.accountIdHex,
                                displayName: account.displayName
                            )
                        }
                    }
                }

                Section(L10n.string("Private Key")) {
                    LabeledContent(L10n.string("Private key")) {
                        Text(
                            account.localSigning
                                ? L10n.string("Stored in Keychain")
                                : L10n.string("Not stored on this Mac")
                        )
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    }

                    Button {
                        showKeyBackup = true
                    } label: {
                        Label(L10n.string("Back Up Private Key…"), systemImage: "key")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(!account.localSigning)
                    .help(
                        account.localSigning
                            ? L10n.string("Reveal your nsec or export an encrypted NIP-49 backup")
                            : L10n.string("This account has no private key stored on this Mac"))
                }

                Section(L10n.string("Account Removal")) {
                    Text(
                        L10n.string(
                            "Remove this identity from this Mac. Messages and keys managed by Marmot for this account will no longer be available locally."
                        )
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showRemoveAccountConfirmation = true
                    } label: {
                        Label(
                            workspace.isRemovingAccount ? L10n.string("Removing...") : L10n.string("Remove Account"),
                            systemImage: "person.crop.circle.badge.minus")
                    }
                    // Outline rather than red by explicit request, and with no destructive
                    // `role` to contradict that. The confirmation dialog this opens is
                    // system-rendered, so the irreversible step is still the one drawn in red.
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isAccountMutationInProgress)
                }
            } else {
                Section {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }

        }
        .removeAccountConfirmation(
            account: workspace.activeAccount,
            isPresented: $showRemoveAccountConfirmation,
            isRemoveDisabled: workspace.isAccountMutationInProgress
        ) {
            Task { await workspace.removeActiveAccount() }
        }
        .sheet(isPresented: $showKeyBackup) {
            PrivateKeyBackupSheet()
        }
    }

    private func accountSigningDescription(for account: AccountItem) -> String {
        if account.localSigning {
            return L10n.string("Local signing account")
        }
        return account.externalSigning ? L10n.string("External signing account") : L10n.string("Watch-only account")
    }
}

/// Private-key backup sheet: reveal the raw `nsec` or export a passphrase-encrypted
/// NIP-49 (`ncryptsec`) backup of the active account's signing key.
struct PrivateKeyBackupSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable {
        case nsec
        case encrypted
    }

    @State private var mode: Mode = .encrypted
    @State private var passphrase = ""
    @State private var revealedSecret: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("Back Up Private Key"))
                    .wnFont(.semiBold16)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            backupTypeSelector
                .onChange(of: mode) { _, _ in revealedSecret = nil }

            switch mode {
            case .encrypted:
                Text(L10n.string("Protect your key with a passphrase. You'll need it to restore the backup."))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(L10n.string("Passphrase"), text: $passphrase)
                    .textFieldStyle(.roundedBorder)
            case .nsec:
                // Two lines on purpose: the warning carries the risk, the footnote spells out
                // exactly what "recorded" means. The core writes a per-account audit line
                // holding only a timestamp, a salted account hash, and a surface label — never
                // the key material itself — so say so rather than leaving users to assume the
                // nsec is written to a log.
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        L10n.string("Anyone with your nsec controls this account. Never share it."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(WNColor.intentionWarningContent)

                    Text(
                        L10n.string(
                            "White Noise notes the date and time of each reveal in this account's audit log, kept on this Mac, so you can spot a reveal you didn't make. Your nsec is never written to the log."
                        )
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .wnFont(.medium12)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let revealedSecret {
                GroupBox {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(revealedSecret)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        CopyToClipboardButton(
                            value: revealedSecret,
                            actionDescription: L10n.string("Copy")
                        ) { isConfirming in
                            Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(
                                    isConfirming
                                        ? WNColor.intentionSuccessContent
                                        : WNColor.backgroundContentPrimary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await produceBackup() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .nsec ? L10n.string("Reveal nsec") : L10n.string("Export Backup"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || (mode == .encrypted && passphrase.isEmpty))
            }

            if let error = workspace.lastError {
                Text(error)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var backupTypeSelector: some View {
        HStack(spacing: 0) {
            backupTypeButton(L10n.string("Encrypted (NIP-49)"), mode: .encrypted)
            backupTypeButton(L10n.string("Raw nsec"), mode: .nsec)
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WNColor.fillSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Backup type"))
    }

    private func backupTypeButton(_ title: String, mode targetMode: Mode) -> some View {
        let isSelected = mode == targetMode
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                mode = targetMode
            }
        } label: {
            Text(title)
                .wnFont(.semiBold12)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(
                    isSelected ? WNColor.fillContentPrimary : WNColor.fillContentTertiary
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(WNColor.fillPrimary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func produceBackup() async {
        isWorking = true
        defer { isWorking = false }
        switch mode {
        case .nsec:
            revealedSecret = await workspace.revealActiveAccountNsec()
        case .encrypted:
            revealedSecret = await workspace.exportActiveAccountEncryptedKey(passphrase: passphrase)
        }
    }
}

// Shows a user's public key as a truncated `npub` (derived from the hex), with an optional
// one-click copy-to-clipboard icon. Use everywhere a pubkey is surfaced so users always see
// — and can copy — the canonical npub form rather than raw hex.
struct CopyableKeyLabel: View {
    @Environment(WorkspaceState.self) private var workspace
    let accountIdHex: String
    var head: Int = 12
    var tail: Int = 10
    var showsCopyButton: Bool = true

    var body: some View {
        let npub = workspace.npub(forAccountIdHex: accountIdHex)
        HStack(spacing: 6) {
            Text(DisplayText.short(npub, head: head, tail: tail))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if showsCopyButton {
                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                        .wnFont(.medium10)
                        .foregroundStyle(
                            isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Appearance"),
            subtitle: L10n.string("Choose how White Noise follows macOS appearance.")
        ) {
            Section(L10n.string("Appearance")) {
                Picker(L10n.string("Theme"), selection: $workspace.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }

                Picker(L10n.string("Language"), selection: $workspace.languagePreference) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Text(L10n.string("System follows your Mac language. Other choices update White Noise immediately."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showDeleteAuditLogsConfirmation = false
    @State private var showDeleteAllDataConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Privacy & Security"),
            subtitle: L10n.string("Telemetry and audit logs stay off until you enable them.")
        ) {
            Section(L10n.string("Remote Content")) {
                Toggle(
                    isOn: Binding(
                        get: { workspace.loadRemoteImages },
                        set: { workspace.loadRemoteImages = $0 }
                    )
                ) {
                    Label(
                        L10n.string("Load Remote Profile Images"),
                        systemImage: "person.crop.circle.badge.exclamationmark")
                }

                Text(
                    L10n.string(
                        "Off by default. Profile pictures come from URLs other people control, so loading them reveals your IP address and when you're online to whoever sent them. Leave this off unless you trust the senders. Only secure (https) images are ever loaded."
                    )
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            Section(L10n.string("Data Sharing")) {
                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                        set: { enabled in
                            Task { await workspace.setRelayTelemetryEnabled(enabled) }
                        }
                    )
                ) {
                    Label(L10n.string("Anonymous Telemetry"), systemImage: "waveform.path.ecg")
                }
                .disabled(workspace.isSavingPrivacySecurity)

                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.auditLoggingEnabled },
                        set: { enabled in
                            Task { await workspace.setAuditLoggingEnabled(enabled) }
                        }
                    )
                ) {
                    Label(L10n.string("Audit Logging"), systemImage: "doc.text.magnifyingglass")
                }
                .disabled(workspace.isSavingPrivacySecurity)

                if workspace.isSavingPrivacySecurity {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Saving..."))
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }
            }

            Section(L10n.string("Audit Log Files")) {
                HStack {
                    if workspace.isLoadingAuditLogFiles {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.loadAuditLogFiles() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isLoadingAuditLogFiles)
                }

                if workspace.auditLogFiles.isEmpty {
                    HStack {
                        Spacer()

                        ContentUnavailableView("No audit logs", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: 320)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(workspace.auditLogFiles, id: \.path) { file in
                        AuditLogFileRow(file: file)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.uploadAuditLogFiles() }
                    } label: {
                        Label(
                            workspace.isUploadingAuditLogFiles
                                ? L10n.string("Uploading...") : L10n.string("Upload Now"), systemImage: "arrow.up.doc")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.isUploadingAuditLogFiles
                            || !workspace.privacySecuritySettings.auditLogCredentialsAvailable
                    )

                    Button(role: .destructive) {
                        showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label(
                            workspace.isDeletingAuditLogFiles ? L10n.string("Deleting...") : L10n.string("Delete All"),
                            systemImage: "trash")
                    }
                    .disabled(workspace.auditLogFiles.isEmpty || workspace.isDeletingAuditLogFiles)
                }

                if let auditLogUploadStatus = workspace.auditLogUploadStatus {
                    Label(auditLogUploadStatus, systemImage: "checkmark.seal")
                        .foregroundStyle(WNColor.intentionSuccessContent)
                }
            }

            Section(L10n.string("Reset")) {
                Button(role: .destructive) {
                    showDeleteAllDataConfirmation = true
                } label: {
                    Label(
                        workspace.isDeletingAllData ? L10n.string("Deleting...") : L10n.string("Delete All Data"),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(WNColor.fillDestructive)
                .disabled(workspace.isAccountMutationInProgress)

                Text(L10n.string("Reset White Noise to a newly installed state on this Mac."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .task {
            await workspace.loadAuditLogFiles()
        }
        .confirmationDialog(
            L10n.string("Delete all audit logs?"),
            isPresented: $showDeleteAuditLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete All Audit Logs"), role: .destructive) {
                Task { await workspace.deleteAllAuditLogFiles() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This permanently removes every local audit JSONL file on this Mac."))
        }
        .alert(L10n.string("Delete all data?"), isPresented: $showDeleteAllDataConfirmation) {
            Button(L10n.string("Delete All Data"), role: .destructive) {
                Task { await workspace.deleteAllData() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This clears all accounts, chats, and messages from this Mac and resets White Noise to a newly installed state. This cannot be undone."
                )
            )
        }
    }
}

struct AuditLogFileRow: View {
    let file: AuditLogFileFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(file.fileName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(byteCount(file.sizeBytes))
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            Text(details)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)

            Text(file.path)
                .font(.caption2.monospaced())
                .foregroundStyle(WNColor.backgroundContentTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var parts = [shortAccountRef(file.accountRef)]
        if let modifiedAtMs = file.modifiedAtMs {
            let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000)
            parts.append(DisplayText.dateTimeTimestamp(for: date))
        }
        return parts.joined(separator: " - ")
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}

struct NotificationsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Notifications"),
            subtitle: L10n.string("Local alerts for this Mac.")
        ) {
            Section(L10n.string("Local Alerts")) {
                Toggle(
                    isOn: Binding(
                        get: { workspace.notificationSettings.localNotificationsEnabled },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                ) {
                    Label(L10n.string("Local notifications"), systemImage: "bell.badge")
                }
                .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications)

                LabeledContent(L10n.string("Permission")) {
                    HStack(spacing: 8) {
                        Text(workspace.notificationAuthorizationStatus.label)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                        if workspace.isSavingNotifications {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if workspace.notificationAuthorizationStatus == .notDetermined {
                    Button {
                        Task { await workspace.requestLocalNotificationPermission() }
                    } label: {
                        Label(L10n.string("Allow Notifications"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.wnSecondary)
                } else if workspace.notificationAuthorizationStatus == .denied {
                    Button {
                        workspace.openSystemNotificationSettings()
                    } label: {
                        Label(L10n.string("Open System Settings"), systemImage: "gear")
                    }
                    .buttonStyle(.wnSecondary)
                }
            }

            Section(L10n.string("Privacy")) {
                Picker(L10n.string("Message preview"), selection: $workspace.notificationPreviewMode) {
                    ForEach(NotificationPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!workspace.notificationSettings.localNotificationsEnabled)

                Text(workspace.notificationPreviewMode.detail)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .task {
            await workspace.refreshNotificationPermissionState()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Notification permission can be changed outside White Noise. Treat the system as
            // the source of truth whenever the app returns from System Settings, so the pane
            // stops asking for a permission the user has already granted.
            Task { await workspace.refreshNotificationPermissionState() }
        }
    }
}

struct StorageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showClearConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Storage"),
            subtitle: L10n.string("Downloaded attachments stored on this Mac.")
        ) {
            // The folder is granted by the panel on the first download, so without this row there
            // would be no way to see where files went or to move them somewhere else.
            Section(L10n.string("Downloads")) {
                LabeledContent(L10n.string("Save downloads to")) {
                    Text(
                        workspace.mediaDownloadDestinationPath
                            ?? L10n.string("Chosen the first time you download")
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Button(L10n.string("Change Folder"), systemImage: "folder") {
                    workspace.changeMediaDownloadDestination()
                }
                .buttonStyle(.wnSecondary)
            }

            Section(L10n.string("Media Cache")) {
                LabeledContent(L10n.string("Cached attachments")) {
                    if workspace.isLoadingMediaCacheFootprint {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(byteCount(workspace.mediaCacheFootprint.byteCount))
                            .monospacedDigit()
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Text(
                    L10n.string(
                        "White Noise encrypts cached attachment data on this Mac. Clearing it does not remove accounts, messages, drafts, or settings."
                    )
                )
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    showClearConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isClearingMediaCache {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label(
                            workspace.isClearingMediaCache ? L10n.string("Clearing...") : L10n.string("Clear Cache"),
                            systemImage: "trash"
                        )
                    }
                }
                // Outline rather than red by explicit request, and with no destructive `role`
                // to contradict that. The confirmation dialog it opens is system-rendered, so the
                // irreversible step is still the one drawn in red.
                .buttonStyle(.wnSecondary)
                .disabled(
                    workspace.isClearingMediaCache
                        || workspace.isLoadingMediaCacheFootprint
                        || workspace.mediaCacheFootprint.byteCount == 0
                )

                if let reclaimed = workspace.mediaCacheReclaimedByteCount {
                    Label(
                        String(
                            format: L10n.string("%@ reclaimed."),
                            byteCount(reclaimed)
                        ),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(WNColor.intentionSuccessContent)
                }
            }
        }
        .task {
            workspace.refreshMediaDownloadDestinationPath()
            await workspace.refreshMediaCacheFootprint()
        }
        .confirmationDialog(
            L10n.string("Clear media cache?"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Clear Cache"), role: .destructive) {
                Task { await workspace.clearMediaCache() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: L10n.string(
                        "This removes %@ of encrypted cached attachments. Visible media will download again when needed."
                    ),
                    byteCount(workspace.mediaCacheFootprint.byteCount)
                )
            )
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Developer mode"),
            subtitle: L10n.string("Storage and diagnostics.")
        ) {
            Section(L10n.string("Developer")) {
                Toggle(isOn: $workspace.developerMode) {
                    Label(L10n.string("Developer mode"), systemImage: "stethoscope")
                }

                Toggle(isOn: $workspace.streamingDebugMode) {
                    Label(L10n.string("Streaming debug"), systemImage: "waveform.path.ecg")
                }
                .disabled(!workspace.developerMode)
            }

            Section(L10n.string("Storage")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Location"))

                    Text(workspace.storageRootPath)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label(L10n.string("Open Storage Folder"), systemImage: "folder")
                }
                .buttonStyle(.wnSecondary)
            }

            Section(L10n.string("Diagnostics")) {
                ForEach(workspace.diagnosticsInfo) { item in
                    LabeledContent(item.title) {
                        Text(item.value)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

        }
    }
}

struct RelaySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Relays"),
            subtitle: L10n.string("Manage the relay lists published for this account.")
        ) {
            Section {
                RelayDiagnosticsView(settings: workspace.relaySettings)
            }

            Section(L10n.string("Relays")) {
                if workspace.relayDraft.isEmpty {
                    ContentUnavailableView("No relays", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minHeight: 160)
                } else {
                    ForEach(workspace.relayDraft, id: \.self) { relay in
                        RelayRow(url: relay, isInsecure: workspace.isInsecureRelay(relay)) {
                            workspace.removeRelayDraftURL(relay)
                        }
                    }
                }
            }

            Section(L10n.string("Add Relay")) {
                HStack(spacing: 8) {
                    TextField(
                        L10n.string(""), text: $workspace.newRelayURL, prompt: Text(L10n.string("wss://relay.example"))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        workspace.addRelayDraftURL()
                    }
                    .frame(maxWidth: .infinity)

                    Picker(L10n.string("Relay list"), selection: $workspace.selectedRelaySection) {
                        ForEach(RelaySettingsSection.allCases) { section in
                            Text(section.label).tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 96)
                    .onChange(of: workspace.selectedRelaySection) { _, section in
                        workspace.selectRelaySection(section)
                    }

                    Button {
                        workspace.addRelayDraftURL()
                    } label: {
                        Label(L10n.string("Add"), systemImage: "plus")
                    }
                    .buttonStyle(.wnSecondary)
                    .help(L10n.string("Add relay"))
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.saveRelaySettings() }
                    } label: {
                        Label(
                            workspace.isSavingRelays ? L10n.string("Saving...") : L10n.string("Save relays"),
                            systemImage: "checkmark.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isSavingRelays || workspace.activeAccount == nil)

                    Button {
                        workspace.restoreRelayDraftDefaults()
                    } label: {
                        Label(L10n.string("Restore defaults"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isSavingRelays)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

        }
    }
}

struct RelayDiagnosticsView: View {
    let settings: RelaySettingsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: settings.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.isComplete ? .green : .orange)
                Text(L10n.string("Published Relay Lists"))
                    .wnFont(.semiBold12)
                Spacer()
                Text(settings.isComplete ? L10n.string("Complete") : L10n.string("Missing"))
                    .wnFont(.semiBold10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            RelayDiagnosticsRow(
                title: L10n.string("NIP-65"), systemImage: "list.bullet", relays: settings.publishedNip65)
            RelayDiagnosticsRow(
                title: L10n.string("Inbox"), systemImage: "tray.and.arrow.down", relays: settings.publishedInbox)

            if !settings.missing.isEmpty {
                Text(String(format: L10n.string("Missing: %@"), settings.missing.joined(separator: ", ")))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.intentionWarningContent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RelayDiagnosticsRow: View {
    let title: String
    let systemImage: String
    let relays: [String]

    var body: some View {
        DisclosureGroup {
            if relays.isEmpty {
                Text(L10n.string("Not published"))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                // Drawn on `fillSecondary`, so it takes a `fillContent*` token rather than a
                // `backgroundContent*` one. `fillContentTertiary` is the de-emphasized step of that
                // family — the right weight for a count beside its own row title, and the same
                // `500`/`400` ramp steps this already rendered at.
                Text(verbatim: "\(relays.count)")
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.fillContentTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(WNColor.fillSecondary, in: Capsule())
                    .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            }
            .wnFont(.medium12)
        }
    }
}

struct KeyPackageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Key Packages"),
            subtitle: L10n.string("Manage the KeyPackages this identity has published for invites.")
        ) {
            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.publishNewKeyPackage() }
                    } label: {
                        Label(
                            workspace.isPublishingKeyPackage
                                ? L10n.string("Publishing...") : L10n.string("Publish new"), systemImage: "plus.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isPublishingKeyPackage || workspace.activeAccount == nil)

                    Button {
                        Task { await workspace.republishKeyPackage() }
                    } label: {
                        Label(
                            workspace.isRepublishingKeyPackage
                                ? L10n.string("Republishing...") : L10n.string("Republish latest"),
                            systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isRepublishingKeyPackage || workspace.activeAccount == nil)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

            Section(L10n.string("Published Key Packages")) {
                if workspace.keyPackages.isEmpty {
                    ContentUnavailableView("No key packages", systemImage: "key.slash")
                        .frame(minHeight: 220)
                } else {
                    ForEach(workspace.keyPackages) { package in
                        KeyPackageRow(package: package) {
                            Task { await workspace.deleteKeyPackage(package) }
                        }
                        .disabled(workspace.deletingKeyPackageId == package.id)
                    }
                }
            }

        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadKeyPackages()
        }
    }
}

struct KeyPackageRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let package: KeyPackageItem
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .wnFont(.semiBold16)
                    .foregroundStyle(WNColor.fillContentPrimary)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(WNColor.fillPrimary)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if package.isLocal {
                            statusBadge(
                                L10n.string("Local"),
                                systemImage: "macbook",
                                tint: MessagesPalette.sentBubble
                            )
                        }
                        if package.isRelayDiscovered {
                            statusBadge(
                                L10n.string("Synced"),
                                systemImage: "checkmark.icloud.fill",
                                tint: .green
                            )
                        }
                        if !package.isLocal && !package.isRelayDiscovered {
                            statusBadge(
                                L10n.string("Unknown"),
                                systemImage: "questionmark.circle",
                                tint: .secondary
                            )
                        }
                        Text(package.publishedLabel)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }

                    keyValue(L10n.string("Event"), package.eventIdHex)

                    if workspace.developerMode {
                        keyValue("KeyPackageRef", package.keyPackageRefHex)
                        keyValue(L10n.string("Slot"), package.keyPackageId)
                        Text(L10n.plural("%llu bytes", package.keyPackageBytes))
                            .wnFont(.medium10.monospacedDigit())
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }

                Spacer()

                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .help(L10n.string("Delete key package"))
                .disabled(package.eventIdHex.isEmpty || workspace.deletingKeyPackageId != nil)
            }

            if workspace.developerMode && !package.sourceRelays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Source relays"))
                        .wnFont(.semiBold10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    ForEach(package.sourceRelays, id: \.self) { relay in
                        Text(relay)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L10n.string("%@, %@"), package.sourceLabel, package.publishedLabel))
    }

    private func statusBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .wnFont(.semiBold10)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Text(value.isEmpty ? L10n.string("Unknown") : DisplayText.short(value, head: 12, tail: 10))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .textSelection(.enabled)
        }
    }
}

struct RelayRow: View {
    let url: String
    var isInsecure: Bool = false
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInsecure ? "lock.open.trianglebadge.exclamationmark" : "network")
                .wnFont(.semiBold10)
                .foregroundStyle(isInsecure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .help(
                    isInsecure
                        ? L10n.string("Insecure cleartext relay (ws://). Relay metadata is not encrypted in transit.")
                        : "")

            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)

                if isInsecure {
                    Text(
                        RelayURLValidator.classify(url) == .insecureLoopback
                            ? "Insecure — cleartext ws:// (loopback only)"
                            : "Insecure — cleartext ws:// (public host)"
                    )
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.intentionWarningContent)
                }
            }

            Spacer()

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .help(L10n.string("Remove relay"))
        }
        .padding(.vertical, 4)
    }
}
