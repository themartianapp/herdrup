import XCTest

/// The SWIPE-REMOVAL receipt (JARVIS standing rule 47814/47874: a gesture change ships with an
/// on-simulator gesture proof, not static review alone).
///
/// The horizontal swipe-between-agents gesture was REMOVED: a finger/mouse drag meant to SELECT
/// terminal text was triggering it and paging to an unwanted agent. This test is the inverted
/// receipt — it proves the removal held: a fast horizontal flick on the terminal body no longer
/// changes the front pane. (Agent switching now lives entirely in the list/sidebar.)
///
/// Launches the keep-mounted paging harness (`HERDR_SCREENSHOT_MOCK=paging`) — three
/// distinctively-named agents (ALFA / BRAVO / CHARLIE) in the real `PaneKeepAliveContainer`.
/// Only the FRONT pane is hittable (`.accessibilityHidden(!isFront)` + opacity/hit-testing off on
/// the rest), so an existence+hittable assertion genuinely proves which pane is on screen. If a
/// swipe still paged, BRAVO would become the hittable front → this fails. So a PASS proves the
/// swipe recognizers are gone and a horizontal flick leaves the agent unchanged.
final class PagingTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testSwipeDoesNotPageAgents() {
        let app = XCUIApplication.launched(mock: "paging")

        // Opens on ALFA (heading collapses to "ALFA" — name==kind==folder) — front, hittable.
        // `frontIs` polls until the first pane has mounted and fronted, so no fixed settle.
        XCTAssertTrue(frontIs(app, "ALFA"),
            "Paging harness did not open on the first agent (ALFA).")
        attach(app, "01-alfa")

        // A firm leftward flick used to page to BRAVO. With the swipe recognizers removed it must
        // be inert: BRAVO never fronts and ALFA stays the hittable front pane.
        swipe(app, .left)
        XCTAssertFalse(frontIs(app, "BRAVO", timeout: 2),
            "A horizontal swipe paged to BRAVO — the swipe-between-agents gesture should be removed.")
        XCTAssertTrue(frontIs(app, "ALFA"),
            "ALFA is no longer the front pane after a horizontal swipe — the swipe must leave the agent unchanged.")
        attach(app, "02-still-alfa")

        // The other direction is equally inert.
        swipe(app, .right)
        XCTAssertTrue(frontIs(app, "ALFA"),
            "A rightward swipe changed the front pane — it must be inert after the gesture removal.")
        attach(app, "03-still-alfa")
    }

    // MARK: helpers

    /// True when the named agent's header heading belongs to the FRONT pane — present AND
    /// HITTABLE. A backgrounded keep-mounted pane sits at opacity 0 with hit-testing off, so its
    /// header is not hittable; only the fronted pane's header is. This distinguishes "on screen"
    /// from "merely still mounted", without relying on accessibility hiding.
    private func frontIs(_ app: XCUIApplication, _ name: String, timeout: TimeInterval = 6) -> Bool {
        let el = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        return poll(timeout, every: 0.2) { el.exists && el.isHittable }
    }

    private enum Dir { case left, right }

    /// A firm, FAST horizontal flick on the terminal body at mid-height — the same gesture that
    /// used to page agents. Both directions start well clear of the left screen edge (dx ≥ 0.45 ≫
    /// the ~44pt edge-back zone), so the flick reaches the terminal rather than the system back
    /// gesture. It must now leave the front pane unchanged.
    private func swipe(_ app: XCUIApplication, _ dir: Dir) {
        let startX: CGFloat = dir == .left ? 0.85 : 0.45
        let endX:   CGFloat = dir == .left ? 0.15 : 0.95
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
        start.press(forDuration: 0.0, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.0)
        // Kept: a negative check — the flick must have had time to page (if it still could)
        // before the caller asserts the front pane is unchanged.
        Thread.sleep(forTimeInterval: 1.2)
    }
}
