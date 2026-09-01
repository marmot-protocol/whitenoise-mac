//
//  MessageImageGalleryNavigation.swift
//  whitenoise-mac
//

import Foundation

/// Paging through the photos of one message in the full-screen viewer.
///
/// Held apart from `MessageImageGalleryOverlay` because everything worth guarding here is arithmetic
/// the overlay used to inline: which chevron is live at either end of the run, that paging is
/// suppressed while a photo is magnified — dropping the next one in at someone else's zoom — and
/// that every icon-only control announces itself in the app's selected language rather than the
/// system's.
struct MessageImageGalleryNavigation: Equatable {
    let imageCount: Int
    private(set) var selectedIndex: Int
    /// Paging out of a magnified photo would drop the next one in at someone else's zoom, so the
    /// chevrons go dead while one is zoomed. Flutter suppresses paging entirely for the same reason.
    var isZoomed: Bool

    init(imageCount: Int, selectedIndex: Int, isZoomed: Bool = false) {
        self.imageCount = imageCount
        self.selectedIndex = min(max(0, selectedIndex), max(0, imageCount - 1))
        self.isZoomed = isZoomed
    }

    /// A single photo has nowhere to page to, so neither the chevrons nor the counter are drawn.
    var showsNavigation: Bool {
        imageCount > 1
    }

    var canGoToPreviousImage: Bool {
        showsNavigation && selectedIndex > 0 && !isZoomed
    }

    var canGoToNextImage: Bool {
        showsNavigation && selectedIndex < imageCount - 1 && !isZoomed
    }

    /// Clamped rather than guarded, because the arrow keys reach these with no button in between:
    /// holding ← at the first photo must sit still, not run off the front of the run.
    mutating func goToPreviousImage() {
        guard canGoToPreviousImage else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    mutating func goToNextImage() {
        guard canGoToNextImage else { return }
        selectedIndex = min(imageCount - 1, selectedIndex + 1)
    }

    /// The index the viewer reads a photo's payload at, safe for an empty or out-of-range run.
    func clampedIndex() -> Int {
        min(max(0, selectedIndex), max(0, imageCount - 1))
    }

    var positionLabel: String {
        "\(selectedIndex + 1) / \(imageCount)"
    }

    // Every icon-only control in the viewer names itself through `L10n.string`, so VoiceOver
    // announces it in the language the app is set to rather than the one the system is set to.
    static var closeLabel: String { L10n.string("Close") }
    static var previousImageLabel: String { L10n.string("Previous image") }
    static var nextImageLabel: String { L10n.string("Next image") }
}
