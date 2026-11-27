//
//  GroupDraftImagePicker.swift
//  whitenoise-mac
//
//  The New group panel's hero: the picture the group will be founded with.
//

import AppKit
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
                    .wnFont(.custom(size: size * 0.38, weight: .semiBold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
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

#Preview("With picture") {
    @Previewable @State var image: GroupDraftImage? = {
        // A flat 64×64 JPEG drawn inline: the test bundle's image helpers are not reachable here.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmap.flatMap(NSGraphicsContext.init(bitmapImageRep:))
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap?.representation(using: .jpeg, properties: [:]) else { return nil }
        return GroupDraftImage(
            attachment: PendingMediaAttachment(
                fileName: "avatar.jpg", mediaType: "image/jpeg", data: data, dim: "64x64"))
    }()
    GroupDraftImagePicker(name: "Hiking crew", image: $image)
        .padding()
        .frame(width: 320)
}
