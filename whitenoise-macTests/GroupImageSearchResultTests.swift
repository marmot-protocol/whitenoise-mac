//
//  GroupImageSearchResultTests.swift
//  whitenoise-macTests
//

import Foundation
import Testing

@testable import whitenoise_mac

struct GroupImageSearchResultTests {
    private func record(_ fields: [String: Any]) throws -> OpenverseImageRecord {
        var json: [String: Any] = ["id": "img-1"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(OpenverseImageRecord.self, from: data)
    }

    private func result(creator: String?, license: String?) -> GroupImageSearchResult {
        GroupImageSearchResult(
            id: "img",
            title: "Title",
            imageURL: "https://example.com/a.jpg",
            thumbnailURL: nil,
            creator: creator,
            license: license,
            attribution: nil,
            sourceURL: nil,
            width: nil,
            height: nil
        )
    }

    @Test func recordMapsTrimmedFieldsAndDropsBlankOnes() throws {
        let mapped = try #require(
            try record([
                "title": "  Sunset  ",
                "url": "  https://cdn.example/sunset.jpg  ",
                "thumbnail": "   ",
                "creator": "Ada",
                "license": "",
                "attribution": "Photo by Ada",
                "foreign_landing_url": "https://openverse.org/image/img-1",
                "width": 640,
                "height": 480,
            ]).groupImageSearchResult
        )

        #expect(mapped.id == "img-1")
        #expect(mapped.title == "Sunset")
        #expect(mapped.imageURL == "https://cdn.example/sunset.jpg")
        #expect(mapped.thumbnailURL == nil)
        #expect(mapped.previewURL == nil)
        #expect(mapped.creator == "Ada")
        #expect(mapped.license == nil)
        #expect(mapped.attribution == "Photo by Ada")
        #expect(mapped.sourceURL == "https://openverse.org/image/img-1")
        #expect(mapped.dimension == "640x480")
    }

    @Test func recordWithoutATitleFallsBackToThePlaceholder() throws {
        let mapped = try #require(
            try record(["title": "  ", "url": "https://cdn.example/a.png"]).groupImageSearchResult
        )
        #expect(mapped.title == L10n.string("Untitled image"))
    }

    @Test func recordWithoutAnHTTPImageURLIsDropped() throws {
        #expect(try record([:]).groupImageSearchResult == nil)
        #expect(try record(["url": "   "]).groupImageSearchResult == nil)
        #expect(try record(["url": "ftp://cdn.example/a.png"]).groupImageSearchResult == nil)
        #expect(try record(["url": "file:///etc/passwd"]).groupImageSearchResult == nil)
        #expect(try record(["url": "HTTP://cdn.example/a.png"]).groupImageSearchResult != nil)
    }

    @Test func dimensionNeedsBothSidesPositive() {
        func dimension(_ width: Int?, _ height: Int?) -> String? {
            GroupImageSearchResult(
                id: "img", title: "t", imageURL: "https://x", thumbnailURL: nil, creator: nil,
                license: nil, attribution: nil, sourceURL: nil, width: width, height: height
            ).dimension
        }
        #expect(dimension(1024, 768) == "1024x768")
        #expect(dimension(nil, 768) == nil)
        #expect(dimension(1024, nil) == nil)
        #expect(dimension(0, 768) == nil)
        #expect(dimension(1024, -1) == nil)
    }

    @Test func creditLineCombinesCreatorAndUppercasedLicense() {
        #expect(result(creator: " Ada ", license: " by-sa ").creditLine == "Ada · BY-SA")
        #expect(result(creator: "Ada", license: "  ").creditLine == "Ada")
        #expect(result(creator: nil, license: "cc0").creditLine == "CC0")
        #expect(result(creator: "", license: nil).creditLine == L10n.string("Openverse"))
    }

    @Test func searchErrorsDescribeThemselves() throws {
        let errors: [GroupImageSearchError] = [.invalidURL, .invalidResponse, .requestFailed(statusCode: 503)]
        let descriptions = try errors.map { try #require($0.errorDescription) }
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(Set(descriptions).count == errors.count)
        #expect(descriptions[2].contains("503"))
    }
}
