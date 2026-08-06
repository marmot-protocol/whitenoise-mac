//
//  SettingsViews.swift
//  whitenoise-mac
//
//  The settings surface: SettingsPanelView and every settings page/row
//  (accounts, profile, identity keys, appearance, privacy/security, audit
//  logs, notifications, developer mode, relays, key packages). Extracted
//  verbatim from MessengerShellView.swift (no behavior change).
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
            case .general:
                GeneralSettingsView()
            case .accounts:
                AccountsSettingsView()
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
        .background {
            LiquidGlassBackground()
        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadSettingsData()
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        SettingsScaffold(
            title: L10n.string("General"),
            subtitle: L10n.string("Choose how White Noise behaves when you start your Mac.")
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
                    .font(.caption)
                    .foregroundStyle(.secondary)

                launchAtLoginStatus

                Divider()

                Toggle(
                    L10n.string("Restore last selected chat on launch"),
                    isOn: Binding(
                        get: { workspace.restoreLastSelectedChat },
                        set: { workspace.setRestoreLastSelectedChat($0) }
                    )
                )

                Text(
                    L10n.string(
                        "Return to the last conversation selected for this account after White Noise finishes loading.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(L10n.string("Open Login Items Settings")) {
                    launchAtLogin.openSystemSettings()
                }
            }
        case .notFound:
            Label(
                L10n.string("macOS could not find White Noise's login item."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .notRegistered, .enabled:
            EmptyView()
        }
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
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .nativeGlassButtonStyle()
                    .help(L10n.string("Back to settings"))
                }

                Text(title)
                    .font(.title2.weight(.semibold))

                Spacer()
            }

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

private var removeAccountConfirmationMessage: String {
    L10n.string(
        "This deletes the private key and local message history for this identity from this Mac. This cannot be undone."
    )
}

private func removeAccountConfirmationTitle(for account: AccountItem?) -> String {
    guard let account else { return L10n.string("Remove account?") }
    return String(format: L10n.string("Remove %@?"), account.displayName)
}

private struct RemoveAccountConfirmationModifier: ViewModifier {
    let account: AccountItem?
    @Binding var isPresented: Bool
    let isRemoveDisabled: Bool
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            removeAccountConfirmationTitle(for: account),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Account"), role: .destructive) {
                onRemove()
            }
            .disabled(isRemoveDisabled)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(removeAccountConfirmationMessage)
        }
    }
}

private extension View {
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

struct AccountsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var accountPendingRemoval: AccountItem?
    @State private var accountPendingSignOut: AccountItem?

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Accounts"),
            subtitle: L10n.string("Manage the identities available on this Mac."),
            errorSectionTitle: L10n.string("Status")
        ) {
            Section {
                ForEach(workspace.accounts) { account in
                    AccountSettingsRow(
                        account: account,
                        isActive: account.id == workspace.activeAccountId,
                        isRemoving: workspace.isRemovingAccount,
                        isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                        onSelect: {
                            workspace.selectAccountFromSettings(account)
                        },
                        onRemove: {
                            accountPendingRemoval = account
                        },
                        onSignOut: {
                            accountPendingSignOut = account
                        },
                        onSignIn: {
                            Task { await workspace.signInAccount(account) }
                        }
                    )
                }
            } header: {
                Text(L10n.string("Accounts"))
            } footer: {
                Text(
                    L10n.string(
                        "Removing an account deletes its private key and local message history from this Mac. The identity itself is not deleted from the network."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L10n.string("Add Account")) {
                SecureField(L10n.string(""), text: $workspace.loginIdentity, prompt: Text(L10n.string("nsec1...")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(workspace.isAuthenticating)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await workspace.login()
                            workspace.showSettingsPage(.accounts)
                        }
                    } label: {
                        Label(
                            workspace.isAuthenticating ? L10n.string("Logging in...") : L10n.string("Log in with key"),
                            systemImage: "key")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(
                        workspace.loginIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || workspace.isAuthenticating)

                    Button {
                        workspace.loginIdentity = ""
                        Task {
                            await workspace.signUp()
                            workspace.showSettingsPage(.accounts)
                        }
                    } label: {
                        Label(
                            workspace.isAuthenticating ? L10n.string("Creating...") : L10n.string("Create identity"),
                            systemImage: "plus.circle")
                    }
                    .nativeGlassButtonStyle()
                    .disabled(workspace.isAuthenticating)

                    Spacer()
                }
            }

        }
        .removeAccountConfirmation(
            account: accountPendingRemoval,
            isPresented: removeConfirmationBinding,
            isRemoveDisabled: workspace.isAccountMutationInProgress
        ) {
            guard let account = accountPendingRemoval else { return }
            accountPendingRemoval = nil
            Task { await workspace.removeAccount(account) }
        }
        .confirmationDialog(
            L10n.string("Sign out of this account?"),
            isPresented: signOutConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Sign Out"), role: .destructive) {
                guard let account = accountPendingSignOut else { return }
                accountPendingSignOut = nil
                Task { await workspace.signOutAccount(account) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {
                accountPendingSignOut = nil
            }
        } message: {
            Text(L10n.string("The account and its local data will stay on this Mac so you can sign in again later."))
        }
    }

    private var removeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingRemoval != nil },
            set: { isPresented in
                if !isPresented { accountPendingRemoval = nil }
            }
        )
    }

    private var signOutConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingSignOut != nil },
            set: { isPresented in
                if !isPresented { accountPendingSignOut = nil }
            }
        )
    }
}

