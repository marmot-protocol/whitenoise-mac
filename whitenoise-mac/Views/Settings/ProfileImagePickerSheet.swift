//
//  ProfileImagePickerSheet.swift
//  whitenoise-mac
//
//  Finding a profile picture on the web: a search, a grid of squares, and one of them.
//

import SwiftUI

/// The web half of the profile-picture choice, ported from `wn-ios-prototype`'s
/// `AvatarWebImagePickerView`.
///
/// What the prototype's sheet is, and what this now is too:
///
/// * **One source.** The phone's other two — Photos and Files — are menu items on the avatar, not
///   modes of this window; see `ProfileImageSourceMenu`. This sheet used to carry a *Choose from
///   Mac* button in its top-left corner, which meant opening a search window in order to press a
///   button that opened a different window.
/// * **A grid of bare squares.** Three flexible columns, 1pt gutters, edge to edge, each result
///   cropped to fill a 1:1 tile. See `ProfileImageResultTile` for why the card, the caption, and
///   the 1.18:1 crop this grid used to draw are all gone, and where the credit went.
/// * **Choose, then confirm.** A tile press takes the selection badge and nothing else happens;
///   **Done** downloads, re-encodes, and commits. Every press used to do all of that, so the only
///   way to look at a second candidate was to commit the first and reopen the sheet.
/// * **The privacy line said before the results, not after them.** Neutral — an outline
///   `hand.raised`, primary title, secondary sentence, no warning colour and no confirmation. The
///   sentence is this app's own: the prototype names DuckDuckGo because that is what a shipping
///   client would use, and what this one actually queries is Openverse.
///
/// Both destinations open it. `WorkspaceState.ProfileImagePickerDestination` decides whether the
/// chosen bytes are uploaded under the active account or staged on the sign-up draft; nothing on
/// this screen changes between the two except the face in the header.
struct ProfileImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @FocusState private var isSearchFocused: Bool

    static let sheetWidth: CGFloat = 620
    static let sheetHeight: CGFloat = 600

    /// The prototype's grid verbatim: three flexible columns with a hairline between them, so the
    /// squares read as one sheet of images rather than as twenty-one cards.
    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 1),
        count: 3
    )

    private var trimmedQuery: String {
        workspace.profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBusy: Bool {
        workspace.isSearchingProfileImages || workspace.isUploadingProfileImage
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 12) {
                searchField
                ProfileImageSearchPrivacyNote()
                SettingsErrorView(error: workspace.lastError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            results

            Divider()

            confirmationBar
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
        .background {
            LiquidGlassBackground()
        }
        .defaultFocus($isSearchFocused, true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Whichever profile the sheet is filling in — the active account's published picture,
            // or the sign-up draft's staged bytes. On the sign-up path there is no account, so
            // reading `activeAccount` here would leave the header avatar-less exactly when it is
            // most useful: nothing else on screen shows what was picked.
            switch workspace.profileImagePickerDestination {
            case .activeAccount:
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
            case .signUpDraft:
                SignUpAvatarView(size: 46)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Find image on web"))
                    .wnFont(.semiBold14)
                Text(L10n.string("Search for a picture, then pick one."))
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
    }

    private var searchField: some View {
        @Bindable var workspace = workspace

        return HStack(spacing: 8) {
            TextField(L10n.string("Search images"), text: $workspace.profileImageSearchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit {
                    Task { await workspace.searchProfileImages() }
                }

            Button {
                Task { await workspace.searchProfileImages() }
            } label: {
                Label(L10n.string("Search"), systemImage: "magnifyingglass")
            }
            .nativeGlassProminentButtonStyle()
            .disabled(trimmedQuery.isEmpty || isBusy)
            .help(L10n.string("Search"))
        }
        .disabled(workspace.isUploadingProfileImage)
    }

    @ViewBuilder
    private var results: some View {
        if workspace.profileImageResults.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 1) {
                    ForEach(workspace.profileImageResults) { result in
                        resultButton(result)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func resultButton(_ result: GroupImageSearchResult) -> some View {
        let isSelected = workspace.selectedProfileImageResult == result

        return Button {
            workspace.selectProfileImage(result)
        } label: {
            ProfileImageResultTile(result: result, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(workspace.isUploadingProfileImage)
        .accessibilityLabel(result.title)
        .accessibilityValue(isSelected ? L10n.string("Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var emptyState: some View {
        if workspace.isSearchingProfileImages {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Searching"))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        } else if trimmedQuery.isEmpty {
            ContentUnavailableView(
                L10n.string("Search images"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(L10n.string("Enter a search to find an image."))
            )
        } else {
            ContentUnavailableView(
                L10n.string("No images"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(L10n.string("Enter a search to find an image."))
            )
        }
    }

    private var confirmationBar: some View {
        HStack(spacing: 12) {
            // Where the per-tile caption went. Openverse results are licensed work and the credit
            // has to stay somewhere; one line about the image being taken reads better than
            // twenty-one lines about images that are not.
            if let selected = workspace.selectedProfileImageResult {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selected.title)
                        .wnFont(.semiBold12)
                        .lineLimit(1)
                    Text(selected.creditLine)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if workspace.isUploadingProfileImage {
                ProgressView()
                    .controlSize(.small)
            }

            Button(L10n.string("Done")) {
                Task { await workspace.useSelectedProfileImage() }
            }
            .nativeGlassProminentButtonStyle()
            .disabled(workspace.selectedProfileImageResult == nil || workspace.isUploadingProfileImage)
            .accessibilityIdentifier("profile-image-picker.done")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// The quiet sentence about where a search goes, said before the results rather than under them.
///
/// `wn-ios-prototype` puts this in a grouped `Form` section ahead of its grid: an outline
/// `hand.raised`, a primary title, a secondary detail, and deliberately no warning colour, no
/// custom material, and nothing to dismiss. This is that block in the app's own palette, on the
/// `fillSecondary` ground the sheet's other cards stand on — so its text takes that family's
/// content tokens rather than the ambient background ones: `fillContentSecondary` is what reads as
/// primary against a secondary fill, and `fillContentPrimary` — white in Light — is the pairing
/// mistake that renders this heading invisible.
struct ProfileImageSearchPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
                .wnFont(.medium14)
                .foregroundStyle(WNColor.fillContentTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Search privacy"))
                    .wnFont(.semiBold12)
                    .foregroundStyle(WNColor.fillContentSecondary)

                Text(
                    L10n.string("Search terms are sent to Openverse. Selected images are copied to Blossom before use.")
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.fillContentTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(WNColor.fillSecondary, in: .rect(cornerRadius: 8))
        // The prototype's grouped `Form` gives this card a white ground against a grey canvas.
        // Here the canvas is `LiquidGlassBackground`, which is nearly as light as `fillSecondary`,
        // so the fill alone leaves no visible container — the outline is what draws the box.
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(WNColor.borderTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
