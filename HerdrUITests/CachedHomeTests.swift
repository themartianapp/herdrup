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
        XCTAssertTrue(keptAlfa.exists(within: 4), "the kept roster did not paint before agent.list answered")
        XCTAssertTrue(element(app, "agent-row-w1:p2").exists, "every kept agent shows")
        XCTAssertTrue(app.staticTexts["kept-alfa"].exists)
        XCTAssertTrue(element(app, "agents-updating").exists, "a kept roster is marked as updating")

        // The answer lands: the same pane's row now carries the fresh name, the new agent
        // appears, the vanished one goes, and the mark clears.
        XCTAssertTrue(element(app, "agent-row-w1:p3").exists(within: 15), "the fresh roster never replaced the kept one")
        XCTAssertTrue(app.staticTexts["fresh-alfa"].exists(within: 2))
        XCTAssertFalse(app.staticTexts["kept-alfa"].exists)
        XCTAssertTrue(element(app, "agents-updating").gone(within: 3), "the Updating mark stayed")
    }

    /// The first connection fails (herdr is not running): the kept rows were never confirmed,
    /// so this is the connect failing, not a background refresh, and its guidance must show.
    /// The "Updating" mark must not stay up for good.
    ///
    /// The failure lands after 8 s, as in the test above: with 3 s, a slow cold start
    /// (the rows may take up to 4 s to paint) found the failure already in and the mark
    /// already gone, failing on two attempts in one run (herdrup #765, j_67d20ce4).
    func testAFirstConnectionFailureShowsItsGuidanceOverTheKeptRoster() {
        let app = XCUIApplication.launched(mock: "cachedhome", environment: [
            "HERDR_MOCK_LIST_DELAY": "8", "HERDR_MOCK_LIST_FAIL": "daemonUnavailable"])

        XCTAssertTrue(element(app, "agent-row-w1:p1").exists(within: 4), "the kept roster did not paint")
        XCTAssertTrue(element(app, "agents-updating").exists, "a kept roster is marked as updating")

        XCTAssertTrue(app.staticTexts["herdr isn't running on cachedhome"].exists(within: 15),
                      "the failed connection was hidden behind the kept roster")
        XCTAssertTrue(app.buttons["retry"].exists, "the guidance offers a retry")
        XCTAssertTrue(element(app, "agents-updating").gone(within: 3),
                      "the Updating mark stayed after the connection failed")
    }

    /// The kept rows stay unconfirmed until a list succeeds, so a Retry that fails another way
    /// shows that failure's guidance, not the first one's: the daemon was down, the owner
    /// started it, and it turns out too old.
    func testARetryThatFailsDifferentlyReplacesTheFirstFailuresGuidance() {
        let app = XCUIApplication.launched(mock: "cachedhome", environment: [
            "HERDR_MOCK_LIST_DELAY": "2", "HERDR_MOCK_LIST_FAIL": "daemonUnavailable,incompatible"])

        XCTAssertTrue(element(app, "agent-row-w1:p1").exists(within: 4), "the kept roster did not paint")
        let notRunning = app.staticTexts["herdr isn't running on cachedhome"]
        XCTAssertTrue(notRunning.exists(within: 10), "the first failure's guidance did not show")

        app.buttons["retry"].tap()
        XCTAssertTrue(app.staticTexts["herdr here is too old"].exists(within: 10),
                      "the Retry's failure kept the first failure's guidance")
        XCTAssertFalse(notRunning.exists)
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
        XCTAssertTrue(row.exists(within: 10), "the roster did not load")
        row.tap()

        let kept = element(app, "terminal-kept-screen")
        XCTAssertTrue(kept.exists(within: 4), "the terminal did not paint its kept screen")
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
