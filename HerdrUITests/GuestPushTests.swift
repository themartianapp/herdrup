import XCTest

/// Guest push registration and the guest's Notifications control (herdrup#343), over
/// GuestMockTransport. `HERDR_MOCK_PUSH_AUTH` is iOS's notification permission before any
/// question (`granted`, `denied`, or undecided by default); the pane's DEBUG probe
/// `guest-host-calls` lists what the mock host answered, so it shows every registration.
final class GuestPushTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private let registration = "notifications.register_device:device_token=mock-apns-token-guest,platform=apns,"
        + "notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=true"

    /// The guest home over the mock host, which shares Gram and takes guest push.
    /// `HERDR_MOCK_STILL` keeps the agent idle so XCUITest actions don't wait on a pulse.
    private func launch(authorization: String?) -> XCUIApplication {
        var environment = ["HERDR_MOCK_STILL": "1", "HERDR_MOCK_GUEST_FEATURES": "gram,push"]
        if let authorization { environment["HERDR_MOCK_PUSH_AUTH"] = authorization }
        return .launched(mock: "guest", environment: environment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.firstMatch.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the guest tab bar should offer \(name)")
        tab.tap()
    }

    /// Settings › Shared with you, where the share's Notifications control lives (behind the
    /// share's card on the Settings index).
    private func openSharedWithYou(_ app: XCUIApplication) {
        openTab(app, "Settings")
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "guest Settings should lead with the share's card")
        card.tap()
        XCTAssertTrue(element(app, "guest-push-status").waitForExistence(timeout: 10))
    }

    private func openAgent(_ app: XCUIApplication) {
        openTab(app, "Agents")
        let row = app.buttons["guest-agent-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "guest-terminal").waitForExistence(timeout: 10))
    }

    /// A phone iOS already lets notify registers as soon as it connects, without a question,
    /// and the guest's Settings say On. The home and the agent screen share one connection,
    /// which registers once.
    func testGrantedPermissionRegistersWithoutAskingAndShowsOn() {
        let app = launch(authorization: "granted")
        openSharedWithYou(app)
        pollLabel(app, "guest-push-status", "a granted phone's notifications should be on") { $0 == "On" }
        XCTAssertEqual(app.buttons["guest-push-action"].label, "Turn off")
        attach(app, "guest-push-settings-on")

        openAgent(app)
        let calls = pollLabel(app, "guest-host-calls", "the host should hold this phone's registration") {
            $0.contains(self.registration)
        }
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "nothing to ask when iOS already allows")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(element(app, "guest-host-calls").label.components(separatedBy: "notifications.register_device").count - 1,
                       1, "one connection registers once: \(calls)")
    }

    /// "Not now" on the explanation is undone from Settings: Turn on registers.
    func testNotNowCanBeUndoneFromSettings() {
        let app = launch(authorization: nil)
        openAgent(app)
        let notNow = app.buttons["guest-push-not-now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10), "an undecided phone gets the explanation")
        notNow.tap()
        XCTAssertTrue(element(app, "guest-push-prompt").waitForNonExistence(timeout: 5))
        app.buttons["guest-back"].tap()

        openSharedWithYou(app)
        pollLabel(app, "guest-push-status", "Not now leaves notifications off") { $0 == "Off" }
        let action = app.buttons["guest-push-action"]
        XCTAssertEqual(action.label, "Turn on")
        action.tap()
        pollLabel(app, "guest-push-status", "Turn on should turn them on") { $0 == "On" }

        openAgent(app)
        pollLabel(app, "guest-host-calls", "Turn on should register this phone") { $0.contains(self.registration) }
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "no second explanation once on")
    }

    /// iOS refuses: nothing registers or asks, and Settings points to iOS Settings.
    func testDeniedPermissionPointsToSettingsAndNeverRegisters() {
        let app = launch(authorization: "denied")
        openSharedWithYou(app)
        pollLabel(app, "guest-push-status", "a refused phone says so") { $0 == "Off in iOS Settings" }
        XCTAssertEqual(app.buttons["guest-push-action"].label, "Open Settings")

        openAgent(app)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "iOS won't ask again, so neither does the app")
        XCTAssertFalse(element(app, "guest-host-calls").label.contains("notifications.register_device"))
    }

    /// The agent page's ⋯ turns this share's push off and on (GuestPushCenter, as Guest
    /// Settings does): off unregisters the phone and the ⋯ shows the owner's struck bell, on
    /// registers it again and the ⋯ is back. Only push calls a guest may make.
    func testActionsMenuTurnsThisSharesNotificationsOffAndOn() {
        let app = launch(authorization: "granted")
        openAgent(app)
        pollLabel(app, "guest-host-calls", "a granted phone registers on connect") { $0.contains(self.registration) }
        let actions = app.buttons["guest-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.value as? String, "Notifications on", "push on: the ⋯ shows no struck bell")

        actions.tap()
        let toggle = app.buttons["guest-notifications"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the ⋯ should offer this share's notifications")
        XCTAssertEqual(toggle.label, "Turn off notifications")
        toggle.tap()
        pollLabel(app, "guest-host-calls", "Turn off should unregister this phone") {
            $0.contains("notifications.unregister_device:mock-apns-token-guest")
        }
        XCTAssertTrue(poll(5, every: 0.25) { actions.value as? String == "Notifications off" },
                      "push off: the ⋯ shows the struck bell, not \(String(describing: actions.value))")
        attach(app, "guest-notifications-off")

        actions.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Turn on notifications")
        toggle.tap()
        pollLabel(app, "guest-host-calls", "Turn on should register this phone again") {
            $0.components(separatedBy: self.registration).count - 1 == 2
        }
        XCTAssertTrue(poll(5, every: 0.25) { actions.value as? String == "Notifications on" },
                      "push on again: the ⋯ is back, not \(String(describing: actions.value))")
        XCTAssertEqual(element(app, "guest-forbidden-calls").label, "")
    }
}
