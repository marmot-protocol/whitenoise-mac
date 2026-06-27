import XCTest

@MainActor
final class ChatPerformanceUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testHeavyFixtureLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            let measuredApp = fixtureApplication()
            measuredApp.launch()
            measuredApp.terminate()
        }
    }

    func testHeavyTranscriptScrollPerformance() {
        let app = launchFixture()
        let transcript = waitForTranscript(in: app)

        measure(metrics: interactionMetrics(for: app)) {
            scrollWheel(transcript, deltaY: -900)
            scrollWheel(transcript, deltaY: -900)
            scrollWheel(transcript, deltaY: -900)
            scrollWheel(transcript, deltaY: 900)
            scrollWheel(transcript, deltaY: 900)
        }
    }

    func testHeavyTranscriptLongDistancePagingScrollPerformance() {
        let app = launchFixture()
        let transcript = waitForTranscript(in: app)

        let pagingDelta = dominantVerticalScrollDelta(in: transcript)
        let resetDelta = -pagingDelta
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 3

        measure(metrics: interactionMetrics(for: app), options: options) {
            scrollWheel(transcript, deltaY: resetDelta, repetitions: 12)
            let baselinePosition = verticalScrollPosition(in: transcript)

            startMeasuring()
            scrollWheel(transcript, deltaY: pagingDelta, repetitions: 12)
            stopMeasuring()

            if let baselinePosition, let finalPosition = verticalScrollPosition(in: transcript) {
                XCTAssertGreaterThan(
                    abs(finalPosition - baselinePosition),
                    0.04,
                    "Long-distance wheel scroll did not materially move the transcript."
                )
            }
        }
    }

    func testChatSearchFilterPerformance() {
        let app = launchFixture()
        let searchField = app.textFields["chat.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))

        searchField.click()
        measure(metrics: interactionMetrics(for: app)) {
            for query in ["Launch", "Media", "Relay", "Design", "Search"] {
                replaceText(in: searchField, with: query)
            }
        }
    }

    func testVisibleMediaScrollPerformance() {
        let app = launchFixture()
        let transcript = waitForTranscript(in: app)

        let mediaTile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.media.visualTile."))
            .firstMatch
        XCTAssertTrue(mediaTile.waitForExistence(timeout: 10))

        measure(metrics: interactionMetrics(for: app)) {
            scrollWheel(transcript, deltaY: -600)
            scrollWheel(transcript, deltaY: 600)
            scrollWheel(transcript, deltaY: -600)
            scrollWheel(transcript, deltaY: 600)
        }
    }

    private func launchFixture() -> XCUIApplication {
        let launchedApp = fixtureApplication()
        launchedApp.launch()
        _ = waitForTranscript(in: launchedApp)
        app = launchedApp
        return launchedApp
    }

    private func fixtureApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiFixture", "heavy-chat"]
        app.launchEnvironment["WHITE_NOISE_UI_FIXTURE"] = "heavy-chat"
        return app
    }

    private func waitForTranscript(in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let candidate = transcriptElement(in: app)
        _ = candidate.waitForExistence(timeout: timeout)
        XCTAssertTrue(candidate.exists, "conversation.transcript did not appear")
        return candidate
    }

    private func transcriptElement(in app: XCUIApplication) -> XCUIElement {
        app.scrollViews["conversation.transcript"]
    }

    private func interactionMetrics(for app: XCUIApplication) -> [any XCTMetric] {
        [
            XCTClockMetric(),
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app),
        ]
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: [.command])
        element.typeText(text)
    }

    private func scrollWheel(_ element: XCUIElement, deltaY: CGFloat, repetitions: Int = 1) {
        for _ in 0..<repetitions {
            element.scroll(byDeltaX: 0, deltaY: deltaY)
        }
    }

    private func dominantVerticalScrollDelta(in element: XCUIElement) -> CGFloat {
        guard let start = verticalScrollPosition(in: element) else {
            return -1_200
        }

        scrollWheel(element, deltaY: -900)
        let negativePosition = verticalScrollPosition(in: element)
        scrollWheel(element, deltaY: 900)

        scrollWheel(element, deltaY: 900)
        let positivePosition = verticalScrollPosition(in: element)
        scrollWheel(element, deltaY: -900)

        let negativeDistance = negativePosition.map { abs($0 - start) } ?? 0
        let positiveDistance = positivePosition.map { abs($0 - start) } ?? 0
        return negativeDistance >= positiveDistance ? -1_200 : 1_200
    }

    private func verticalScrollPosition(in element: XCUIElement) -> Double? {
        let value = element.scrollBars.firstMatch.value

        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let string = value as? String {
            return Double(string)
        }

        return nil
    }
}
