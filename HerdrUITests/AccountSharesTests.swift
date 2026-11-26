import XCTest

/// Guest shares on all your devices (#700, owner pick "A, reuse as is", 25 Nov), over the guest
/// mock relay (`GuestMockTransport`) and the stand-in account service (`MockAccountService`):
///
/// - g1: an invite whose host takes accounts, signed out: Continue with Apple / Google (1B) and
///   "Continue on this device only".
/// - g2: signed in: "Signed in as …", "Add to my account" and "Only this device".
/// - g3: after Add to my account, the share opens with a quiet "In your HerdrUp account" line.
/// - g4: on another device, the account's share is in SHARED WITH YOU with nothing to accept.
/// - g5: several shares stay one row per machine.
///
/// Each screen is kept as an `iphone-`/`ipad-` `shares-*` attachment.
final class AccountSharesTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func shot(_ app: XCUIApplication, _ name: String) {
        attach(app, (isPad ? "ipad-" : "iphone-") + name)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The accept screen for an invite whose host takes accounts.
    private func launchAccept(_ environment: [String: String] = [:]) -> XCUIApplication {
        let base = ["HERDR_MOCK_GUEST_ACCT": "1", "HERDR_MOCK_STILL": "1",
                    "HERDR_MOCK_ACCOUNT_FEATURES": "native_sign_in,native_sign_in_google,devices,statements,sync,delete"]
        let app = XCUIApplication.launched(mock: "guestaccept", environment: base.merging(environment) { _, new in new })
        XCTAssertTrue(app.staticTexts["guest-accept-title"].exists(within: 10), "the accept screen shows")
        return app
    }

