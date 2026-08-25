//
//  ProfileImagePickerTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Guards the two-step choice the web picker was rebuilt around, and the tile that shows it.
///
/// `wn-ios-prototype`'s `AvatarWebImagePickerView` separates picking from committing: a tile takes
/// a badge, and **Done** is what downloads and applies it. The mac sheet used to do all of that on
/// the tile press. The difference is invisible in a screenshot — both draw a grid — which is why
/// it is asserted here rather than looked at.
///
/// `.serialized` and `@MainActor` because the rasterizing tests switch `NSAppearance`:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it, and
/// the failure lands on whichever suite happened to be running.
@Suite(.serialized) @MainActor struct ProfileImagePickerTests {

    // MARK: - Choosing is not committing

    /// The whole point of the port. A press moves the badge and touches nothing else — no
    /// download, no upload, no dismissal — so a second candidate costs a second click rather than
    /// a committed profile and a reopened sheet.
    @Test func pressingATileSelectsItWithoutDownloadingAnything() async {
        let loader = StubProfileImageSourceLoader()
        let state = WorkspaceState(groupImageSourceLoader: loader)
        let first = Self.result(id: "first")
        let second = Self.result(id: "second")

        state.presentProfileImagePicker(destination: .signUpDraft)
        state.selectProfileImage(first)

        #expect(state.selectedProfileImageResult == first)
        #expect(await loader.requestedURLs.isEmpty)
        #expect(state.isProfileImagePickerPresented)

        state.selectProfileImage(second)

        #expect(state.selectedProfileImageResult == second)
        #expect(await loader.requestedURLs.isEmpty)
    }

    /// Pressing the badged tile again takes the badge off. Without this the only way out of a
    /// selection is to pick a different one, and **Done** can never be re-disabled.
    @Test func pressingTheSelectedTileAgainClearsIt() {
        let state = WorkspaceState()
        let result = Self.result(id: "first")

        state.selectProfileImage(result)
        state.selectProfileImage(result)

        #expect(state.selectedProfileImageResult == nil)
    }

    /// `Done` with an empty badge is a no-op rather than a crash or a committed nothing. The
    /// button is disabled in that state, but the disabled-ness is a view detail and this is the
    /// thing it protects.
    @Test func confirmingWithNothingSelectedDoesNothing() async {
        let loader = StubProfileImageSourceLoader()
        let state = WorkspaceState(groupImageSourceLoader: loader)

        await state.useSelectedProfileImage()

        #expect(await loader.requestedURLs.isEmpty)
        #expect(state.signUpDraft.image == nil)
    }

    /// A selection is scoped to one visit. Reopening the sheet on a different destination — the
    /// sign-up draft after the settings page, say — would otherwise come up with **Done** already
    /// live over a grid of results from the previous search that are no longer on screen.
    @Test func openingAndClosingThePickerClearsTheSelection() {
        let state = WorkspaceState()

        state.presentProfileImagePicker(destination: .signUpDraft)
        state.selectProfileImage(Self.result(id: "first"))
        state.closeProfileImagePicker()

        #expect(state.selectedProfileImageResult == nil)

        state.selectProfileImage(Self.result(id: "second"))
        state.presentProfileImagePicker(destination: .activeAccount)

        #expect(state.selectedProfileImageResult == nil)
    }

    /// A search keeps the badge. The prototype is explicit about it — clearing the query "empties
    /// the query and results without undoing the image selection" — because the confirm button is
    /// the only thing that commits, and re-searching to check one more idea should not silently
    /// throw away the answer already found.
    @Test func searchingAgainKeepsTheSelection() async {
        let result = Self.result(id: "first")
        let state = WorkspaceState(groupImageSearchClient: StubProfileImageSearchClient(results: [result]))

        state.presentProfileImagePicker(destination: .signUpDraft)
        state.selectProfileImage(result)
        state.profileImageSearchQuery = "marmot"
        await state.searchProfileImages()

        #expect(state.selectedProfileImageResult == result)
    }

