import XCTest

/// The sticky "needs you" pill (herdrup#551): it shows once the waiting rows scroll out of
/// sight, counts them, and takes you back to them. Runs on iPhone (the Agents tab) and iPad
/// (the sidebar) over the `needsyou` mock roster: `HERDR_MOCK_WAITING` agents asking, then a
/// dozen and more working ones.
final class NeedsYouPillTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(waiting: Int) -> XCUIApplication {
        XCUIApplication.launched(mock: "needsyou", environment: ["HERDR_MOCK_WAITING": "\(waiting)"])
    }

    private func needsYouPill(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "needs-you-pill").firstMatch
    }

    private func row(_ app: XCUIApplication, _ paneID: String) -> XCUIElement {
        app.descendants(matching: .any)["agent-row-\(paneID)"]
    }

    /// Scrolls the roster down until `done` holds, at most `swipes` times.
    private func scrollDown(_ app: XCUIApplication, swipes: Int = 6, until done: () -> Bool = { false }) {
        let scroll = app.scrollViews["agent-roster-scroll"]
        for _ in 0..<swipes where !done() {
            scroll.swipeUp()
        }
    }

    /// On screen. A lazy row scrolled far away is not even in the tree, which is off screen too.
    private func onScreen(_ element: XCUIElement) -> Bool { element.exists && element.isHittable }

    /// Waits for the roster with its first row on screen: the waiting rows are visible.
    private func waitForTopOfList(_ app: XCUIApplication, firstRow paneID: String) {
        XCTAssertTrue(row(app, paneID).exists(within: 10), "the roster did not load")
        XCTAssertTrue(row(app, paneID).waitForHittable(timeout: 5), "the first row is not on screen")
    }

    func testThreeWaitingShowsCountAndTapScrollsToTop() {
        let app = launch(waiting: 3)
        waitForTopOfList(app, firstRow: "w1:p1")
        let pill = needsYouPill(app)
        XCTAssertFalse(pill.exists, "no pill while the waiting rows are on screen")

        scrollDown(app) { pill.exists }
        XCTAssertTrue(pill.exists(within: 3), "the pill appears once the waiting rows scroll away")
        XCTAssertFalse(onScreen(row(app, "w1:p3")), "the last waiting row is out of sight")
        XCTAssertEqual(pill.label, "3 agents need you")
        pill.waitForSettledFrame()
        attach(app, "needs-you-pill-3")

        pill.tap()
        XCTAssertTrue(row(app, "w1:p1").waitForHittable(timeout: 5), "tap scrolls back to the waiting rows")
        XCTAssertTrue(poll(3, every: 0.1) { !pill.exists }, "the pill leaves once the waiting rows are visible")
        XCTAssertFalse(app.terminalSurface.exists, "with three waiting, tap opens no agent")
    }

    /// The case #551 exists for: agents start asking while the owner is already scrolled
    /// down, so their section is inserted above the screen and the lazy list never builds it.
    /// iPhone only: the iPad sidebar without the asking agents is barely taller than itself.
    func testAgentsThatStartWaitingWhileScrolledDownShowThePill() throws {
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            throw XCTSkip("needs a list several screens tall; the iPhone roster")
        }
        let app = XCUIApplication.launched(mock: "needsyou", environment: [
            "HERDR_MOCK_WAITING": "3", "HERDR_MOCK_WAITING_MANUAL": "1",
        ])
        waitForTopOfList(app, firstRow: "w2:p1")
        let pill = needsYouPill(app)
        scrollDown(app)
        XCTAssertFalse(onScreen(row(app, "w2:p1")), "the list is scrolled down")
        XCTAssertFalse(pill.exists, "nobody waits yet, so no pill")

        let startWaiting = app.buttons["fixture-start-waiting"]
        XCTAssertTrue(startWaiting.waitForHittable(timeout: 5))
        startWaiting.tap()

        XCTAssertTrue(pill.exists(within: 30), "the pill appears when agents start waiting off screen")
        XCTAssertEqual(pill.label, "3 agents need you")
        XCTAssertFalse(onScreen(row(app, "w1:p1")), "the waiting rows are still out of sight")

        pill.tap()
        XCTAssertTrue(row(app, "w1:p1").waitForHittable(timeout: 5), "tap scrolls back to the waiting rows")
        XCTAssertTrue(poll(3, every: 0.1) { !pill.exists }, "the pill leaves once the waiting rows are visible")
    }

    func testOneWaitingTapOpensThatAgent() {
        let app = launch(waiting: 1)
        waitForTopOfList(app, firstRow: "w1:p1")
        let pill = needsYouPill(app)
        XCTAssertFalse(pill.exists, "no pill while the waiting row is on screen")

        scrollDown(app) { pill.exists }
        XCTAssertTrue(pill.exists(within: 3), "the pill appears once the waiting row scrolls away")
        XCTAssertEqual(pill.label, "jarvis needs you")
        pill.waitForSettledFrame()
        attach(app, "needs-you-pill-1")

        pill.tap()
        XCTAssertTrue(app.terminalSurface.exists(within: 10), "tap opens the waiting agent")
        // The pane heading is "name · kind · folder": the mock's jarvis is "jarvis · claude".
        let heading = app.staticTexts.matching(NSPredicate(format: "label == %@", "jarvis · claude"))
        XCTAssertTrue(poll(5, every: 0.2) { heading.allElementsBoundByIndex.contains(where: \.isHittable) },
                      "the opened pane is jarvis")
    }

    func testNoPillWhenNobodyWaits() {
        let app = launch(waiting: 0)
        let search = app.descendants(matching: .any)["agent-search"]
        XCTAssertTrue(search.waitForHittable(timeout: 10), "the roster did not load")
        XCTAssertTrue(row(app, "w2:p1").exists(within: 10), "the roster did not load")
        scrollDown(app, swipes: 4)
        XCTAssertFalse(onScreen(search), "the list scrolled")
        XCTAssertFalse(poll(1.5, every: 0.1) { needsYouPill(app).exists }, "nobody waits: no pill")
    }
}
