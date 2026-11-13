import XCTest

/// Slow-network fix 4: on a cold start the Agents home shows the agents kept from the last
/// launch before the network answers, marked "Updating", then swaps in the fresh roster.
/// The `cachedhome` mock holds `agent.list` for `HERDR_MOCK_LIST_DELAY` seconds.
final class CachedHomeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    func testKeptAgentsShowBeforeTheNetworkAnswersThenTheFreshOnesReplaceThem() {
        let app = XCUIApplication.launched(mock: "cachedhome", environment: ["HERDR_MOCK_LIST_DELAY": "8"])

        // Well inside the 8 s the daemon takes: these rows can only have come from the cache.
        let keptAlfa = element(app, "agent-row-w1:p1")
        XCTAssertTrue(keptAlfa.waitForExistence(timeout: 4), "the kept roster did not paint before agent.list answered")
        XCTAssertTrue(element(app, "agent-row-w1:p2").exists, "every kept agent shows")
        XCTAssertTrue(app.staticTexts["kept-alfa"].exists)
        XCTAssertTrue(element(app, "agents-updating").exists, "a kept roster is marked as updating")

        // The answer lands: the same pane's row now carries the fresh name, the new agent
        // appears, the vanished one goes, and the mark clears.
        XCTAssertTrue(element(app, "agent-row-w1:p3").waitForExistence(timeout: 15), "the fresh roster never replaced the kept one")
        XCTAssertTrue(app.staticTexts["fresh-alfa"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["kept-alfa"].exists)
        XCTAssertTrue(poll(3, every: 0.2) { !self.element(app, "agents-updating").exists }, "the Updating mark stayed")
    }

    /// The terminal's kept screen must be SEEN, not merely present: Desktop's equivalent
    /// existed under the terminal's opaque layer and users got a blank terminal. Hittable is
    /// the proof: XCUITest's hit test finds the topmost element at the point, so a kept screen
    /// drawn under the terminal is not hittable. The stream (and the backfill read) start 8 s
    /// late, so for that long only the cache can have drawn anything.
    func testTheTerminalShowsItsKeptScreenOnTopUntilTheLiveFrameLands() {
        let app = XCUIApplication.launched(mock: "cachedhome", environment: [
            "HERDR_MOCK_LIST_DELAY": "0", "HERDR_MOCK_STREAM_DELAY": "8", "HERDR_STEADY_CARET": "1"])
        let row = element(app, "agent-row-w1:p3")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the roster did not load")
        row.tap()

        let kept = element(app, "terminal-kept-screen")
        XCTAssertTrue(kept.waitForExistence(timeout: 4), "the terminal did not paint its kept screen")
        XCTAssertTrue(kept.isHittable, "the kept screen exists but something is drawn over it")
        XCTAssertTrue((kept.value as? String)?.contains("KEPT-SCREEN-FROM-LAST-LAUNCH") == true,
                      "the kept screen does not hold last launch's text")
        let frame = kept.frame
        XCTAssertGreaterThan(frame.height, 20)
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(frame), "the kept screen is off screen")

        // The stream's first keyframe paints the live screen and takes the kept one away.
        XCTAssertTrue(poll(20, every: 0.25) { !kept.exists }, "the kept screen stayed over the live terminal")
        XCTAssertTrue(app.terminalSurface.exists)
    }
}