    // MARK: - Which empty state the empty grid is

    /// A search that came back with nothing has to say so, and the field cannot say it: a
    /// half-typed query is non-empty too, which is why the sheet used to flip to *No images* on the
    /// first keystroke and then tell a user who had just searched to enter a search.
    @Test func aSearchThatFindsNothingRecordsTheQueryItAnswered() async {
        let state = WorkspaceState(groupImageSearchClient: StubProfileImageSearchClient(results: []))

        state.presentProfileImagePicker(destination: .signUpDraft)

        #expect(state.profileImageResultsQuery == nil)

        state.profileImageSearchQuery = "marmot"
        await state.searchProfileImages()

        #expect(state.profileImageResults.isEmpty)
        #expect(state.profileImageResultsQuery == "marmot")

        // Typing on: the empty grid no longer answers what is in the field, so the sheet goes back
        // to asking for a search rather than reporting that there are none.
        state.profileImageSearchQuery = "marmot h"

        #expect(state.profileImageResultsQuery != "marmot h")
    }

    /// Emptying the field, and leaving the sheet, both put it back to nothing-searched-for-yet —
    /// otherwise the next visit opens on *No images* over a grid cleared with the results.
    @Test func clearingTheQueryOrClosingThePickerForgetsWhatWasSearched() async {
        let state = WorkspaceState(groupImageSearchClient: StubProfileImageSearchClient(results: []))

        state.presentProfileImagePicker(destination: .signUpDraft)
        state.profileImageSearchQuery = "marmot"
        await state.searchProfileImages()
        state.profileImageSearchQuery = ""
        await state.searchProfileImages()

        #expect(state.profileImageResultsQuery == nil)

        state.profileImageSearchQuery = "marmot"
        await state.searchProfileImages()
        state.closeProfileImagePicker()

        #expect(state.profileImageResultsQuery == nil)
    }

    /// A search that *failed* answered nothing either. Openverse being unreachable is not a
    /// spelling mistake, and the error line above the grid is what says what happened.
    @Test func aFailedSearchDoesNotClaimTheQueryFoundNothing() async {
        let state = WorkspaceState(groupImageSearchClient: FailingProfileImageSearchClient())

        state.presentProfileImagePicker(destination: .signUpDraft)
        state.profileImageSearchQuery = "marmot"
        await state.searchProfileImages()

        #expect(state.profileImageResultsQuery == nil)
        #expect(state.lastError != nil)
    }

    // MARK: - The file source no longer needs the sheet

    /// **Choose from Files** goes straight to the system open panel, so the destination that
    /// `beginProfileImageSelection()` switches on has to be set without presenting anything. The
    /// guards are the ones each entry point used to make for itself.
    @Test func preparingADestinationGuardsWithoutPresentingThePicker() async {
        let state = WorkspaceState()

        // No account yet: the settings path has nothing to upload under.
        #expect(!state.prepareProfileImageDestination(.activeAccount))
        // Not on the sign-up pane: nowhere to stage bytes.
        #expect(!state.prepareProfileImageDestination(.signUpDraft))

        state.authenticationMode = .signUp

        #expect(state.prepareProfileImageDestination(.signUpDraft))
        #expect(state.profileImagePickerDestination == .signUpDraft)
        #expect(!state.isProfileImagePickerPresented)
    }

    // MARK: - The tile is a square, and the badge is what says "this one"

    /// The prototype's tile is `Color.clear` at a 1:1 aspect ratio with the image clipped over it.
    /// The card this replaced was 1.18:1 — a landscape crop of a picture destined for a circle —
    /// and the difference is a ratio, which nothing else in the app would catch.
    @Test func theResultTileIsSquare() throws {
        let size = try #require(
            ImageRenderer(
                content: ProfileImageResultTile(result: Self.result(id: "first"), isSelected: false)
                    .frame(width: 120)
            ).nsImage?.size)

