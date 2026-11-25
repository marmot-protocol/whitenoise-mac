//
//  ProfileImagePickerSheet.swift
//  whitenoise-mac
//
//  Finding a profile picture on the web: a search, a grid of squares, and one of them.
//

import SwiftUI

struct ProfileImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SettingsWindowCoordinator.self) private var settings: SettingsWindowCoordinator?
    @FocusState private var isSearchFocused: Bool
    @State private var cropModel: AvatarCropViewModel?

    static let sheetWidth: CGFloat = 620
    static let sheetHeight: CGFloat = 600

    private var trimmedQuery: String {
        workspace.profileImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBusy: Bool {
        workspace.isSearchingProfileImages || workspace.isUploadingProfileImage
    }

    private var canSearch: Bool {
        !trimmedQuery.isEmpty && !isBusy
    }

    private var hasSearchedCurrentQuery: Bool {
        workspace.profileImageResultsQuery == trimmedQuery
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            ProfileImagePickerHeader(
                destination: workspace.profileImagePickerDestination,
                activeAccount: workspace.activeAccount,
                sanitizedDraftPictureURL: workspace.profileDraft.sanitizedPictureURL,
                onClose: { workspace.closeProfileImagePicker() }
            )

            Divider()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField(L10n.string("Search images"), text: $workspace.profileImageSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit(searchIfPossible)

                    Button(action: searchIfPossible) {
                        Label(L10n.string("Search"), systemImage: "magnifyingglass")
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(!canSearch)
                    .help(L10n.string("Search"))
                }
                .disabled(workspace.isUploadingProfileImage)

                ProfileImageSearchPrivacyNote()

                SettingsErrorView(
                    error: workspace.profileImagePickerDestination == .activeAccount
                        ? settings?.lastError : workspace.lastError
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ProfileImagePickerResults(
                results: workspace.profileImageResults,
                selectedResult: workspace.selectedProfileImageResult,
                isSearching: workspace.isSearchingProfileImages,
                isUploading: workspace.isUploadingProfileImage,
                hasSearchedCurrentQuery: hasSearchedCurrentQuery,
                onSelect: { workspace.selectProfileImage($0) }
            )

            Divider()

            ProfileImagePickerConfirmationBar(
                selectedResult: workspace.selectedProfileImageResult,
                isUploading: workspace.isUploadingProfileImage,
                onCancel: { workspace.closeProfileImagePicker() },
                onNext: cropSelectedResult
            )
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
        .defaultFocus($isSearchFocused, true)
        .avatarCropSheet($cropModel)
    }

    /// Downloads the selected tile into the crop editor. Committing the crop closes this sheet
    /// too, through `closeProfileImagePicker()`.
    private func cropSelectedResult() {
        guard let selected = workspace.selectedProfileImageResult else { return }
        let destination = workspace.profileImagePickerDestination
        let expectedAccountId = destination == .activeAccount ? workspace.activeAccountId : nil
        if destination == .activeAccount, expectedAccountId == nil { return }
        let loader = workspace.groupImageSourceLoader
        cropModel = AvatarCropViewModel(
            loadData: { try await AvatarImageCropSource.data(for: selected, using: loader) },
            commit: { [workspace] data in
                try await workspace.setProfileImage(croppedImageData: data, expectedAccountId: expectedAccountId)
            }
        )
    }

    private func searchIfPossible() {
        guard canSearch else { return }
        Task { await workspace.searchProfileImages() }
    }
}

private struct ProfileImagePickerHeader: View {
    let destination: WorkspaceState.ProfileImagePickerDestination
    let activeAccount: AccountItem?
    let sanitizedDraftPictureURL: URL?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch destination {
            case .activeAccount:
                if let account = activeAccount {
                    ProfileImageAvatarView(
                        seed: account.accountIdHex,
                        initials: account.displayName,
                        sanitizedPictureURL: sanitizedDraftPictureURL,
                        size: 46,
                        isSelected: false
                    )
                }
            case .signUpDraft:
                SignUpAvatarView(size: 46)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Find image on web"))
                    .font(.headline)
                Text(L10n.string("Search for a picture, then pick one."))
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            Spacer()

            GlassCircleCloseButton(appearance: .outline, action: onClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct ProfileImagePickerResults: View {
    let results: [GroupImageSearchResult]
    let selectedResult: GroupImageSearchResult?
    let isSearching: Bool
    let isUploading: Bool
    let hasSearchedCurrentQuery: Bool
    let onSelect: (GroupImageSearchResult) -> Void

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 1),
        count: 3
    )

    var body: some View {
        if results.isEmpty {
            ProfileImagePickerEmptyState(
                isSearching: isSearching,
                hasSearchedCurrentQuery: hasSearchedCurrentQuery
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 1) {
                    ForEach(results) { result in
                        let isSelected = selectedResult == result
                        Button {
                            onSelect(result)
                        } label: {
                            ProfileImageResultTile(result: result, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploading)
                        .accessibilityLabel(result.title)
                        .accessibilityValue(isSelected ? L10n.string("Selected") : "")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ProfileImagePickerEmptyState: View {
    let isSearching: Bool
    let hasSearchedCurrentQuery: Bool

    var body: some View {
        if isSearching {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Searching"))
                    .font(.subheadline)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        } else if hasSearchedCurrentQuery {
            ContentUnavailableView(
                L10n.string("No images"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(L10n.string("Check the spelling or try a different search."))
            )
        } else {
            ContentUnavailableView(
                L10n.string("Search images"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(L10n.string("Enter a search to find an image."))
            )
        }
    }
}

private struct ProfileImagePickerConfirmationBar: View {
    let selectedResult: GroupImageSearchResult?
    let isUploading: Bool
    let onCancel: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let selected = selectedResult {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selected.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(selected.creditLine)
                        .font(.caption)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isUploading {
                ProgressView()
                    .controlSize(.small)
            }

            Button(L10n.string("Cancel"), action: onCancel)
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)
                .disabled(isUploading)

            Button(L10n.string("Next"), action: onNext)
                .wnPrimaryButtonStyle()
                .disabled(selectedResult == nil || isUploading)
                .accessibilityIdentifier("profile-image-picker.done")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// The quiet sentence about where a search goes, said before the results rather than under them.
struct ProfileImageSearchPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.body)
                .foregroundStyle(WNColor.fillContentTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Search privacy"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WNColor.fillContentSecondary)

                Text(
                    L10n.string("Search terms are sent to Openverse. Selected images are copied to Blossom before use.")
                )
                .font(.caption)
                .foregroundStyle(WNColor.fillContentTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(WNColor.fillSecondary, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(WNColor.borderTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Profile image picker") {
    ProfileImagePickerSheet()
        .environment(WorkspaceState.preview())
}
