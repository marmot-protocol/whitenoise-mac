import Foundation

struct OpenverseImageRecord: Decodable {
    let id: String
    let title: String?
    let url: String?
    let thumbnail: String?
    let creator: String?
    let license: String?
    let attribution: String?
    let foreignLandingURL: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case thumbnail
        case creator
        case license
        case attribution
        case foreignLandingURL = "foreign_landing_url"
        case width
        case height
    }

    var groupImageSearchResult: GroupImageSearchResult? {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty,
            let parsedURL = URL(string: url),
            ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "")
        else { return nil }

        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupImageSearchResult(
            id: id,
            title: title?.isEmpty == false ? title! : L10n.string("Untitled image"),
            imageURL: url,
            thumbnailURL: thumbnail?.nilIfBlank,
            creator: creator?.nilIfBlank,
            license: license?.nilIfBlank,
            attribution: attribution?.nilIfBlank,
            sourceURL: foreignLandingURL?.nilIfBlank,
            width: width,
            height: height
        )
    }
}