        #expect(
            abs(size.width - size.height) < 1,
            "the tile rendered \(size.width)x\(size.height) — that is not square")
    }

    /// Selection has to be visible on the pixels, in both appearances, and it has to be *absent*
    /// when nothing is selected — the negative control is the half that matters, since a badge
    /// drawn unconditionally would satisfy every positive check.
    ///
    /// The probe is the tile's bottom-trailing corner, which is where the prototype puts the
    /// badge, against a tile whose result carries no thumbnail so the ground under it is the flat
    /// `fillSecondary` placeholder in both states.
    @Test func theSelectedTileDrawsABadgeAndAnUnselectedOneDoesNot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let plain = try Self.badgeCornerLuminances(isSelected: false, appearance: appearance)
            let badged = try Self.badgeCornerLuminances(isSelected: true, appearance: appearance)

            #expect(
                Set(plain).count == 1,
                "the unselected tile's corner is not flat in \(appearance.rawValue) — something is drawn there")
            #expect(
                Set(badged).count > 1,
                "the selected tile's corner is flat in \(appearance.rawValue) — the badge is missing")
        }
    }

    // MARK: - Helpers

    private static let renderScale: CGFloat = 2
    private static let tileWidth: CGFloat = 120

    private static func result(id: String) -> GroupImageSearchResult {
        GroupImageSearchResult(
            id: id,
            title: "Portrait",
            imageURL: "https://example.com/\(id).png",
            thumbnailURL: nil,
            creator: "A Photographer",
            license: "cc0",
            attribution: nil,
            sourceURL: nil,
            width: 640,
            height: 640
        )
    }

    /// Luminances sampled along the bottom edge of the tile's trailing corner, where the badge is.
    ///
    /// Both halves of the appearance are set: `performAsCurrentDrawingAppearance` switches what
    /// `NSColor` dynamic providers resolve to, but a `Color(nsColor:)` inside a SwiftUI body is
    /// resolved by SwiftUI against `\.colorScheme` instead, so setting only the `NSAppearance`
    /// renders the whole palette in its light values under a dark appearance.
    private static func badgeCornerLuminances(
        isSelected: Bool,
        appearance: NSAppearance.Name
    ) throws -> [CGFloat] {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(
            content: ProfileImageResultTile(result: result(id: "first"), isSelected: isSelected)
                .frame(width: tileWidth)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = renderScale

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }

        let tiff = try #require(image?.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))

        // The badge is a 24pt disc inset 6pt from both edges, so its centre sits 18pt in from the
        // trailing and bottom edges. The scan crosses it horizontally.
        let row = bitmap.pixelsHigh - Int(18 * renderScale)
        return ((bitmap.pixelsWide - Int(30 * renderScale))..<(bitmap.pixelsWide - Int(6 * renderScale)))
            .compactMap { column in
                guard let color = bitmap.colorAt(x: column, y: row) else { return nil }
                let converted = color.usingColorSpace(.deviceRGB) ?? color
                return 0.2126 * converted.redComponent
                    + 0.7152 * converted.greenComponent
                    + 0.0722 * converted.blueComponent
            }
    }
}

/// Records what was asked for and hands back nothing. The point of every test that uses it is
/// that the list stays empty: choosing a tile must not fetch its bytes.
private actor StubProfileImageSourceLoader: GroupImageSourceLoading {
    private(set) var requestedURLs: [URL] = []

    func data(for url: URL) async -> Data? {
        requestedURLs.append(url)
        return nil
    }
}

/// The search service being unreachable, which is a different empty grid from a search that ran.
private actor FailingProfileImageSearchClient: GroupImageSearchClient {
    struct Unreachable: Error, LocalizedError {
        var errorDescription: String? { "unreachable" }
    }

    func searchImages(query: String) async throws -> [GroupImageSearchResult] {
        throw Unreachable()
    }
}

private actor StubProfileImageSearchClient: GroupImageSearchClient {
    private let results: [GroupImageSearchResult]

    init(results: [GroupImageSearchResult]) {
        self.results = results
    }

    func searchImages(query: String) async throws -> [GroupImageSearchResult] {
        results
    }
}
