//
//  AvatarCropSheet.swift
//  whitenoise-mac
//
//  The circular crop every profile and group picture passes through before it is saved.
//

import ImageIO
import SwiftUI

private struct AvatarCropSheetModifier: ViewModifier {
    @Binding var model: AvatarCropViewModel?

    func body(content: Content) -> some View {
        content.sheet(item: $model) { model in
            AvatarCropSheet(model: model, onClose: { self.model = nil })
        }
    }
}

extension View {
    /// Presents the crop editor whenever `model` is set, and clears it when the editor closes.
    ///
    /// The one presentation every picture source uses — the profile avatar's file menu, the
    /// profile web picker, and both halves of the group image picker — so the crop looks and
    /// behaves the same wherever a picture is chosen.
    func avatarCropSheet(_ model: Binding<AvatarCropViewModel?>) -> some View {
        modifier(AvatarCropSheetModifier(model: model))
    }
}

/// Ported from `whitenoise-ios`'s `AvatarImageCropEditor`: the picture under a circle, dragged to
/// position and zoomed to frame, then rendered out square.
///
/// Where iOS has only a pinch, a Mac also gets a slider: a mouse has no pinch, and a trackpad
/// pinch is not discoverable. Outside the circle the picture is dimmed rather than cut away, so
/// what is about to be left out stays visible while it is framed.
struct AvatarCropSheet: View {
    let model: AvatarCropViewModel
    let onClose: () -> Void

    static let sheetWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            AvatarCropHeader(isSaving: model.isSaving, onClose: onClose)

            Divider()

            AvatarCropContent(model: model)
                .padding(18)
                .frame(maxWidth: .infinity)

            Divider()

            AvatarCropFooter(model: model, onClose: onClose)
        }
        .frame(width: Self.sheetWidth)
        .background {
            LiquidGlassBackground()
        }
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.load() }
    }
}

private struct AvatarCropHeader: View {
    let isSaving: Bool
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(L10n.string("Crop image"))
                .wnFont(.semiBold14)

            Spacer()

            GlassCircleCloseButton(action: onClose)
                .disabled(isSaving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct AvatarCropContent: View {
    let model: AvatarCropViewModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .loading:
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: model.cropSide, height: model.cropSide)

            case .failed(let message):
                ContentUnavailableView(
                    L10n.string("Couldn’t add photo"),
                    systemImage: "photo",
                    description: Text(message)
                )
                .frame(minHeight: model.cropSide)

            case .ready:
                AvatarCropCanvas(model: model)

                Text(L10n.string("Drag to position the image. Pinch or use the slider to zoom."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                AvatarCropZoomSlider(model: model)

                SettingsErrorView(error: model.saveError)
            }
        }
    }
}

/// The picture, the dimmed surround, and the circle — and the gestures that move them.
private struct AvatarCropCanvas: View {
    let model: AvatarCropViewModel

    var body: some View {
        let displayed = model.displayedSize

        ZStack {
            Color.black

            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayed.width, height: displayed.height)
                    .offset(model.offset)
            }

            AvatarCropMask()
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            Circle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: model.cropSide, height: model.cropSide)
        .clipShape(.rect(cornerRadius: 8))
        .contentShape(.rect)
        .gesture(
            DragGesture()
                .onChanged { model.drag(by: $0.translation) }
                .onEnded { _ in model.endDrag() }
                .simultaneously(
                    with: MagnifyGesture()
                        .onChanged { model.pinch(by: $0.magnification) }
                        .onEnded { _ in model.endPinch() }
                )
        )
        .pointerStyle(.grabIdle)
        .accessibilityElement()
        .accessibilityLabel(L10n.string("Crop image"))
        .accessibilityAddTraits(.isImage)
    }
}

/// The square with the crop circle punched out of it, for an even-odd fill.
private struct AvatarCropMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: rect)
        return path
    }
}

private struct AvatarCropZoomSlider: View {
    let model: AvatarCropViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                in: 1...AvatarImageCropper.maximumZoom
            )
            .accessibilityLabel(L10n.string("Zoom"))
            .disabled(model.isSaving)

            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .accessibilityHidden(true)
        }
        .frame(width: model.cropSide)
    }
}

private struct AvatarCropFooter: View {
    let model: AvatarCropViewModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            if model.isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Button(L10n.string("Cancel"), action: onClose)
                .buttonStyle(.wnSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)

            Button(L10n.string("Done")) {
                Task {
                    if await model.save() { onClose() }
                }
            }
            .nativeGlassProminentButtonStyle()
            .tint(WNColor.fillPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
            .accessibilityIdentifier("avatar-crop.done")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

#Preview("Avatar crop") {
    AvatarCropSheet(
        model: AvatarCropViewModel(
            loadData: { AvatarCropPreviewImage.pngData() },
            commit: { _ in }
        ),
        onClose: {}
    )
}

#Preview("Avatar crop failure") {
    AvatarCropSheet(
        model: AvatarCropViewModel(
            loadData: { throw AvatarImageCropSource.Failure.downloadFailed },
            commit: { _ in }
        ),
        onClose: {}
    )
}

/// A landscape gradient, so the preview shows the cover-fit and the dimmed sides.
private nonisolated enum AvatarCropPreviewImage {
    static func pngData() -> Data {
        let width = 1_200
        let height = 800
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
                    CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1),
                ]
                    as CFArray,
                locations: [0, 1]
            )
        else { return Data() }
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: []
        )
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
