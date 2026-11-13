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
        // Leave lives on Shared with you, behind the share's card.
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "guest Settings should lead with the share's card")
        card.tap()
        let leave = app.buttons["guest-leave"]
        for _ in 0..<4 where leave.exists && !leave.isHittable { app.swipeUp() }
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "Shared with you should offer Leave share")
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

    // MARK: Settings (the real index minus what needs a machine of your own)

    /// A guest-only phone's Settings is the app's own: the share's card where the machine card
    /// sits, Your own machine, Preferences, Help and About, and nothing that needs a machine.
    func testSettingsIsTheRealIndexWithoutOwnMachineSections() {
        let app = openGuestSettings()
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the share's card should lead Settings")
        XCTAssertTrue(card.label.contains("llm-opt") && card.label.contains("Jerry"),
                      "the card should name the agent and who shared it, got \(card.label)")
        for label in ["YOUR OWN MACHINE", "PREFERENCES", "HELP"] {
            XCTAssertTrue(app.staticTexts[label].exists, "Settings should show \(label)")
        }
        XCTAssertTrue(app.buttons["guest-settings-connect-own-machine"].exists)
        XCTAssertTrue(app.buttons["settings-omp-opens-in"].exists || app.staticTexts["omp agents open in"].exists,
                      "Preferences should keep its rows")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Report a bug'")).firstMatch.exists,
                      "Help should keep Report a bug")
        attach(app, "guest-settings-index")

        for hidden in ["settings-machine-card", "settings-suggestion-update", "settings-suggestion-exhausted"] {
            XCTAssertFalse(app.buttons[hidden].exists, "a guest's Settings must not show \(hidden)")
        }
        for hidden in ["YOUR HERD", "Accounts", "Shared access", "Notifications", "Typing latency"] {
            XCTAssertFalse(app.staticTexts[hidden].exists, "a guest's Settings must not show \(hidden)")
        }
        XCTAssertFalse(app.buttons["guest-leave"].exists, "Leave sits behind the share's card")

        let usage = app.buttons["settings-usage-count"]
        for _ in 0..<5 where !usage.exists || !usage.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["ABOUT"].exists, "Settings should end with About")
        XCTAssertTrue(usage.exists, "About should keep the usage-count switch")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Privacy Policy'")).firstMatch.exists)
        attach(app, "guest-settings-about")
    }

    /// The share's card opens Shared with you: the share, this phone's key and Leave.
    func testShareCardOpensSharedWithYou() {
        let app = openGuestSettings()
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["Shared by Jerry"].waitForExistence(timeout: 10),
                      "Shared with you should say who shared the agent")
        XCTAssertTrue(app.staticTexts["guest-settings-fingerprint"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["guest-settings-fingerprint"].label.hasPrefix("SHA256:"))
        XCTAssertTrue(app.staticTexts["You appear as"].exists)
        XCTAssertTrue(app.buttons["guest-leave"].exists, "Shared with you should offer Leave share")
        attach(app, "guest-settings-shared-with-you")

        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Back should return to the Settings index")
    }

    /// Connect your own machine closes the share onto the machine list with its own-machine
    /// setup open, whose Scan reaches pairing (and its Paste).
    func testConnectYourOwnMachineReachesPairing() {
        let app = openGuestSettings()
        let connect = app.buttons["guest-settings-connect-own-machine"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()

        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10),
                      "Connect your own machine should open the machine list's pairing setup")
        XCTAssertTrue(app.buttons["shared-machine-row"].exists, "the share should stay in the list")
        attach(app, "guest-settings-connect-own-machine")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan to connect"].waitForExistence(timeout: 10),
                      "Scan pairing code should open the pairing sheet")
        XCTAssertTrue(app.buttons["pairing-paste-button"].waitForExistence(timeout: 5)
                      || app.buttons["Paste"].firstMatch.exists, "pairing should offer Paste")
    }

    /// Several shares on one machine open their Settings in a sheet over the share list;
    /// Connect your own machine closes it and reaches pairing (#666), which RootView presents
    /// under the sheet.
    func testConnectYourOwnMachineReachesPairingFromTheMultiShareSheet() {
        let app = launchMachine()
        let settingsTab = app.tabBars.firstMatch.buttons["Settings"]
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }
        let share = app.buttons.matching(identifier: "guest-share-row").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Settings should list the machine's shares")
        share.tap()
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "a share's Settings should open in its sheet")
        let connect = app.buttons["guest-settings-connect-own-machine"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        attach(app, "guest-settings-multi-share-sheet")
        connect.tap()

        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10),
                      "Connect your own machine should close the sheet onto the machine list's pairing setup")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan to connect"].waitForExistence(timeout: 10),
                      "Scan pairing code should open the pairing sheet")
    }

    /// Guest home's Settings tab. The iPad draws its tab bar at the top, where the item may
    /// not sit under a tab bar element, so fall back to the button by its label.
    private func openGuestSettings() -> XCUIApplication {
        let app = XCUIApplication.launched(mock: "guest")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10))
        let inTabBar = app.tabBars.firstMatch.buttons["Settings"]
        let settingsTab = inTabBar.exists ? inTabBar : app.buttons["Settings"].firstMatch
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }
        return app
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
