import Foundation

struct GroupImageSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let imageURL: String
    let thumbnailURL: String?
    let creator: String?
    let license: String?
    let attribution: String?
    let sourceURL: String?
    let width: Int?
    let height: Int?

    var dimension: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }

    /// The URL used to render the search-result thumbnail. Only the
    /// Openverse-proxied `thumbnailURL` is used; the arbitrary origin
    /// `imageURL` is never fetched for previews (whitenoise-mac#315), so a
    /// result without a usable thumbnail renders the placeholder instead.
    var previewURL: URL? {
        guard let thumbnailURL = thumbnailURL?.nilIfBlank else { return nil }
        return URL(string: thumbnailURL)
    }

    var creditLine: String {
        let creatorText = creator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let licenseText = license?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (creatorText?.isEmpty == false ? creatorText : nil, licenseText?.isEmpty == false ? licenseText : nil) {
        case (let creator?, let license?):
            return "\(creator) · \(license.uppercased())"
        case (let creator?, nil):
            return creator
        case (nil, let license?):
            return license.uppercased()
        default:
            return L10n.string("Openverse")
        }
    }
}
