import Foundation
import Testing

@testable import whitenoise_mac

struct LinkPreviewTests {
    private let base = URL(string: "https://example.com/articles/one")!

    private func parse(_ html: String) -> LinkPreviewMetadata? {
        LinkPreviewMetadata.parse(html: Data(html.utf8), baseURL: base)
    }

    private func document(_ blocks: [MarkdownDisplayBlock]) -> MarkdownDisplayDocument {
        MarkdownDisplayDocument(
            blocks: blocks.enumerated().map { MarkdownDisplayBlockNode(id: $0.offset, block: $0.element) },
            truncated: false
        )
    }

    private static func htmlResponse(_ url: URL, contentType: String = "text/html; charset=utf-8") -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
    }

    @Test func readsOpenGraphTitleAndResolvesRelativeImage() throws {
        let metadata = try #require(
            parse(
                """
                <html><head>
                <meta property="og:title" content="Tom &amp; Jerry&#39;s &#x201C;Day&#x201D;">
                <meta content='/img/cover.jpg' property='og:image'>
                <title>Fallback</title>
                </head><body></body></html>
                """))
        #expect(metadata.title == "Tom & Jerry's \u{201C}Day\u{201D}")
        #expect(metadata.imageURL == URL(string: "https://example.com/img/cover.jpg"))
    }

    @Test func fallsBackToTwitterThenDocumentTitle() throws {
        let twitter = try #require(
            parse(#"<head><meta name="twitter:title" content="Tweet title"><title>Doc</title></head>"#))
        #expect(twitter.title == "Tweet title")
        #expect(twitter.imageURL == nil)

        let document = try #require(parse("<head><title>\n  Document   title \n</title></head>"))
        #expect(document.title == "Document title")
    }

    @Test func prefersSecureImageAndRejectsUnsafeImageURLs() throws {
        let secure = try #require(
            parse(
                """
                <head>
                <meta property="og:image" content="https://cdn.example.com/plain.png">
                <meta property="og:image:secure_url" content="https://cdn.example.com/secure.png">
                </head>
                """))
        #expect(secure.imageURL == URL(string: "https://cdn.example.com/secure.png"))

        for unsafe in [
            "http://cdn.example.com/a.png", "https://127.0.0.1/a.png", "https://10.0.0.4/a.png",
            "javascript:alert(1)", "https://cdn.example.com:8443/a.png", "https://user@cdn.example.com/a.png",
        ] {
            #expect(parse(#"<head><meta property="og:image" content="\#(unsafe)"></head>"#) == nil)
        }
    }

    @Test func findsMetadataBehindLargeInlineHeadScripts() throws {
        let script = "<script>" + String(repeating: "x", count: 900 * 1024) + "</script>"
        let metadata = try #require(
            parse(#"<head>\#(script)<meta property="og:image" content="https://i.example.com/v.jpg"></head>"#))
        #expect(metadata.imageURL == URL(string: "https://i.example.com/v.jpg"))
    }

    @Test func ignoresMetadataAfterTheHeadAndReturnsNilWhenEmpty() {
        #expect(parse(#"<head></head><body><meta property="og:title" content="Body"></body>"#) == nil)
        #expect(parse("<html><body>No metadata</body></html>") == nil)
        #expect(parse(#"<head><meta property="og:title" content="   "></head>"#) == nil)
    }

    @Test func boundsAndSanitizesTheTitle() throws {
        let long = String(repeating: "a", count: 1_000)
        let metadata = try #require(parse(#"<head><meta property="og:title" content="\u{202E}\#(long)"></head>"#))
        let title = try #require(metadata.title)
        #expect(title.count == LinkPreviewMetadata.maximumTitleLength)
        #expect(!title.unicodeScalars.contains("\u{202E}"))
    }

    @Test func previewURLPicksTheFirstFetchableLink() {
        var text = AttributedString("mail http https")
        text[text.range(of: "mail")!].link = URL(string: "mailto:someone@example.com")
        text[text.range(of: "http ")!].link = URL(string: "http://insecure.example.com")
        text[text.range(of: "https")!].link = URL(string: "https://secure.example.com/page")

        #expect(
            LinkPreviewMetadata.previewURL(in: document([.paragraph(text)]))
                == URL(string: "https://secure.example.com/page"))
        #expect(LinkPreviewMetadata.previewURL(in: nil) == nil)
        #expect(LinkPreviewMetadata.previewURL(in: document([.codeBlock("https://example.com")])) == nil)
    }

    @Test func previewURLLooksInsideQuotesAndLists() {
        var linked = AttributedString("site")
        linked.link = URL(string: "https://nested.example.com")
        let quote = MarkdownDisplayBlock.blockQuote([MarkdownDisplayBlockNode(id: 0, block: .paragraph(linked))])
        #expect(
            LinkPreviewMetadata.previewURL(in: document([.paragraph(AttributedString("plain")), quote]))
                == URL(string: "https://nested.example.com"))
    }

    @Test func fetchParsesOnlyHTMLResponsesAgainstTheFinalURL() async throws {
        let html = Data(#"<head><meta property="og:image" content="cover.png"></head>"#.utf8)
        let finalURL = URL(string: "https://final.example.com/dir/page")!

        let parsed = await LinkPreviewLoader.fetchMetadata(for: base) { request in
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)
            return (html, Self.htmlResponse(finalURL))
        }
        #expect(
            parsed
                == .loaded(
                    LinkPreviewMetadata(title: nil, imageURL: URL(string: "https://final.example.com/dir/cover.png"))))

        let image = await LinkPreviewLoader.fetchMetadata(for: base) { _ in
            (html, Self.htmlResponse(finalURL, contentType: "image/png"))
        }
        #expect(image == .loaded(nil))

        let failed = await LinkPreviewLoader.fetchMetadata(for: base) { _ in nil }
        #expect(failed == .failed)
    }

    @Test func fetchNeverContactsUnsafeHosts() async {
        for raw in [
            "http://example.com", "https://localhost/page", "https://192.168.1.1/", "https://example.com:8443/",
        ] {
            let result = await LinkPreviewLoader.fetchMetadata(for: URL(string: raw)!) { _ in
                Issue.record("fetched \(raw)")
                return nil
            }
            #expect(result == .loaded(nil))
        }
    }

    @MainActor
    @Test func loaderCachesAnswersButRetriesFailures() async {
        let counter = FetchCounter()
        let html = Data(#"<head><title>Cached</title></head>"#.utf8)
        let url = URL(string: "https://cache.example.com/a")!
        let failing = URL(string: "https://cache.example.com/down")!
        let loader = LinkPreviewLoader { request in
            await counter.increment()
            guard request.url != failing else { return nil }
            return (html, Self.htmlResponse(request.url!))
        }

        #expect(await loader.metadata(for: url)?.title == "Cached")
        #expect(await loader.metadata(for: url)?.title == "Cached")
        #expect(loader.cachedMetadata(for: url) == .some(LinkPreviewMetadata(title: "Cached", imageURL: nil)))

        #expect(await loader.metadata(for: failing) == nil)
        #expect(loader.cachedMetadata(for: failing) == nil)
        #expect(await loader.metadata(for: failing) == nil)
        #expect(await counter.value == 3)

        loader.clearCache()
        #expect(loader.cachedMetadata(for: url) == nil)
    }

    @Test func cardHostDropsTheWWWPrefix() {
        #expect(LinkPreviewCardContent.host(for: URL(string: "https://www.example.com/a")!) == "example.com")
        #expect(LinkPreviewCardContent.host(for: URL(string: "https://news.example.com")!) == "news.example.com")
    }

    @MainActor
    @Test func previewsAreOffByDefaultAndPersistTheChoice() throws {
        let suiteName = "LinkPreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = LinkPreviewPreference(defaults: defaults)
        #expect(!initial.showsPreviews)

        initial.setShowsPreviews(true)
        #expect(LinkPreviewPreference(defaults: defaults).showsPreviews)

        initial.reset()
        #expect(!LinkPreviewPreference(defaults: defaults).showsPreviews)
    }
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
