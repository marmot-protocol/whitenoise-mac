//
//  ProfileImageSourceMenu.swift
//  whitenoise-mac
//
//  Where a profile picture can come from, hung off the avatar that will wear it.
//

import SwiftUI
import UniformTypeIdentifiers

/// The avatar, as the menu of places a picture can come from.
///
/// This is `wn-ios-prototype`'s `SignUpView` menu — **Choose from Photos**, **Choose from Files**,
/// **Find Image on Web** — minus the source a Mac does not have. There is no camera roll here and
/// no camera, so the phone's first entry collapses into the second: a file on this machine, or an
/// image found on the web. Two sources, named the way the prototype names them.
///
/// Splitting the two apart is what lets the sheet behind **Find image on web** become the
/// prototype's web picker rather than a hybrid — see `ProfileImagePickerSheet`. Files never needed
/// the sheet: the system's open panel *is* the picker, and routing it through a window that then
/// has to be dismissed only put a step in front of it.
///
/// **Why a popover and not a `Menu`.** A `Menu` on macOS coerces its label into a *menu title*: an
/// avatar handed to one comes out as the badge glyph and the monogram letter set side by side in
/// menu-title type, with the circle, the ring, and the layout all discarded. It renders that way
/// under every menu style, and `ImageRenderer` cannot show it — a `Menu` rasterizes as the
/// unsupported-view placeholder, so this is only visible by running the app. A `Button` keeps the
/// label exactly as written, and the popover carries the same two rows.
///
/// `destination` is the same one `WorkspaceState.ProfileImagePickerDestination` carries, because
/// the file path skips `presentProfileImagePicker(destination:)` and has to say where the bytes
/// land some other way.
struct ProfileImageSourceMenu<Label: View>: View {
    @Environment(WorkspaceState.self) private var workspace

    let destination: WorkspaceState.ProfileImagePickerDestination
    var isEnabled = true
    @ViewBuilder var label: () -> Label

    @State private var isSourceListPresented = false
    @State private var isFileImporterPresented = false

    var body: some View {
        Button {
            isSourceListPresented = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(L10n.string("Change profile image"))
        .accessibilityLabel(L10n.string("Change profile image"))
        .popover(isPresented: $isSourceListPresented, arrowEdge: .bottom) {
            ProfileImageSourceList(chooseFile: chooseFile, findOnWeb: showWebPicker)
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

    private func chooseFile() {
        isSourceListPresented = false
        guard workspace.prepareProfileImageDestination(destination) else { return }
        isFileImporterPresented = true
    }

    private func showWebPicker() {
        isSourceListPresented = false
        switch destination {
        case .activeAccount:
            workspace.showProfileImagePicker()
        case .signUpDraft:
            workspace.showSignUpImagePicker()
        }
    }
}

/// The two sources, as the popover draws them.
///
/// Sized explicitly: a popover with no width takes the system's minimum content size — 312x237 on
/// this OS — which is a dialog-sized card around two rows of text.
struct ProfileImageSourceList: View {
    let chooseFile: () -> Void
    let findOnWeb: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProfileImageSourceButton(
                title: L10n.string("Choose from Files"),
                systemImage: "folder",
                action: chooseFile
            )

            ProfileImageSourceButton(
                title: L10n.string("Find image on web"),
                systemImage: "globe",
                action: findOnWeb
            )
        }
        .padding(6)
        .frame(width: Self.width)
    }

    /// Wide enough for the longest of the two titles in every language the app ships, which is
    /// Russian's "Найти изображение в интернете" at 198pt in the 12pt medium face — measured with
    /// `NSString.size(withAttributes:)` rather than eyeballed against the English, which is 80pt
    /// shorter. Plus the 16pt symbol gutter, its 8pt gap, the row's 16pt padding, and the list's
    /// own 12pt.
    static let width: CGFloat = 252
}

/// One row of the source popover, drawn to read as a menu item: a symbol in a fixed gutter so the
/// two titles line up, and a highlight that follows the pointer.
private struct ProfileImageSourceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .wnFont(.medium12)
                    .frame(width: 16)

                Text(title)
                    .wnFont(.medium12)

                Spacer(minLength: 0)
            }
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? WNColor.fillSecondaryHover : .clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
