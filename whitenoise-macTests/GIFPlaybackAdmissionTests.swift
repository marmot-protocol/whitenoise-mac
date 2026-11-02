import Foundation
import Testing

@testable import whitenoise_mac

struct GIFPlaybackAdmissionTests {
    @Test func admitsSmallAnimationAndUsesLogicalCanvas() throws {
        let data = Self.container(width: 3, height: 2, frames: [Self.frame(), Self.frame(left: 2, top: 1)])
        #expect(GIFPlaybackAdmission.inspect(data) == .init(width: 3, height: 2, frameCount: 2))
        #expect(try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: data) == 1.5)
    }

    @Test func rejectsLargeCanvasWithTinyPartialFramesBeforeNativeInspection() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 4_097, height: 1)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 65_535, height: 65_535)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 0, height: 1)) == nil)
    }

    @Test func capsTheLogicalCanvasArea() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 2_048, height: 2_048)) != nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 2_048, height: 2_049)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 4_096, height: 4_096)) == nil)
    }

    @Test func rejectsAdmittedCanvasThatImageIOCannotDecode() {
        // 1x1 frames on a 400x400 canvas pass the header checks, but ImageIO refuses frame 0
        // and the animator would crash on it.
        let data = Self.container(width: 400, height: 400)
        #expect(GIFPlaybackAdmission.inspect(data) != nil)
        #expect(throws: GiphyRemoteMediaLoader.Failure.unsupportedMedia) {
            try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: data)
        }
    }

    /// The reader indexes `Data` in place, so a slice whose `startIndex` is not 0 must read the
    /// same as a fresh buffer.
    @Test func readsADataSliceFromItsOwnStartIndex() {
        let slice = (Data([0xFF, 0xFF, 0xFF]) + Self.container(width: 3, height: 2)).dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(
            GIFPlaybackAdmission.inspect(slice) == GIFPlaybackAdmission.inspect(Self.container(width: 3, height: 2)))
        #expect(GIFPlaybackAdmission.inspect(slice)?.width == 3)
    }

    @Test func boundsEveryFrameRectangle() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(width: 2)])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(left: 1)])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(height: 0)])) == nil)
    }

    @Test func enforcesFrameCountAtTheBoundary() {
        let frame = Self.frame()
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: Array(repeating: frame, count: 1_000))) != nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: Array(repeating: frame, count: 1_001))) == nil)
    }

    @Test func enforcesAggregateCanvasBudgetWithoutAllocatingPixels() {
        // Eight full logical canvases are exactly 32 Mi pixels, though the stored frames are 1x1.
        let boundary = Self.container(width: 2_048, height: 2_048, frames: Array(repeating: Self.frame(), count: 8))
        #expect(GIFPlaybackAdmission.inspect(boundary) != nil)
        let over = Self.container(width: 2_048, height: 2_048, frames: Array(repeating: Self.frame(), count: 9))
        #expect(GIFPlaybackAdmission.inspect(over) == nil)
    }

    @Test func rejectsEveryIncompletePrefixAndTrailingGarbage() {
        let valid = Self.container()
        for length in 0..<valid.count {
            #expect(GIFPlaybackAdmission.inspect(Data(valid.prefix(length))) == nil)
        }
        #expect(GIFPlaybackAdmission.inspect(valid + Data([0])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame()])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Data("not a GIF".utf8)) == nil)
    }

    @Test func handlesColorTablesAndBoundedExtensions() {
        let animation = Self.container()
        var bytes = Array(animation)
        bytes[10] = 0x80  // Global two-entry color table.
        bytes.insert(contentsOf: [0, 0, 0, 255, 255, 255], at: 13)
        bytes.insert(contentsOf: [0x21, 0xFE, 3, 65, 66, 67, 0], at: 19)
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) != nil)
        bytes[21] = 255  // Truncated comment block cannot be skipped past the container.
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) == nil)
    }

    @Test func rejectsUnsupportedRenderingAndEncodedOverrun() {
        var bytes = Array(Self.container())
        bytes.insert(contentsOf: [0x21, 0x01, 0], at: 13)
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Data(count: GiphySearchClient.maximumMediaBytes + 1)) == nil)
    }

    @Test func reportsWhyAContainerWasRefused() {
        func reason(_ data: Data) -> GIFPlaybackAdmission.Rejection? {
            if case .failure(let rejection) = GIFPlaybackAdmission.evaluate(data) { return rejection }
            return nil
        }
        let frame = Self.frame()
        var reserved = frame
        reserved[17] |= 0x08  // Image descriptor flags.
        var plainText = Array(Self.container())
        plainText.insert(contentsOf: [0x21, 0x01, 0], at: 13)
        #expect(reason(Self.container()) == nil)
        #expect(reason(Data(count: 4)) == .size)
        #expect(reason(Data("GIF00a".utf8) + Self.container().dropFirst(6)) == .signature)
        #expect(reason(Self.container(width: 4_097, height: 1)) == .canvas)
        #expect(reason(Self.container(width: 4_096, height: 4_096)) == .area)
        #expect(reason(Self.container(frames: [frame])) == .frames)
        #expect(reason(Self.container(frames: Array(repeating: frame, count: 1_001))) == .frames)
        let overBudget = Self.container(width: 2_048, height: 2_048, frames: Array(repeating: frame, count: 9))
        #expect(reason(overBudget) == .aggregate)
        #expect(reason(Self.container(frames: [frame, Self.frame(left: 1)])) == .rect)
        #expect(reason(Self.container(frames: [frame, reserved])) == .reservedBits)
        #expect(reason(Data(plainText)) == .extension)
        #expect(reason(Self.container().dropLast()) == .truncated)
        #expect(reason(Self.container() + Data([0])) == .trailingData)
    }

    @Test func playbackPreparationCannotBypassAdmissionWithSmallAdvertisedDimensions() async {
        let media = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/fixture/giphy.gif")!,
            width: 1, height: 1, attribution: nil)
        let oversizedCanvas = Self.container(width: 4_097, height: 1)
        for _ in 0..<2 {  // A second attempt takes the same admission path.
            do {
                _ = try await GiphyRemoteMediaLoader.preparePlayback(for: media, apiKey: nil) { _ in oversizedCanvas }
                Issue.record("Oversized GIF was admitted")
            } catch {
                #expect(error as? GiphyRemoteMediaLoader.Failure == .unsupportedMedia)
            }
        }
    }

    /// Hand-assembled complete GIFs keep all rejection tests metadata-only and tiny. The 1x1
    /// LZW payload is a clear code, one pixel, and an end code; no huge raster is constructed.
    private static func container(width: Int = 1, height: Int = 1, frames: [[UInt8]]? = nil) -> Data {
        var bytes = Array("GIF89a".utf8)
        bytes += word(width) + word(height) + [0, 0, 0]
        for frame in frames ?? [Self.frame(), Self.frame()] { bytes += frame }
        bytes.append(0x3B)
        return Data(bytes)
    }

    private static func frame(left: Int = 0, top: Int = 0, width: Int = 1, height: Int = 1) -> [UInt8] {
        // A local color table makes the partial-frame animation valid without a global table.
        [0x21, 0xF9, 4, 0, 10, 0, 0, 0, 0x2C]
            + word(left) + word(top) + word(width) + word(height)
            + [0x80, 0, 0, 0, 255, 255, 255, 2, 2, 0x44, 0x01, 0]
    }

    private static func word(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}
