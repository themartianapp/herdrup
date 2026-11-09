import XCTest

/// The guest shell (#312) over GuestMockTransport: accepting an invite, a home that
/// shows only the shared agent with no Gram tab, and leaving the share.
final class GuestShellTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testAcceptLandsOnGuestHome() {
        let app = XCUIApplication.launched(mock: "guestaccept")

        XCTAssertTrue(app.staticTexts["Jerry shared llm-opt with you"].waitForExistence(timeout: 10),
                      "the accept screen should say who shared which agent")
        XCTAssertTrue(app.staticTexts["plotarmordev"].exists, "the name the guest appears as should show")
        attach(app, "guest-accept")

        app.buttons["guest-accept"].tap()

        XCTAssertTrue(app.staticTexts["guest-home-title"].waitForExistence(timeout: 10),
                      "accepting should land on guest home")
        XCTAssertEqual(app.staticTexts["guest-home-title"].label, "Jerry's Mac Studio")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10),
                      "guest home should list the shared agent")
    }

    func testHomeShowsOnlyTheSharedAgentAndNoGram() {
        let app = XCUIApplication.launched(mock: "guest")

        let row = app.buttons["guest-agent-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the shared agent's row should render")
        XCTAssertTrue(row.label.contains("llm-opt"), "the row should be llm-opt, got \(row.label)")
        XCTAssertTrue(app.staticTexts["Shared by Jerry · 1 agent"].exists)
        // The mock agent.list also returns jarvis; only the shared agent may render.
        XCTAssertEqual(app.buttons.matching(identifier: "guest-agent-row").count, 1)
        XCTAssertFalse(app.staticTexts["jarvis"].exists, "an agent that was not shared must not render")

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.buttons.count, 2, "the guest tab bar should hold only Agents and Settings")
        XCTAssertTrue(tabs.buttons["Agents"].exists)
        XCTAssertTrue(tabs.buttons["Settings"].exists)
        XCTAssertFalse(tabs.buttons["Gram"].exists, "a guest has no Gram tab")
        attach(app, "guest-home")
    }

    func testLeaveRemovesTheShare() {
        let app = XCUIApplication.launched(mock: "guest")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10))

        // A tap on the tab bar right after launch can be swallowed while it settles, so
        // tap until the tab reports selected.
        let settingsTab = app.tabBars.firstMatch.buttons["Settings"]
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }
        let leave = app.buttons["guest-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "guest Settings should offer Leave share")
        XCTAssertTrue(app.staticTexts["guest-settings-fingerprint"].label.hasPrefix("SHA256:"),
                      "Settings should show this phone's key fingerprint")
        attach(app, "guest-settings")
        leave.tap()

        // The confirmation's destructive button, not the row that opened it.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Leave share' AND identifier != 'guest-leave'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "leaving should ask for confirmation")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["guest-home-title"].waitForNonExistence(timeout: 5),
                      "leaving should close guest home")
        XCTAssertTrue(app.staticTexts["Scan pairing code"].waitForExistence(timeout: 5),
                      "with no machines left the phone should be back on onboarding")
        XCTAssertFalse(app.buttons["shared-machine-row"].exists, "the share should be gone")
    }

    // MARK: Removing a share from its row (the `guestmachine` mock)

    /// Three shares on one machine: llm-opt (idle), enyo-ui (idle) and a second enyo-ui whose
    /// terminal is gone, so its row reads "Agent unavailable" though the share still exists.
    /// `HERDR_MOCK_STILL` keeps llm-opt idle: a WORKING pulse never lets the app go idle.
    private func launchMachine() -> XCUIApplication {
        let app = XCUIApplication.launched(mock: "guestmachine", environment: ["HERDR_MOCK_STILL": "1"])
        XCTAssertTrue(poll(15, every: 0.25) { rows(app).count == 3 }, "the machine should list its three shares")
        return app
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "guest-agent-row")
    }

    /// The confirmation's destructive button: neither a row's Remove share nor the menu item.
    private func confirmRemoval(_ app: XCUIApplication, of agent: String) {
        XCTAssertTrue(app.staticTexts["Remove \(agent)?"].waitForExistence(timeout: 10),
                      "removing should ask for confirmation")
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == 'Remove share' AND identifier != 'guest-remove-share'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    func testUnavailableSharedAgentIsRemovedFromItsRow() {
        let app = launchMachine()
        let unavailable = rows(app).matching(NSPredicate(format: "label CONTAINS 'Agent unavailable'"))
        XCTAssertTrue(poll(15, every: 0.25) { unavailable.count == 1 }, "the gone enyo-ui should read Agent unavailable")

        // Settings tells the two enyo-ui shares apart by their status.
        let settingsTab = app.tabBars.firstMatch.buttons["Settings"]
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }
        let shares = app.buttons.matching(identifier: "guest-share-row")
        let enyo = shares.matching(NSPredicate(format: "label CONTAINS 'enyo-ui'"))
        XCTAssertTrue(poll(10, every: 0.25) { enyo.count == 2 }, "Settings should list both enyo-ui shares")
        XCTAssertTrue(poll(10, every: 0.25) {
            enyo.matching(NSPredicate(format: "label CONTAINS 'unavailable'")).count == 1
                && enyo.matching(NSPredicate(format: "label CONTAINS 'idle'")).count == 1
        }, "each enyo-ui share should show its status, got \(enyo.allElementsBoundByIndex.map(\.label))")
        attach(app, "guest-settings-share-statuses")

        let agentsTab = app.tabBars.firstMatch.buttons["Agents"]
        for _ in 0..<3 where !agentsTab.isSelected {
            agentsTab.tap()
            _ = poll(3, every: 0.25) { agentsTab.isSelected }
        }
        let remove = app.buttons["guest-remove-share"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "an unavailable agent's row should offer Remove share")
        XCTAssertEqual(app.buttons.matching(identifier: "guest-remove-share").count, 1,
                       "only the unavailable row shows the button")
        attach(app, "guest-unavailable-row-remove")
        remove.tap()
        confirmRemoval(app, of: "enyo-ui")

        XCTAssertTrue(poll(10, every: 0.25) { rows(app).count == 2 }, "the removed share's row should go")
        XCTAssertEqual(unavailable.count, 0, "the unavailable share is the one removed")
        XCTAssertTrue(app.staticTexts["Shared by Jerry · 2 agents"].waitForExistence(timeout: 5))
    }

    func testContextMenuRemovesAShare() {
        let app = launchMachine()
        let llm = rows(app).matching(NSPredicate(format: "label CONTAINS 'llm-opt'")).firstMatch
        XCTAssertTrue(llm.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(10, every: 0.25) { llm.label.contains("idle") }, "llm-opt should have loaded, got \(llm.label)")

        llm.press(forDuration: 1.0)
        let item = app.buttons.matching(
            NSPredicate(format: "label == 'Remove share' AND identifier != 'guest-remove-share'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "long-press should offer Remove share")
        attach(app, "guest-row-context-menu")
        item.tap()
        confirmRemoval(app, of: "llm-opt")

        XCTAssertTrue(poll(10, every: 0.25) { rows(app).count == 2 }, "the removed share's row should go")
        XCTAssertFalse(llm.exists, "llm-opt is the share removed")
    }
}
