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

struct SettingsHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
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
                    .help("Back to settings")
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
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var errorSectionTitle: LocalizedStringKey?
    let content: Content

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        errorSectionTitle: LocalizedStringKey? = nil,
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

struct AccountsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var accountPendingRemoval: AccountItem?

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Accounts",
            subtitle: "Manage the identities available on this Mac.",
            errorSectionTitle: "Status"
        ) {
            Section {
                ForEach(workspace.accounts) { account in
                    AccountSettingsRow(
                        account: account,
                        isActive: account.id == workspace.activeAccountId,
                        isRemoving: workspace.isRemovingAccount,
                        onSelect: {
                            workspace.selectAccountFromSettings(account)
                        },
                        onRemove: {
                            accountPendingRemoval = account
                        }
                    )
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(
                    "Removing an account deletes its private key and local message history from this Mac. The identity itself is not deleted from the network."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Add Account") {
                SecureField("", text: $workspace.loginIdentity, prompt: Text("nsec1..."))
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
        .confirmationDialog(
            removeAccountTitle,
            isPresented: removeConfirmationBinding,
            titleVisibility: .visible,
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove Account", role: .destructive) {
                accountPendingRemoval = nil
                Task { await workspace.removeAccount(account) }
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: { _ in
            Text(
                "This deletes the private key and local message history for this identity from this Mac. This cannot be undone."
            )
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

    private var removeAccountTitle: String {
        if let account = accountPendingRemoval {
            return String(format: L10n.string("Remove %@?"), account.displayName)
        }
        return L10n.string("Remove account?")
    }
}

struct AccountSettingsRow: View {
    let account: AccountItem
    let isActive: Bool
    let isRemoving: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.initials,
                        pictureURL: account.pictureURL,
                        size: 44,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            CopyableKeyLabel(accountIdHex: account.accountIdHex, showsCopyButton: false)

                            Text(account.localSigning ? L10n.string("Local signing") : L10n.string("Watch-only"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRemoving)

            PublicIdentityQRCodeButton(
                accountIdHex: account.accountIdHex,
                displayName: account.displayName
            )
            .disabled(isRemoving)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "person.crop.circle.badge.minus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isRemoving)
            .help(L10n.string("Remove this account from this Mac"))
            .accessibilityLabel(Text(String(format: L10n.string("Remove %@"), account.displayName)))
        }
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
        .help("Show npub QR code")
        .accessibilityLabel(Text("Show npub QR code"))
        .sheet(isPresented: $isPresented) {
            PublicIdentityQRCodeSheet(displayName: displayName, npub: npub)
        }
    }
}

struct PublicIdentityQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceState.self) private var workspace
    let displayName: String
    let npub: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("Public identity")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Close")
            }

            ZStack {
                Color.white
                QRCodeImageView(payload: npub)
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
                Button {
                    workspace.copyText(npub)
                } label: {
                    Label("Copy npub", systemImage: "doc.on.doc")
                }
                .nativeGlassButtonStyle()

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
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
            renderedImage = Self.image(for: payload)
            renderedPayload = payload
        }
    }

    private static func image(for payload: String) -> NSImage? {
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
        return image
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

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Profile",
            subtitle: "Publish the profile other people see for this identity."
        ) {
            if let account = workspace.activeAccount {
                Section("Preview") {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: profilePreviewName(fallback: account),
                            pictureURL: workspace.profileDraft.picture,
                            size: 56,
                            isSelected: false
                        )

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

            Section("Profile") {
                TextField("Display name", text: $workspace.profileDraft.displayName)
                TextField("Name", text: $workspace.profileDraft.name)
                TextField("About", text: $workspace.profileDraft.about, axis: .vertical)
                    .lineLimit(3...5)
                TextField("Picture URL", text: $workspace.profileDraft.picture)
                TextField("NIP-05", text: $workspace.profileDraft.nip05)
                TextField("Lightning address", text: $workspace.profileDraft.lud16)
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
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            workspace.profileDraft.name,
            account.displayName,
        ]) ?? account.displayName
    }
}

