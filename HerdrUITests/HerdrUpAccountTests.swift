import XCTest

/// The HerdrUp account (#698, accounts step 5) over the app's stand-in account service
/// (`HERDR_SCREENSHOT_MOCK=account`, App/AccountMock.swift): the first-launch sign-in (1B),
/// sign-in → this device enrolled → the account's machines merged into the list by the host
/// identity rule, Settings › HerdrUp account, sign-out and deletion. The real `AccountClient`,
/// `AccountSession`, `DeviceEnroller`, `SyncEngine` and the app's merge run against it; only
/// Apple's sheet and Google's page are stood in for.
///
/// The mock account holds "Mac Studio" (jerry@mac-studio.local), "fleet-hel1" (jerry@fleet-hel1),
/// a fork of fleet-hel1 with a higher rev ("fleet (old phone)", which the merge tombstones) and a
/// second device, "Jerry's MacBook".
final class HerdrUpAccountTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Onboarding 1B

    func testOnboardingOffersAppleAndNoGoogleWhenTheServiceDoesNotListIt() throws {
        let app = try launch(features: "native_sign_in,devices,statements,sync,delete")
        XCTAssertTrue(app.otherElements["account-onboarding"].exists(within: 10), "a new device opens on 1B")
        XCTAssertTrue(appleButton(app).exists(within: 8), "Continue with Apple shows when the service takes native sign-in")
        XCTAssertTrue(app.buttons["account-skip"].exists, "Set up without an account is always offered")
        XCTAssertFalse(app.buttons["account-continue-google"].exists,
                       "Google needs native_sign_in_google in /v1/health")
        attach(app, "account-1b-apple-only")
    }

    func testOnboardingOffersGoogleWhenTheServiceListsIt() throws {
        let app = try launch(features: "native_sign_in,native_sign_in_google,devices,statements,sync,delete")
        XCTAssertTrue(appleButton(app).exists(within: 10))
        XCTAssertTrue(app.buttons["account-continue-google"].exists(within: 3),
                      "Continue with Google shows once the service lists native_sign_in_google")
        XCTAssertTrue(app.buttons["account-skip"].exists)
        attach(app, "account-1b-apple-google")
    }

    func testSettingUpWithoutAnAccountKeepsTodaysMachineList() throws {
        let app = try launch()
        let skip = app.buttons["account-skip"]
        XCTAssertTrue(skip.waitForHittable(timeout: 10))
        skip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pairing-prerequisite-tailscale"].exists(within: 8),
                      "skipping lands on the same first screen as before accounts")
        XCTAssertTrue(app.buttons["Copy command: curl -fsSL https://herdrup.app/install.sh | sh"].exists(within: 3))
        XCTAssertTrue(app.buttons["Copy command: herdr pair"].exists)
        XCTAssertFalse(app.otherElements["account-onboarding"].exists, "1B is answered and stays gone")
    }

    func testSigningInEnrolsThisDeviceAndBringsTheAccountsMachines() throws {
        let app = try launch()
        let apple = appleButton(app)
        XCTAssertTrue(apple.waitForHittable(timeout: 10))
        apple.tap()

        XCTAssertTrue(machine(app, "jerry@mac-studio.local").exists(within: 15),
                      "the account's machines land in the list after the first sync")
        XCTAssertTrue(machine(app, "jerry@fleet-hel1").exists(within: 3))
        XCTAssertEqual(machines(app, containing: "fleet-hel1").count, 1,
                       "two account items for one machine keep the lower rev; the fork is not a second row")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'old phone'")).firstMatch.exists)
        attach(app, "account-signed-in-list")

        openAccountPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["account-device-current"].exists(within: 8),
                      "this device is enrolled and listed as the current one")
        XCTAssertTrue(app.staticTexts["Jerry's MacBook"].exists(within: 3), "the account's other device is listed")
        pollLabel(app, "account-synced-machines", "the account holds the two machines") { $0.contains("2") }
    }

    func testALocalDuplicateIsMergedIntoTheAccountsMachine() throws {
        // The same machine saved here under another name, address case and id, plus a machine
        // the account doesn't know.
        let app = try launch(hosts: [
            ["id": UUID().uuidString, "host": "Mac-Studio.local", "username": "jerry", "nickname": "studio", "authKind": "key"],
            ["id": UUID().uuidString, "host": "10.0.4.12", "username": "ci", "nickname": "build-box", "authKind": "key"],
        ])
        XCTAssertTrue(machine(app, "jerry@Mac-Studio.local").exists(within: 10), "the local copy shows before sign-in")
        openAccountPage(app)
        let apple = appleButton(app)
        XCTAssertTrue(apple.waitForHittable(timeout: 10), "the signed-out account page offers sign-in")
        apple.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-device-current"].exists(within: 15))
        pollLabel(app, "account-synced-machines",
                  "the merged machine, fleet-hel1 and the pushed build-box: 3 in the account") { $0.contains("3") }
        closeSettings(app)

        XCTAssertTrue(machine(app, "jerry@mac-studio.local").exists(within: 8))
        XCTAssertEqual(machines(app, containing: "mac-studio.local").count, 1,
                       "the local machine took the account's id: one row, not two")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mac Studio'")).firstMatch.exists,
                      "the account's copy wins: its nickname replaces the local one")
        XCTAssertTrue(machine(app, "ci@10.0.4.12").exists, "a machine the account didn't know stays and is pushed")
        XCTAssertTrue(machine(app, "jerry@fleet-hel1").exists)
        attach(app, "account-merged-list")
    }

    func testAMachineThatLooksLikeASecretIsNotSyncedAndSaysSo() throws {
        let app = try launch(hosts: [
            ["id": UUID().uuidString, "host": "pi.local", "username": "pi",
             "nickname": "-----BEGIN OPENSSH PRIVATE KEY-----", "authKind": "key"],
        ])
        openAccountPage(app)
        let apple = appleButton(app)
        XCTAssertTrue(apple.waitForHittable(timeout: 10))
        apple.tap()
        let alert = app.alerts["Some things didn't sync"]
        XCTAssertTrue(alert.exists(within: 15), "a refused machine is named, not dropped silently")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never leave this device'")).firstMatch.exists)
        alert.buttons["OK"].tap()
    }

    // MARK: Settings › HerdrUp account

    func testTheSignedInAccountPageListsDevicesAndRenamesOne() throws {
        let app = try launch(signedIn: true)
        openAccountPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["account-identity"].exists(within: 8))
        XCTAssertTrue(app.descendants(matching: .any)["account-identity"].label.contains("Signed in with Apple"))
        XCTAssertTrue(app.descendants(matching: .any)["account-device-current"].exists(within: 5))
        XCTAssertTrue(app.buttons["account-sign-out"].exists)
        XCTAssertTrue(app.buttons["account-delete"].exists)
        attach(app, "account-page-signed-in")

        let menu = app.buttons["account-device-menu-dev_mock_other_macbook"]
        XCTAssertTrue(menu.waitForHittable(timeout: 5))
        menu.tap()
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForHittable(timeout: 3), "the device menu offers Rename")
        rename.tap()
        let alert = app.alerts["Rename device"]
        XCTAssertTrue(alert.exists(within: 5), "Rename opens its alert (after the menu has closed, on iPad too)")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.exists(within: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Studio Laptop")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(app.staticTexts["Studio Laptop"].exists(within: 8), "the rename reaches the account and the list")
    }

    func testSigningOutKeepsTheMachinesOnThisDevice() throws {
        let app = try launch(signedIn: true, hosts: [
            ["id": UUID().uuidString, "host": "10.0.4.12", "username": "ci", "nickname": "build-box", "authKind": "key"],
        ])
        openAccountPage(app)
        let signOut = app.buttons["account-sign-out"]
        XCTAssertTrue(signOut.waitForHittable(timeout: 8))
        signOut.tap()
        let confirm = app.buttons["account-confirm-sign-out"].firstMatch
        XCTAssertTrue(confirm.exists(within: 3))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-signed-out"].exists(within: 8), "the page turns signed out")
        closeSettings(app)
        XCTAssertTrue(machine(app, "ci@10.0.4.12").exists(within: 5), "signing out keeps the local machines")
    }

    func testDeletingTheAccountConfirmsWithAFreshSignIn() throws {
        let app = try launch(signedIn: true)
        deleteAccount(app)
        let alert = app.alerts["Account deleted"]
        XCTAssertTrue(alert.exists(within: 10))
        XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Stop Using'")).firstMatch.exists,
                       "Apple confirmed the revoke: no manual steps")
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-signed-out"].exists(within: 5))
    }

    func testDeletingWhenAppleDidNotConfirmShowsApplesManualSteps() throws {
        let app = try launch(signedIn: true, environment: ["HERDR_MOCK_ACCOUNT_MANUAL_REVOKE": "1"])
        deleteAccount(app)
        let alert = app.alerts["Account deleted"]
        XCTAssertTrue(alert.exists(within: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'Sign in with Apple' AND label CONTAINS 'Stop Using'")).firstMatch.exists,
                      "manual_revoke shows Apple's path: Settings › Apple Account › Sign in with Apple › HerdrUp › Stop Using")
        attach(app, "account-deleted-manual-revoke")
        alert.buttons["OK"].tap()
    }

    // MARK: The account avatar on the machine list

    func testTheMachineListAvatarShowsTheAccountState() throws {
        let local: [[String: Any]] = [
            ["id": UUID().uuidString, "host": "10.0.4.12", "username": "ci", "nickname": "build-box", "authKind": "key"],
        ]
        var app = try launch(hosts: local)
        var avatar = app.descendants(matching: .any)["hosts.account"]
        XCTAssertTrue(avatar.exists(within: 10), "the machine list shows the account avatar")
        XCTAssertEqual(avatar.label, "HerdrUp account")
        pollValue(avatar, "signed out", equals: "Signed out")
        XCTAssertGreaterThanOrEqual(avatar.frame.width, 44, "the hit target is at least 44 pt")
        XCTAssertGreaterThanOrEqual(avatar.frame.height, 44)
        attach(app, "hosts-account-signed-out")
        app.terminate()

        app = try launch(signedIn: true, hosts: local, environment: ["HERDR_MOCK_ACCOUNT_EMAIL": "sam.rivera@gmail.com"])
        avatar = app.descendants(matching: .any)["hosts.account"]
        XCTAssertTrue(avatar.exists(within: 10))
        pollValue(avatar, "signed in and synced", equals: "Signed in as sam.rivera@gmail.com")
        attach(app, "hosts-account-signed-in")
        app.terminate()

        app = try launch(signedIn: true, hosts: local, environment: [
            "HERDR_MOCK_ACCOUNT_EMAIL": "sam.rivera@gmail.com", "HERDR_MOCK_ACCOUNT_SYNC_OFFLINE": "1",
        ])
        avatar = app.descendants(matching: .any)["hosts.account"]
        XCTAssertTrue(avatar.exists(within: 10))
        pollValue(avatar, "signed in, sync failed", equals: "Needs attention")
        attach(app, "hosts-account-needs-attention")
    }

    func testTappingTheAvatarOpensTheAccountPage() throws {
        let local: [[String: Any]] = [
            ["id": UUID().uuidString, "host": "10.0.4.12", "username": "ci", "nickname": "build-box", "authKind": "key"],
        ]
        var app = try launch(hosts: local)
        var avatar = app.descendants(matching: .any)["hosts.account"]
        XCTAssertTrue(avatar.waitForHittable(timeout: 10))
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-signed-out"].exists(within: 8),
                      "signed out, the avatar opens the sign-in page")
        XCTAssertTrue(appleButton(app).exists(within: 5))
        app.terminate()

        app = try launch(signedIn: true, hosts: local)
        avatar = app.descendants(matching: .any)["hosts.account"]
        XCTAssertTrue(avatar.waitForHittable(timeout: 10))
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-identity"].exists(within: 8),
                      "signed in, the avatar opens the account page")
        XCTAssertTrue(app.buttons["account-sign-out"].exists)
        let close = app.buttons["account-sheet-close"]
        XCTAssertTrue(close.waitForHittable(timeout: 5))
        close.tap()
        XCTAssertTrue(avatar.waitForHittable(timeout: 5), "closing returns to the machine list")
    }

    private func pollValue(_ element: XCUIElement, _ what: String, equals expected: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        var last = ""
        let met = poll(15, every: 0.3) {
            last = element.value as? String ?? ""
            return last == expected
        }
        if !met { XCTFail("\(what): hosts.account value = \(last)", file: file, line: line) }
    }

    // MARK: Enrolment refusals

    func testAKeyInAnotherAccountOffersToSignOut() throws {
        let app = try launch(environment: ["HERDR_MOCK_ACCOUNT_ENROL": "device_in_other_account"])
        let apple = appleButton(app)
        XCTAssertTrue(apple.waitForHittable(timeout: 10))
        apple.tap()
        let signOut = app.alerts.buttons["account-notice-sign-out"].firstMatch
        XCTAssertTrue(signOut.exists(within: 15), "device_in_other_account offers to sign out of this account")
        attach(app, "account-device-in-other-account")
        signOut.tap()
        openAccountPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["account-signed-out"].exists(within: 8))
    }

    func testTooManyDevicesIsExplained() throws {
        let app = try launch(environment: ["HERDR_MOCK_ACCOUNT_ENROL": "too_many_devices"])
        let apple = appleButton(app)
        XCTAssertTrue(apple.waitForHittable(timeout: 10))
        apple.tap()
        let alert = app.alerts["Too many devices"]
        XCTAssertTrue(alert.exists(within: 15))
        alert.buttons["OK"].tap()
        openAccountPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["account-enrolment-failed"].exists(within: 8),
                      "the account page says this device isn't added and offers to try again")
    }

    // MARK: Helpers

    private func launch(features: String? = nil, signedIn: Bool = false, hosts: [[String: Any]] = [],
                        environment: [String: String] = [:]) throws -> XCUIApplication {
        var env = environment
        if let features { env["HERDR_MOCK_ACCOUNT_FEATURES"] = features }
        if signedIn { env["HERDR_MOCK_ACCOUNT_SIGNED_IN"] = "1" }
        let app = XCUIApplication.forUITest()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "account"
        app.launchEnvironment.merge(env) { _, new in new }
        // The argument domain wins over the app-group defaults the stores read and writes
        // nothing to them (SavedHostMissingSecretTests): exactly these machines, no shares.
        app.launchArguments += ["-dev.herdr.savedHosts.v1", try Self.plistData(hosts),
                                "-dev.herdr.sharedMachines.v1", try Self.plistData([])]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad, app.windows.firstMatch.exists(within: 10), !app.isFullScreen {
            app.restoreFullScreen()
        }
        return app
    }

    private static func plistData(_ object: [[String: Any]]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: object)
        return "<" + json.map { String(format: "%02x", $0) }.joined() + ">"
    }

    private func appleButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["account-continue-apple"]
    }

    private func machine(_ app: XCUIApplication, _ subtitle: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subtitle)).firstMatch
    }

    private func machines(_ app: XCUIApplication, containing text: String) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).allElementsBoundByIndex
    }

    private func openAccountPage(_ app: XCUIApplication) {
        let settings = app.buttons["fixture-open-settings"]
        XCTAssertTrue(settings.waitForHittable(timeout: 15), "the fixture's Settings button")
        settings.tap()
        let row = app.buttons["settings-herdrup-account"]
        var reached = row.waitForHittable(timeout: 5)
        for _ in 0..<4 where !reached {
            app.swipeUp()
            reached = row.waitForHittable(timeout: 2)
        }
        XCTAssertTrue(reached, "Settings lists the HerdrUp account row")
        row.tap()
    }

    private func closeSettings(_ app: XCUIApplication) {
        let back = app.buttons["Back"].firstMatch
        if back.waitForHittable(timeout: 3) { back.tap() }
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForHittable(timeout: 5), "Settings closes")
        close.tap()
        XCTAssertTrue(close.gone(within: 5))
    }

    private func deleteAccount(_ app: XCUIApplication) {
        openAccountPage(app)
        let delete = app.buttons["account-delete"]
        var reached = delete.waitForHittable(timeout: 8)
        for _ in 0..<3 where !reached {
            app.swipeUp()
            reached = delete.waitForHittable(timeout: 2)
        }
        XCTAssertTrue(reached)
        delete.tap()
        let confirm = app.buttons["account-confirm-delete"].firstMatch
        XCTAssertTrue(confirm.exists(within: 3), "deletion asks first, and says machines and prompts stay")
        confirm.tap()
    }
}
