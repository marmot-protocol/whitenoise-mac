//
//  GroupImageSourceMenu.swift
//  whitenoise-mac
//
//  The "Add photo" / "Change photo" pill under the group-info avatar, for admins.
//

import SwiftUI
import UniformTypeIdentifiers

/// Where a group image can come from, as a pill under the avatar that will wear it.
///
/// This is the iOS client's `WNAvatarPhotoMenu` — the avatar with an **Add Photo** /
/// **Change Photo** button beneath it, opening **Choose from Files**, **Find Image on Web** and,
/// once there is an image, **Remove Photo**. The Mac has no camera roll, so the phone's
/// *Choose from Photos* collapses into *Choose from Files*, the same way `ProfileImageSourceMenu`
/// does for a profile picture.
///
/// A popover rather than a `Menu` for the reason `ProfileImageSourceMenu` gives: a macOS `Menu`
/// restyles its label into a menu title.
///
/// The view knows nothing about the workspace: every source is a closure, so it previews and can
/// be substituted.
struct GroupImageSourceMenu: View {
    let hasImage: Bool
    var isSaving = false
    var isEnabled = true
    let chooseFile: (URL) -> Void
    let findOnWeb: () -> Void
    let remove: () -> Void
    let reportImportFailure: (any Error) -> Void

    @State private var isSourceListPresented = false
    @State private var isFileImporterPresented = false

    var body: some View {
        Button {
            isSourceListPresented = true
        } label: {
            HStack(spacing: 6) {
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(L10n.string(hasImage ? "Change photo" : "Add photo"))
                    .wnFont(.medium12)
            }
        }
        .buttonStyle(.wnSecondary)
        .controlSize(.small)
        .disabled(!isEnabled || isSaving)
        .accessibilityIdentifier("group.details.photo")
        .popover(isPresented: $isSourceListPresented, arrowEdge: .bottom) {
            ProfileImageSourceList(
                chooseFile: {
                    isSourceListPresented = false
                    isFileImporterPresented = true
                },
                findOnWeb: {
                    isSourceListPresented = false
                    findOnWeb()
                },
                remove: hasImage
                    ? {
                        isSourceListPresented = false
                        remove()
                    } : nil
            )
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                chooseFile(url)
            case .failure(let error):
                reportImportFailure(error)
            }
        }
    }
}

#Preview("No image") {
    GroupImageSourceMenu(
        hasImage: false,
        chooseFile: { _ in },
        findOnWeb: {},
        remove: {},
        reportImportFailure: { _ in }
    )
    .padding()
}

#Preview("Has image, saving") {
    GroupImageSourceMenu(
        hasImage: true,
        isSaving: true,
        chooseFile: { _ in },
        findOnWeb: {},
        remove: {},
        reportImportFailure: { _ in }
    )
    .padding()
}
