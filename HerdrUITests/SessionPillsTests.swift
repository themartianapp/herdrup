import XCTest

/// #347: the Agents home on a machine with several herdr sessions. The `sessions` mock
/// lists work, personal and default as running and scratch as stopped, and the home is
/// on "work"; every session answers with the demo roster (3 agents need you).
final class SessionPillsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testRunningSessionsShowAsPillsWithTheCurrentOneSelected() {
        let app = XCUIApplication.launched(mock: "sessions")

        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].exists(within: 12),
                      "the roster should have loaded")

        // Labels are what VoiceOver reads: name, then the needs-you count.
        let work = app.buttons["work, 3 need you"]
        XCTAssertTrue(work.exists(within: 6), "the current session should have a pill")
        XCTAssertTrue(work.isSelected, "the session the app is on should read as selected")

        let personal = app.buttons["personal, 3 need you"]
        XCTAssertTrue(personal.exists(within: 6), "another running session should have a pill")
        XCTAssertFalse(personal.isSelected)
        XCTAssertTrue(app.buttons["default, 3 need you"].exists, "the default session should have a pill")

        // A stopped session can't be switched to, so it gets no pill.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'scratch'")).firstMatch.exists,
                       "a stopped session must not be offered")
    }

    /// #386: switching shows the new session's agents from what the app already saw (the
    /// pills check every session), instead of an empty screen until its own list loads.
    /// In this mock the switched-to session takes 4 s to answer its own `agent.list`.
    func testSwitchingShowsTheNewSessionsAgentsWithoutWaitingForItsLoad() {
        let app = XCUIApplication.launched(mock: "sessions")

        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].exists(within: 12),
                      "the roster should have loaded")
        let personal = app.buttons["personal, 3 need you"]
        XCTAssertTrue(personal.exists(within: 6), "the pills should have checked the other sessions")

        personal.tap()

        XCTAssertTrue(app.buttons["personal, 3 need you"].exists(within: 1.5),
                      "the pills should stay up through the switch")
        XCTAssertTrue(app.buttons["personal, 3 need you"].isSelected, "the tapped session should be the current one")
        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].exists(within: 1.5),
                      "the new session's agents should show at once, not after its 4 s load")
    }
}
