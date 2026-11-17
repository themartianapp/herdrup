import XCTest

/// The home list's live status stream (herdr events v2), over a mock daemon that
/// counts the `agent.list` and `events.subscribe` requests it serves.
///
/// - A streamed status event must move a row by itself: the list count may not move.
/// - A `lagged` line must reload the list, which is the only way the change the
///   stream missed can appear.
/// - A daemon without `events_v2` must keep the 5 s poll and never subscribe.
final class LiveEventsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testStatusEventUpdatesTheRowWithoutReloadingTheList() {
        let app = XCUIApplication.launched(mock: "liveevents")
        let remote = row(app, "build/w1:p2")
        XCTAssertTrue(remote.exists(within: 15), "the federated row should be listed")
        XCTAssertEqual(remote.value as? String, "working")
        let before = waitForSettledSubscription(app)

        app.buttons["live-emit-status"].tap()
        XCTAssertTrue(poll(3, every: 0.25) { remote.value as? String == "needs you" },
                      "the streamed status should move the remote row into needs you")
        XCTAssertEqual(counters(app).list, before, "the row must change from the event, not a reload")

        // Kept: a negative check, past a 5 s poll tick and well short of the 30 s backstop:
        // an open stream replaces the poll.
        Thread.sleep(forTimeInterval: 7)
        XCTAssertEqual(counters(app).list, before, "no 5 s poll while the stream is open")
        XCTAssertEqual(counters(app).subscribe, 1, "one subscription is held, not reopened")
    }

    func testLaggedLineReloadsTheListAndADroppedStreamReconnects() {
        let app = XCUIApplication.launched(mock: "liveevents")
        let lead = row(app, "w1:p1")
        XCTAssertTrue(lead.exists(within: 15), "the local row should be listed")
        XCTAssertEqual(lead.value as? String, "working")
        let before = waitForSettledSubscription(app)

        app.buttons["live-emit-lagged"].tap()
        XCTAssertTrue(poll(4, every: 0.25) { lead.value as? String == "needs you" },
                      "after lagged, the reload must show the change the stream dropped")
        XCTAssertGreaterThan(counters(app).list, before, "lagged must reload agent.list")

        let reloaded = counters(app).list
        app.buttons["live-drop-stream"].tap()
        XCTAssertTrue(poll(8, every: 0.25) { counters(app).subscribe == 2 },
                      "a dropped stream should reconnect after its backoff")
        XCTAssertTrue(poll(4, every: 0.25) { counters(app).list > reloaded },
                      "a reconnect resynchronizes from agent.list")
    }

    func testOlderDaemonKeepsTheFiveSecondPoll() {
        let app = XCUIApplication.launched(mock: "liveevents-legacy")
        let remote = row(app, "build/w1:p2")
        XCTAssertTrue(remote.exists(within: 15), "the federated row should be listed")
        XCTAssertTrue(poll(5, every: 0.25) { counters(app).list >= 1 })
        let before = counters(app).list

        // The daemon's state changes; with no stream, only the poll can show it.
        app.buttons["live-emit-status"].tap()
        XCTAssertTrue(poll(8, every: 0.25) { remote.value as? String == "needs you" },
                      "the 5 s poll should pick up the change")
        XCTAssertTrue(poll(13, every: 0.25) { counters(app).list >= before + 2 },
                      "an old daemon is polled every 5 s")
        XCTAssertEqual(counters(app).subscribe, 0, "no events_v2, no subscription")
    }

    // MARK: - Helpers

    private func row(_ app: XCUIApplication, _ pane: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-row-\(pane)").firstMatch
    }

    /// Waits for the subscription and the reload its acknowledgement triggers, then
    /// returns the settled `agent.list` count.
    private func waitForSettledSubscription(_ app: XCUIApplication) -> Int {
        XCTAssertTrue(poll(10, every: 0.25) { counters(app).subscribe == 1 && counters(app).list >= 2 },
                      "the capability should open one subscription and resynchronize")
        // Kept: a quiet window so a reload still in flight lands before the count is taken,
        // and is not later mistaken for a poll or an event-driven reload.
        Thread.sleep(forTimeInterval: 1)
        return counters(app).list
    }

    private func counters(_ app: XCUIApplication) -> (list: Int, subscribe: Int) {
        let label = app.staticTexts["live-events-counters"].label
        var values: [String: Int] = [:]
        for pair in label.split(separator: " ") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let value = Int(parts[1]) { values[String(parts[0])] = value }
        }
        return (values["list"] ?? -1, values["subscribe"] ?? -1)
    }
}
