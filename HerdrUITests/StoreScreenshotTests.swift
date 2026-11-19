import XCTest

/// Captures the five App Store screens from the REAL app, at the simulator's native
/// resolution, so store artwork is regenerated from the shipping UI rather than
/// re-scaled from whatever was published last.
///
/// Not part of the normal suite's job: it asserts almost nothing and exists to produce
/// attachments. It is dispatched deliberately (`-only-testing:HerdrUITests/StoreScreenshotTests`)
/// and its output is collected from the result bundle.
///
/// Each case waits for a distinctive element of that screen before capturing, so a slow
/// launch cannot silently produce a screenshot of an empty or half-built view — which is
/// the failure mode that would quietly ship a broken store image.
final class StoreScreenshotTests: XCTestCase {
    private func capture(_ mode: String, named name: String, until: (XCUIApplication) -> Bool) {
        let app = XCUIApplication.launched(mock: mode)

        XCTAssertTrue(poll(20, every: 0.25) { until(app) }, "\(mode) never reached a capturable state")

        // Kept: the product is the image. Async rows land after the element that proves the
        // screen exists, and no single element marks "everything painted" across the five screens.
        Thread.sleep(forTimeInterval: 1.5)

        attach(XCUIScreen.main.screenshot(), name)
        app.terminate()
    }

    func testCaptureAgents() {
        capture("list", named: "store-01-agents") { $0.staticTexts["Agents"].exists }
    }

    func testCaptureTerminal() {
        capture("pane", named: "store-02-terminal") { $0.terminalSurface.exists || $0.staticTexts["Terminal"].exists }
    }

    func testCaptureGram() {
        capture("gram", named: "store-03-gram") { $0.staticTexts["Gram"].exists }
    }

    func testCaptureSettings() {
        capture("settings", named: "store-04-settings") { $0.staticTexts["Settings"].exists }
    }

    func testCaptureConnect() {
        capture("onboarding", named: "store-05-connect") { $0.buttons["Connect"].exists || $0.staticTexts["herdrup"].exists }
    }
}
