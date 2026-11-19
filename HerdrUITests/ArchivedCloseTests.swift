import XCTest

/// #380: Close on an archived agent. Offered only when the daemon advertises
/// `agent_forget` (herdr#291), and always behind a confirmation. The demo roster has one
/// archived agent, "huurjacht".
final class ArchivedCloseTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func openArchivedMenu(mock: String) -> XCUIApplication {
        let app = XCUIApplication.launched(mock: mock, environment: [
            // Every tap also redraws the home, as a roster poll landing mid-tap does on a slow
            // runner: an open menu rebuilt by that redraw used to drop the tap on Close.
            "HERDR_REDRAW_ON_TOUCH": "1",
        ])
        let archived = app.buttons["Archived, 1"]
        XCTAssertTrue(archived.exists(within: 12), "the Archived row should be listed")
        archived.tap()
        let row = app.staticTexts["huurjacht"]
        XCTAssertTrue(row.exists(within: 6), "opening Archived should show its agent")
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Unarchive"].exists(within: 6), "the row's menu should open")
        return app
    }

    func testCloseAsksBeforeRemovingAnArchivedAgent() {
        let app = openArchivedMenu(mock: "archivedClose")
        let close = app.buttons["Close"]
        XCTAssertTrue(close.exists, "a daemon with agent.forget should offer Close")
        close.tap()

        XCTAssertTrue(app.staticTexts["Close huurjacht?"].exists(within: 6),
                      "Close should ask for confirmation, naming the agent")
        XCTAssertTrue(app.staticTexts["It leaves the Archived list. Its transcript stays on the machine."].exists)
        // iOS 26 action sheets have no visible Cancel button: tapping outside dismisses.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.staticTexts["Close huurjacht?"].gone(within: 6),
                      "tapping outside should dismiss the confirmation")
        XCTAssertTrue(app.staticTexts["huurjacht"].exists, "cancelling must leave the archived agent listed")
    }

    func testOlderDaemonOffersNoClose() {
        let app = openArchivedMenu(mock: "list")
        XCTAssertFalse(app.buttons["Close"].exists, "a daemon without agent.forget must not offer Close")
    }
}
