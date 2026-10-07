//
//  AvatarCropViewModel.swift
//  whitenoise-mac
//
//  One circular crop, from picked bytes to the JPEG its destination stores.
//

import CoreGraphics
import Foundation
import Observation

/// The state behind `AvatarCropSheet`: the decoded picture, where it sits under the crop circle,
/// and the save that hands the cropped square to whoever asked for it.
///
/// It knows nothing about profiles or groups. A caller supplies where the bytes come from —
/// `AvatarImageCropSource` has the file and web-search cases — and what to do with the result,
/// which is how one editor serves the profile settings, the sign-up pane, and the group image
/// picker alike. Ported from `whitenoise-ios`'s `AvatarImageCropEditor`, whose state lived in the
/// view; here it lives where a test can drive it.
@MainActor
@Observable
final class AvatarCropViewModel: Identifiable {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The side of the square the circle is inscribed in, in points.
    nonisolated static let defaultCropSide: CGFloat = 280

    let cropSide: CGFloat
    private(set) var phase: Phase = .loading
    private(set) var image: CGImage?
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private(set) var isSaving = false
    private(set) var saveError: String?

    /// Where the gesture in progress started from. Gestures report totals since they began, so
    /// each change is applied to this rather than to the value the previous change produced.
    @ObservationIgnored private var dragOrigin: CGSize?
    @ObservationIgnored private var pinchOrigin: CGFloat?
    @ObservationIgnored private let loadData: @MainActor () async throws -> Data
    @ObservationIgnored private let commit: @MainActor (Data) async throws -> Void

    /// - Parameters:
    ///   - loadData: The picked bytes. Runs when the sheet appears, so a download shows as the
    ///     editor's own spinner rather than as a pause before anything opens.
    ///   - commit: Receives the cropped JPEG. Throwing keeps the editor open with the error under
    ///     the image; returning closes it.
    init(
        cropSide: CGFloat = defaultCropSide,
        loadData: @escaping @MainActor () async throws -> Data,
        commit: @escaping @MainActor (Data) async throws -> Void
    ) {
        self.cropSide = cropSide
        self.loadData = loadData
        self.commit = commit
    }

    var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    var displayedSize: CGSize {
        AvatarImageCropper.displayedSize(imageSize: imageSize, cropSide: cropSide, zoom: zoom)
    }

    var canSave: Bool { phase == .ready && !isSaving }

    func load() async {
        guard image == nil else { return }
        phase = .loading
        do {
            let data = try await loadData()
            let decoded = await Task.detached(priority: .userInitiated) {
                AvatarImageCropper.normalizedImage(from: data)
            }.value
            try Task.checkCancellation()
            guard let decoded else { throw OutgoingMediaDraftProcessor.Failure.unsupportedImage }
            image = decoded
            zoom = 1
            offset = .zero
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func drag(by translation: CGSize) {
        guard image != nil, !isSaving else { return }
        let origin = dragOrigin ?? offset
        dragOrigin = origin
        offset = AvatarImageCropper.clampedOffset(
            CGSize(width: origin.width + translation.width, height: origin.height + translation.height),
            imageSize: imageSize,
            cropSide: cropSide,
            zoom: zoom
        )
    }

    func endDrag() {
        dragOrigin = nil
    }

    func pinch(by magnification: CGFloat) {
        let origin = pinchOrigin ?? zoom
        pinchOrigin = origin
        setZoom(origin * magnification)
    }

    func endPinch() {
        pinchOrigin = nil
    }

    func setZoom(_ newValue: CGFloat) {
        guard image != nil, !isSaving else { return }
        let clamped = AvatarImageCropper.clampedZoom(newValue)
        offset = AvatarImageCropper.rezoomedOffset(
            offset,
            imageSize: imageSize,
            cropSide: cropSide,
            from: zoom,
            to: clamped
        )
        zoom = clamped
    }

    /// Renders the crop and hands it to `commit`. Returns whether the editor should close.
    func save() async -> Bool {
        guard canSave, let image else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let side = cropSide
        let zoom = zoom
        let offset = offset
        let data = await Task.detached(priority: .userInitiated) {
            AvatarImageCropper.croppedJPEG(image: image, cropSide: side, zoom: zoom, offset: offset)
        }.value
        guard let data else {
            saveError = OutgoingMediaDraftProcessor.Failure.encodingFailed.localizedDescription
            return false
        }

        do {
            try await commit(data)
            return true
        } catch is CancellationError {
            return false
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
