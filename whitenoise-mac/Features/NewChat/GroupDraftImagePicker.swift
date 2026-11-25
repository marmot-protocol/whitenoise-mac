//
//  GroupDraftImagePicker.swift
//  whitenoise-mac
//
//  The New group panel's hero: the picture the group will be founded with.
//

import SwiftUI
import UniformTypeIdentifiers

/// The group-to-be's avatar over the pill that picks its picture, with Remove beside it once
/// there is one — the same shape as `AccountSetupProfileAvatar`, and what `whitenoise-ios`'s
/// Set Up Group step offers.
///
/// A picked file goes through `AvatarCropSheet` like every other profile and group picture. The
/// result stays here, held in `image`, until Create founds the group with it; nothing is uploaded
/// before then, so there is no group change to retry and no advisory to host.
struct GroupDraftImagePicker: View {
    let name: String
    @Binding var image: GroupDraftImage?
    var isEnabled = true
    /// Where a failed file pick is reported. A failed load or crop shows in the crop editor.
    var onError: (String) -> Void = { _ in }

    @State private var isFileImporterPresented = false
    @State private var cropModel: AvatarCropViewModel?

    static let avatarSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 10) {
            GroupDraftAvatar(name: name, image: image, size: Self.avatarSize)

            HStack(spacing: 8) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Text(L10n.string(image == nil ? "Add photo" : "Change photo"))
                }
                .accessibilityIdentifier("compose.groupImage")

                if image != nil {
                    Button {
                        image = nil
                    } label: {
                        Text(L10n.string("Remove photo"))
                    }
                    .accessibilityIdentifier("compose.groupImage.remove")
                }
            }
            .wnSecondaryButtonStyle()
            .controlSize(.small)
            .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                cropModel = AvatarCropViewModel(
                    loadData: { try await AvatarImageCropSource.data(fromFileURL: url) },
                    commit: { data in
                        image = try await GroupDraftImage.prepared(fromCroppedImageData: data)
                    }
                )
            case .failure(let error):
                onError(UserFacingError.message(for: error))
            }
        }
        .avatarCropSheet($cropModel)
    }
}

/// The circle itself: the chosen picture, else the name's initials, else the group glyph while
/// the group has no name yet.
private struct GroupDraftAvatar: View {
    let name: String
    let image: GroupDraftImage?
    let size: CGFloat

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let image {
                ProfileImageAvatarView(
                    seed: trimmedName,
                    initials: trimmedName,
                    sanitizedPictureURL: nil,
                    localImagePayload: image.preview,
                    size: size,
                    isSelected: false
                )
            } else if trimmedName.isEmpty {
                Image(systemName: "person.2.fill")
                    .wnFont(.semiBold32)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(WNColor.fillSecondary))
                    .overlay(Circle().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            } else {
                AvatarView(seed: trimmedName, initials: trimmedName, size: size, isSelected: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Group image"))
    }
}

#Preview("No picture") {
    @Previewable @State var image: GroupDraftImage?
    GroupDraftImagePicker(name: "Hiking crew", image: $image)
        .padding()
        .frame(width: 320)
}

#Preview("Unnamed") {
    @Previewable @State var image: GroupDraftImage?
    GroupDraftImagePicker(name: "", image: $image)
        .padding()
        .frame(width: 320)
}