    /// The machine list of a device signed in to an account that holds `shares` (`enyo` or
    /// `several`) accepted on another device, and no machines of its own.
    private func launchAccountList(shares: String) throws -> XCUIApplication {
        let app = XCUIApplication.forUITest()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "account"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_SIGNED_IN"] = "1"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_STORED_HINT"] = "nike@example.com"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_SHARES"] = shares
        app.launchEnvironment["HERDR_MOCK_STILL"] = "1"
        // The argument domain wins over the app-group defaults: no saved machines here.
        let empty = "<" + (try JSONSerialization.data(withJSONObject: [] as [Any])).map { String(format: "%02x", $0) }.joined() + ">"
        app.launchArguments += ["-dev.herdr.savedHosts.v1", empty]
        app.launch()
        if isPad, app.windows.firstMatch.exists(within: 10), !app.isFullScreen {
            app.restoreFullScreen()
        }
        return app
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "shared-machine-row")
    }

    // MARK: g1, g2, g3: accepting

    func testSignedOutTheInviteOffersTheAccountOrThisDeviceOnly() {
        let app = launchAccept()
        XCTAssertTrue(any(app, "account-continue-apple").exists(within: 10), "Continue with Apple, the 1B button")
        XCTAssertTrue(app.buttons["account-continue-google"].exists(within: 5), "Continue with Google, the 1B button")
        let thisDevice = app.buttons["guest-accept-this-device"]
        XCTAssertTrue(thisDevice.exists)
        XCTAssertEqual(thisDevice.label, "Continue on this device only")
        XCTAssertTrue(app.staticTexts["Keep it on all your devices"].exists)
        XCTAssertFalse(app.buttons["guest-accept-account"].exists, "Add to my account needs an account")
        XCTAssertFalse(app.buttons["guest-accept"].exists, "no plain Accept for a host that takes accounts")
        XCTAssertTrue(app.buttons["guest-accept-close"].exists, "Not now is the close circle")
        shot(app, "shares-g1-accept")

        thisDevice.tap()
        XCTAssertTrue(app.staticTexts["guest-home-title"].exists(within: 10), "the share opens")
        XCTAssertFalse(any(app, "guest-home-account-line").exists, "a share on this device only says nothing of the account")
    }

    func testSigningInOnTheInviteOffersAddToMyAccount() {
        let app = launchAccept()
        let google = app.buttons["account-continue-google"]
        XCTAssertTrue(google.waitForHittable(timeout: 10))
        google.tap()

        let signedIn = any(app, "guest-accept-signed-in")
        XCTAssertTrue(signedIn.exists(within: 15), "signed in, the foot says who")
        XCTAssertTrue(signedIn.label.contains("jerry@example.com"), "got \(signedIn.label)")
        let add = app.buttons["guest-accept-account"]
        XCTAssertTrue(add.exists)
        XCTAssertTrue(poll(15, every: 0.3) { add.isEnabled }, "Add to my account once the first sync is done")
        XCTAssertFalse(app.buttons["account-continue-google"].exists, "the sign-in buttons are gone")
    }

    func testSignedInAddToMyAccountOpensTheShareInTheAccount() {
        let app = launchAccept(["HERDR_MOCK_ACCOUNT_SIGNED_IN": "1", "HERDR_MOCK_ACCOUNT_STORED_HINT": "nike@example.com"])
        let signedIn = any(app, "guest-accept-signed-in")
        XCTAssertTrue(signedIn.exists(within: 10))
        XCTAssertTrue(signedIn.label.contains("Signed in as") && signedIn.label.contains("nike@example.com"),
                      "got \(signedIn.label)")
        let add = app.buttons["guest-accept-account"]
        XCTAssertEqual(add.label, "Add to my account")
        XCTAssertEqual(app.buttons["guest-accept-this-device"].label, "Only this device")
        XCTAssertFalse(any(app, "account-continue-apple").exists, "no sign-in buttons once signed in")
        shot(app, "shares-g2-accept-signed-in")

        XCTAssertTrue(poll(10, every: 0.3) { add.isEnabled })
        add.tap()
        XCTAssertTrue(app.staticTexts["guest-home-title"].exists(within: 10), "the share opens")
        let line = any(app, "guest-home-account-line")
        XCTAssertTrue(line.exists(within: 5), "the share says it is in the account")
        XCTAssertTrue(line.label.contains("nike@example.com"), "got \(line.label)")
        shot(app, "shares-g3-in-account")
    }

    // MARK: g4, g5: the account's shares on another device

    func testAnAccountShareOpensWithNothingToAccept() throws {
        let app = try launchAccountList(shares: "enyo")
        let row = rows(app).firstMatch
        XCTAssertTrue(row.exists(within: 20), "the account's share is listed after the first sync")
        XCTAssertTrue(row.label.contains("hetzner") && row.label.contains("enyo · shared by jerry"), "got \(row.label)")
        let note = any(app, "shared-from-account-note")
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("nothing to accept") && note.label.contains("jerry sees each device"),
                      "got \(note.label)")
        shot(app, "shares-g4-from-account")

        row.tap()
        let title = app.staticTexts["guest-home-title"]
        XCTAssertTrue(title.exists(within: 10), "the share opens with no invite")
        XCTAssertEqual(title.label, "hetzner")
        XCTAssertTrue(app.buttons["guest-agent-row"].exists(within: 10), "its agent is listed")
        XCTAssertTrue(any(app, "guest-home-account-line").exists)
    }

    func testSeveralSharesStayOneRowPerMachine() throws {
        let app = try launchAccountList(shares: "several")
        XCTAssertTrue(poll(20, every: 0.3) { self.rows(app).count == 2 }, "two machines, two rows")
        let labels = rows(app).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("hetzner") && $0.contains("enyo, orgstudio · shared by jerry") }, "got \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("atlas-mini") && $0.contains("landing · shared by maya") }, "got \(labels)")
        XCTAssertTrue(any(app, "shared-from-account-note").label.contains("The owner sees each device"),
                      "two owners: the note names neither")
        shot(app, "shares-g5-rows")

        rows(app).matching(NSPredicate(format: "label CONTAINS 'hetzner'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Shared by jerry · 2 agents"].exists(within: 10), "both agents open on hetzner")
        shot(app, "shares-g5-machine")
    }

    func testLeavingAnAccountShareTakesItOutOfTheAccount() throws {
        let app = try launchAccountList(shares: "enyo")
        let row = rows(app).firstMatch
        XCTAssertTrue(row.exists(within: 20))
        row.tap()
        XCTAssertTrue(app.buttons["guest-agent-row"].exists(within: 10))

        // A tap on the tab bar right after launch can be swallowed while it settles.
        // On iPad the tabs may sit outside a tab bar element.
        let inTabBar = app.tabBars.firstMatch.buttons["Settings"]
        let settingsTab = inTabBar.exists ? inTabBar : app.buttons["Settings"].firstMatch
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }
        let card = app.buttons["guest-settings-agent-card"]
        XCTAssertTrue(card.exists(within: 10))
        card.tap()
        let leave = app.buttons["guest-leave"]
        for _ in 0..<4 where leave.exists && !leave.isHittable { app.swipeUp() }
        XCTAssertTrue(leave.exists(within: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'on all your devices'")).firstMatch.exists,
                      "leaving says it leaves every device")
        leave.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Leave share' AND identifier != 'guest-leave'")).firstMatch
        XCTAssertTrue(confirm.exists(within: 5))
        confirm.tap()

        XCTAssertTrue(app.staticTexts["guest-home-title"].gone(within: 5), "leaving closes the share")
        // Had the account kept it, the next sync would list it again with nothing to accept.
        XCTAssertFalse(poll(6, every: 0.5) { self.rows(app).count > 0 }, "the share left the account too")
    }
}
