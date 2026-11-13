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
}