struct IdentityKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveAccountConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: "Identity & Keys",
            subtitle: "Public identity details and local signing state."
        ) {
            if let account = workspace.activeAccount {
                Section("Account") {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.initials,
                            pictureURL: account.pictureURL,
                            size: 52,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(
                                account.localSigning
                                    ? L10n.string("Local signing account") : L10n.string("Watch-only account")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Public Identity") {
                    let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
                    LabeledContent("npub") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(npub)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            Button {
                                workspace.copyText(npub)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("\(L10n.string("Copy")) npub")

                            PublicIdentityQRCodeButton(
                                accountIdHex: account.accountIdHex,
                                displayName: account.displayName
                            )
                        }
                    }
                }

                Section("Private Key") {
                    LabeledContent("Private key") {
                        Text(
                            account.localSigning
                                ? L10n.string("Stored in Keychain") : L10n.string("Not stored on this Mac")
                        )
                        .foregroundStyle(.secondary)
                    }

                    Button {
                    } label: {
                        Label("Copy Private Key", systemImage: "key")
                    }
                    .disabled(true)
                    .help("Private-key export is not exposed by MarmotKit in this build")
                }

                Section("Account Removal") {
                    Text(
                        "Remove this identity from this Mac. Messages and keys managed by Marmot for this account will no longer be available locally."
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
                    .disabled(workspace.isRemovingAccount)
                }
            } else {
                Section {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }

        }
        .confirmationDialog(
            removeAccountTitle,
            isPresented: $showRemoveAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                Task { await workspace.removeActiveAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected account from this Mac.")
        }
    }

    private var removeAccountTitle: String {
        if let account = workspace.activeAccount {
            return String(format: L10n.string("Remove %@?"), account.displayName)
        }
        return L10n.string("Remove account?")
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
                Button {
                    workspace.copyText(npub)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.string("Copy npub"))
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Appearance",
            subtitle: "Choose how White Noise follows macOS appearance."
        ) {
            Section("Appearance") {
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

        }
    }
}

struct PrivacySecuritySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showDeleteAuditLogsConfirmation = false
    @State private var showDeleteAllDataConfirmation = false

    var body: some View {
        SettingsScaffold(
            title: "Privacy & Security",
            subtitle: "Telemetry and audit logs stay off until you enable them."
        ) {
            Section("Remote Content") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.loadRemoteImages },
                        set: { workspace.loadRemoteImages = $0 }
                    )
                ) {
                    Label("Load Remote Profile Images", systemImage: "person.crop.circle.badge.exclamationmark")
                }

                Text(
                    "Off by default. Profile pictures come from URLs other people control, so loading them reveals your IP address and when you're online to whoever sent them. Leave this off unless you trust the senders. Only secure (https) images are ever loaded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Data Sharing") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.privacySecuritySettings.relayTelemetryEnabled },
                        set: { enabled in
                            Task { await workspace.setRelayTelemetryEnabled(enabled) }
                        }
                    )
                ) {
                    Label("Anonymous Telemetry", systemImage: "waveform.path.ecg")
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
                    Label("Audit Logging", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(workspace.isSavingPrivacySecurity)

                if workspace.isSavingPrivacySecurity {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Audit Log Files") {
                HStack {
                    if workspace.isLoadingAuditLogFiles {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await workspace.loadAuditLogFiles() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
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

            Section("Reset") {
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
                .disabled(workspace.isDeletingAllData)

                Text("Reset White Noise to a newly installed state on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .task {
            await workspace.loadAuditLogFiles()
        }
        .confirmationDialog(
            "Delete all audit logs?",
            isPresented: $showDeleteAuditLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Audit Logs", role: .destructive) {
                Task { await workspace.deleteAllAuditLogFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this Mac.")
        }
        .alert("Delete all data?", isPresented: $showDeleteAllDataConfirmation) {
            Button("Delete All Data", role: .destructive) {
                Task { await workspace.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This clears all accounts, chats, and messages from this Mac and resets White Noise to a newly installed state. This cannot be undone."
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
            title: "Notifications",
            subtitle: "Local alerts for this Mac."
        ) {
            Section("Local Alerts") {
                Toggle(
                    isOn: Binding(
                        get: { workspace.notificationSettings.localNotificationsEnabled },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                ) {
                    Label("Local notifications", systemImage: "bell.badge")
                }
                .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications)

                LabeledContent("Permission") {
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
                        Label("Allow Notifications", systemImage: "checkmark.circle")
                    }
                } else if workspace.notificationAuthorizationStatus == .denied {
                    Button {
                        workspace.openSystemNotificationSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
                    }
                }
            }

            Section("Privacy") {
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
    }
}

struct DeveloperModeSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: "Developer mode",
            subtitle: "Storage and diagnostics."
        ) {
            Section("Developer") {
                Toggle(isOn: $workspace.developerMode) {
                    Label("Developer mode", systemImage: "stethoscope")
                }

                Toggle(isOn: $workspace.streamingDebugMode) {
                    Label("Streaming debug", systemImage: "waveform.path.ecg")
                }
                .disabled(!workspace.developerMode)
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")

                    Text(workspace.storageRootPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace.storageRootPath, isDirectory: true))
                } label: {
                    Label("Open Storage Folder", systemImage: "folder")
                }
            }

            Section("Diagnostics") {
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
            title: "Relays",
            subtitle: "Manage the relay lists published for this account."
        ) {
            Section("Relay List") {
                Picker("Relay list", selection: $workspace.selectedRelaySection) {
                    ForEach(RelaySettingsSection.allCases) { section in
                        Text(section.label).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: workspace.selectedRelaySection) { _, section in
                    workspace.selectRelaySection(section)
                }

                Text(workspace.selectedRelaySection.description)
                    .foregroundStyle(.secondary)
            }

            Section {
                RelayDiagnosticsView(settings: workspace.relaySettings)
            }

            Section("Relays") {
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

            Section("Add Relay") {
                HStack(spacing: 8) {
                    TextField("", text: $workspace.newRelayURL, prompt: Text("wss://relay.example"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            workspace.addRelayDraftURL()
                        }
                        .frame(maxWidth: .infinity)

                    Button {
                        workspace.addRelayDraftURL()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add relay")
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
                        Label("Restore defaults", systemImage: "arrow.counterclockwise")
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
                Text("Published Relay Lists")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(settings.isComplete ? L10n.string("Complete") : L10n.string("Missing"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            RelayDiagnosticsRow(title: "Default", systemImage: "network", relays: settings.defaultRelays)
            RelayDiagnosticsRow(
                title: "Bootstrap", systemImage: "antenna.radiowaves.left.and.right", relays: settings.bootstrapRelays)
            RelayDiagnosticsRow(title: "NIP-65", systemImage: "list.bullet", relays: settings.publishedNip65)
            RelayDiagnosticsRow(title: "Inbox", systemImage: "tray.and.arrow.down", relays: settings.publishedInbox)

            if !settings.missing.isEmpty {
                Text("Missing: \(settings.missing.joined(separator: ", "))")
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
                Text("Not published")
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
                Text("\(relays.count)")
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
            title: "Key Packages",
            subtitle: "Manage the KeyPackages this identity has published for invites."
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

            Section("Published Key Packages") {
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
                        Text(package.sourceLabel)
                            .font(.callout.weight(.semibold))
                        Text(package.publishedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    keyValue("Event", package.eventIdHex)

                    if workspace.developerMode {
                        keyValue("KeyPackageRef", package.keyPackageRefHex)
                        keyValue("Slot", package.keyPackageId)
                        Text("\(package.keyPackageBytes) bytes")
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
                .help("Delete key package")
                .disabled(package.eventIdHex.isEmpty || workspace.deletingKeyPackageId != nil)
            }

            if workspace.developerMode && !package.sourceRelays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source relays")
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
            .help("Remove relay")
        }
        .padding(.vertical, 4)
    }
}