struct AccountSettingsRow: View {
    let account: AccountItem
    let isActive: Bool
    let isRemoving: Bool
    let isAccountMutationInProgress: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onSignOut: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: account.signedOut ? onSignIn : onSelect) {
                HStack(spacing: 12) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        sanitizedPictureURL: account.sanitizedPictureURL,
                        size: 44,
                        isSelected: false
                    )
                    .opacity(account.signedOut ? 0.4 : 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            CopyableKeyLabel(accountIdHex: account.accountIdHex, showsCopyButton: false)

                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(account.signedOut ? Color.orange : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isActive {
                        Label(L10n.string("Active"), systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRemoving || (account.signedOut && isAccountMutationInProgress))

            PublicIdentityQRCodeButton(
                accountIdHex: account.accountIdHex,
                displayName: account.displayName
            )
            .disabled(isRemoving)

            Menu {
                if account.signedOut {
                    Button(action: onSignIn) {
                        Label(L10n.string("Sign In"), systemImage: "person.crop.circle.badge.checkmark")
                    }
                } else {
                    Button(action: onSignOut) {
                        Label(L10n.string("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label(L10n.string("Remove Account"), systemImage: "person.crop.circle.badge.minus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isRemoving || isAccountMutationInProgress)
            .help(L10n.string("Account actions"))
            .accessibilityLabel(Text(String(format: L10n.string("Actions for %@"), account.displayName)))
        }
    }

    private var statusText: String {
        if account.signedOut {
            return L10n.string("Signed out")
        }
        if account.localSigning {
            return L10n.string("Local signing")
        }
        return account.externalSigning ? L10n.string("External signing") : L10n.string("Watch-only")
    }
}

struct PublicIdentityQRCodeButton: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isPresented = false
    let accountIdHex: String
    let displayName: String

    private var npub: String {
        workspace.npub(forAccountIdHex: accountIdHex)
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
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
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(L10n.string("Public identity"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                GlassCircleCloseButton {
                    dismiss()
                }
            }

            ZStack {
                Color.white
                // Encode the marmot:// profile link form so scanners can route the
                // scheme; the visible text and Copy button keep the bare npub.
                QRCodeImageView(payload: MarmotProfileLink.qrPayload(npub: npub))
                    .padding(22)
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }

            Text(DisplayText.short(npub, head: 24, tail: 24))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Label(
                        isConfirming ? L10n.string("Copied") : L10n.string("Copy npub"),
                        systemImage: isConfirming ? "checkmark" : "doc.on.doc"
                    )
                }
                .nativeGlassButtonStyle()

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label(L10n.string("Done"), systemImage: "checkmark")
                }
                .nativeGlassProminentButtonStyle()
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

struct QRCodeImageView: View {
    let payload: String

    @State private var renderedPayload: String?
    @State private var renderedImage: NSImage?

    var body: some View {
        Group {
            if renderedPayload == payload, let renderedImage {
                Image(nsImage: renderedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else if renderedPayload == payload {
                ContentUnavailableView("QR code unavailable", systemImage: "qrcode")
                    .foregroundStyle(.black)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .foregroundStyle(.black)
            }
        }
        .task(id: payload) {
            let image = await Task.detached(priority: .utility) {
                Self.image(for: payload)
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = image?.nsImage
            renderedPayload = payload
        }
    }

    nonisolated private static func image(for payload: String) -> RenderedQRCodeImage? {
        guard !payload.isEmpty,
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return RenderedQRCodeImage(nsImage: image)
    }
}

struct SettingsErrorView: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isMoreExpanded = false

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Profile"),
            subtitle: L10n.string("Publish the profile other people see for this identity.")
        ) {
            if let account = workspace.activeAccount {
                Section(L10n.string("Preview")) {
                    HStack(spacing: 12) {
                        Button {
                            workspace.showProfileImagePicker()
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                ProfileImageAvatarView(
                                    seed: account.accountIdHex,
                                    initials: profilePreviewName(fallback: account),
                                    sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                                    size: 56,
                                    isSelected: false
                                )

                                Image(systemName: "camera.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.68), in: Circle())
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Change profile image"))
                        .accessibilityLabel(L10n.string("Change profile image"))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profilePreviewName(fallback: account))
                                .font(.headline)
                                .lineLimit(1)
                            CopyableKeyLabel(accountIdHex: account.accountIdHex)
                        }

                        Spacer()

                        PublicIdentityQRCodeButton(
                            accountIdHex: account.accountIdHex,
                            displayName: profilePreviewName(fallback: account)
                        )
                    }
                }
            }

            Section(L10n.string("Profile")) {
                TextField(L10n.string("Name"), text: $workspace.profileDraft.displayName)
                TextField(L10n.string("About"), text: $workspace.profileDraft.about, axis: .vertical)
                    .lineLimit(3...5)

                DisclosureGroup("More", isExpanded: $isMoreExpanded) {
                    TextField(L10n.string("Profile image URL"), text: $workspace.profileDraft.picture)
                    TextField(L10n.string("Banner image URL"), text: $workspace.profileDraft.banner)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await workspace.saveProfile() }
                    } label: {
                        Label(
                            workspace.isSavingProfile ? L10n.string("Saving...") : L10n.string("Save profile"),
                            systemImage: "checkmark.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isSavingProfile || workspace.activeAccount == nil)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

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
                        size: 46,
                        isSelected: false
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Profile image"))
                        .font(.headline)
                    Text(L10n.string("Choose from your Mac or search the web"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsErrorView(error: workspace.lastError)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

                ScrollView {
                    if workspace.profileImageResults.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(
                                workspace.isSearchingProfileImages ? L10n.string("Searching") : L10n.string("No images")
                            )
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
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
                            size: 52,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(accountSigningDescription(for: account))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L10n.string("Public Identity")) {
                    let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
                    LabeledContent(L10n.string("npub")) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(npub)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            CopyToClipboardButton(
                                value: npub,
                                actionDescription: L10n.string("Copy npub")
                            ) { isConfirming in
                                Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(isConfirming ? Color.green : Color.accentColor)
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
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        showKeyBackup = true
                    } label: {
                        Label(L10n.string("Back Up Private Key…"), systemImage: "key")
                    }
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        showRemoveAccountConfirmation = true
                    } label: {
                        Label(
                            workspace.isRemovingAccount ? L10n.string("Removing...") : L10n.string("Remove Account"),
                            systemImage: "person.crop.circle.badge.minus")
                    }
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
                    .font(.title3.weight(.semibold))
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(L10n.string("Passphrase"), text: $passphrase)
                    .textFieldStyle(.roundedBorder)
            case .nsec:
                Label(
                    L10n.string(
                        "Anyone with your nsec controls this account. Never share it. Revealing it is recorded in your audit log."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
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
                                .foregroundStyle(isConfirming ? Color.green : Color.accentColor)
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
                    .font(.caption)
                    .foregroundStyle(.red)
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
                .fill(Color.primary.opacity(0.10))
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
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if showsCopyButton {
                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(isConfirming ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var quickReactionBeingReplaced: Int?

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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("Quick reactions")) {
                Text(L10n.string("Choose and order the six reactions shown in message actions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(workspace.quickReactions.enumerated()), id: \.offset) { index, emoji in
                    HStack(spacing: 12) {
                        Button {
                            quickReactionBeingReplaced = index
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(width: 38, height: 32)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                            .foregroundStyle(.secondary)

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
                .disabled(workspace.quickReactions == ChatReactionDefaults.quick)
            }
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
                .font(.caption)
                .foregroundStyle(.secondary)
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

                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.auditFullDataLogging },
                        set: { enabled in
                            Task { await workspace.setAuditFullDataLogging(enabled) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.string("Full Data Logging"), systemImage: "eye.trianglebadge.exclamationmark")
                        Text(
                            L10n.string("Record decrypted message content and full identifiers. ")
                                + L10n.string("Leave off to keep sensitive data obfuscated.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(workspace.isSavingPrivacySecurity || !workspace.privacySecuritySettings.auditLoggingEnabled)

                if workspace.isSavingPrivacySecurity {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Saving..."))
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.green)
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
                .tint(.red)
                .disabled(workspace.isAccountMutationInProgress)

                Text(L10n.string("Reset White Noise to a newly installed state on this Mac."))
                    .foregroundStyle(.secondary)
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(details)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(file.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
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
                            .foregroundStyle(.secondary)
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
                } else if workspace.notificationAuthorizationStatus == .denied {
                    Button {
                        workspace.openSystemNotificationSettings()
                    } label: {
                        Label(L10n.string("Open System Settings"), systemImage: "gear")
                    }
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
                    .foregroundStyle(.secondary)
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
            Section(L10n.string("Media Cache")) {
                LabeledContent(L10n.string("Cached attachments")) {
                    if workspace.isLoadingMediaCacheFootprint {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(byteCount(workspace.mediaCacheFootprint.byteCount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    L10n.string(
                        "White Noise encrypts cached attachment data on this Mac. Clearing it does not remove accounts, messages, drafts, or settings."
                    )
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
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
                    .foregroundStyle(.green)
                }
            }
        }
        .task {
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
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label(L10n.string("Open Storage Folder"), systemImage: "folder")
                }
            }

            Section(L10n.string("Diagnostics")) {
                ForEach(workspace.diagnosticsInfo) { item in
                    LabeledContent(item.title) {
                        Text(item.value)
                            .foregroundStyle(.secondary)
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
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(settings.isComplete ? L10n.string("Complete") : L10n.string("Missing"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            RelayDiagnosticsRow(
                title: L10n.string("NIP-65"), systemImage: "list.bullet", relays: settings.publishedNip65)
            RelayDiagnosticsRow(
                title: L10n.string("Inbox"), systemImage: "tray.and.arrow.down", relays: settings.publishedInbox)

            if !settings.missing.isEmpty {
                Text(String(format: L10n.string("Missing: %@"), settings.missing.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Text(verbatim: "\(relays.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .font(.callout)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(MessagesPalette.sentBubble)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    keyValue(L10n.string("Event"), package.eventIdHex)

                    if workspace.developerMode {
                        keyValue("KeyPackageRef", package.keyPackageRefHex)
                        keyValue(L10n.string("Slot"), package.keyPackageId)
                        Text(L10n.plural("%llu bytes", package.keyPackageBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(L10n.string("Delete key package"))
                .disabled(package.eventIdHex.isEmpty || workspace.deletingKeyPackageId != nil)
            }

            if workspace.developerMode && !package.sourceRelays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Source relays"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(package.sourceRelays, id: \.self) { relay in
                        Text(relay)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? L10n.string("Unknown") : DisplayText.short(value, head: 12, tail: 10))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
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
                .font(.caption.weight(.semibold))
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
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.string("Remove relay"))
        }
        .padding(.vertical, 4)
    }
}
