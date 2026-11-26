import XCTest

/// Pair from another device (option B, code-first) over the account mock
/// (`HERDR_SCREENSHOT_MOCK=account`, `HERDR_MOCK_ACCOUNT_PAIR`, App/AccountMock.swift). The real
/// `PairApproval`, `PairRequester` and pair-v1 crypto run against the mock service.
///
/// - Approver: a mock new device ("MacBook Air") asks; this device types its code (the sheet's
///   `fixture-pair-code`), adds the key on the machines (`PairMachinesMock`), and the envelope the
///   mock device opens with its own key is read back (`fixture-pair-envelope`).
/// - New device: this device asks; a mock approver claims, approves fleet-hel1, Mac Studio and
///   laptop (build-box timed out), then retries build-box. The code shown must equal the one the
///   mock approver computes (`fixture-pair-expected-code`).
final class PairFromDeviceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Approver

    func testApprovingAPairRequestAddsTheKeyAndRetriesAFailedMachine() throws {
        let app = launch(["HERDR_MOCK_ACCOUNT_PAIR": "approver"])
        let sheet = app.descendants(matching: .any)["pair-approve-sheet"]
        XCTAssertTrue(sheet.exists(within: 20), "the sheet opens by itself while a device asks")
        XCTAssertTrue(app.staticTexts["Pair MacBook Air?"].exists)

        let code = fixture(app, "fixture-pair-code") { $0.count == 4 }
        let field = app.textFields["pair-approve-code"]
        XCTAssertTrue(field.waitForHittable(timeout: 10), "the code field opens once the device shows its code")
        field.tap()
        field.typeText(code == "0000" ? "1111" : "0000")
        app.buttons["pair-approve-continue"].tap()
        let error = app.descendants(matching: .any)["pair-approve-error"]
        XCTAssertTrue(error.exists(within: 5), "a wrong code says so")
        XCTAssertTrue(error.label.contains("2 tries left"), error.label)
        attach(app, "pair-approve-wrong-code")

        field.typeText(code)
        attach(app, "pair-approve-code")
        app.buttons["pair-approve-continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pair-approve-matched"].exists(within: 5), "step 2 follows the code")

        // Every reachable machine is ticked; the others are greyed with the reason.
        XCTAssertTrue(waitValue(app, "pair-approve-machine-fleet-hel1", "Ticked"))
        XCTAssertTrue(waitValue(app, "pair-approve-machine-studio", "Ticked"))
        XCTAssertTrue(waitValue(app, "pair-approve-machine-build-box", "Ticked"))
        XCTAssertTrue(waitValue(app, "pair-approve-machine-laptop", "Unreachable"))
        XCTAssertTrue(waitValue(app, "pair-approve-machine-old-pi", "Needs herdr update 0.9.2"))
        let laptop = app.buttons["pair-approve-machine-laptop"]
        XCTAssertTrue(laptop.label.contains("Can’t reach it from this"), laptop.label)
        XCTAssertTrue(app.buttons["pair-approve-machine-old-pi"].label.contains("Needs a herdr update (herdr 0.9.2)"))
        let approve = app.buttons["pair-approve-approve"]
        XCTAssertEqual(approve.label, "Approve 3 machines")
        attach(app, "pair-approve-machines")

        approve.tap()
        if element(app, "pair-approve-machine-studio").exists(within: 3), waitValue(app, "pair-approve-machine-studio", "Adding", timeout: 3) {
            attach(app, "pair-approve-adding")
        }
        XCTAssertTrue(app.buttons["pair-approve-done"].exists(within: 20), "the approval reports each machine")
        XCTAssertTrue(app.staticTexts["Paired MacBook Air"].exists)
        XCTAssertTrue(waitValue(app, "pair-approve-machine-build-box", "Failed: timed out"))
        // What MacBook Air reads in the envelope, opened with its own key.
        let sent = fixture(app, "fixture-pair-envelope") { $0.hasPrefix("seq 1") }
        XCTAssertEqual(sent, "seq 1: fleet-hel1 added, studio added, build-box failed (timed out)")
        attach(app, "pair-approve-results")

        let retry = app.buttons["pair-approve-retry"]
        XCTAssertEqual(retry.label, "Try build-box again")
        retry.tap()
        let resent = fixture(app, "fixture-pair-envelope") { $0.hasPrefix("seq 2") }
        XCTAssertEqual(resent, "seq 2: fleet-hel1 added, studio added, build-box added",
                       "the retry is a new envelope with a higher seq")
        XCTAssertTrue(waitValue(app, "pair-approve-machine-build-box", "Added"))
        XCTAssertTrue(retry.gone(within: 5), "nothing left to retry")
        attach(app, "pair-approve-retried")

        app.buttons["pair-approve-done"].tap()
        XCTAssertTrue(sheet.gone(within: 5))
    }

    /// The service doesn't list the request (`HERDR_MOCK_PAIR_UNLISTED`): only its push opens
    /// the sheet. Deny ends it, and Settings › HerdrUp account shows REQUESTS.
    func testAPairPushOpensTheRequestAndDenyEndsIt() throws {
        let push = #"{"aps":{"alert":{"body":"MacBook Air wants to pair with your machines"},"category":"pair_request"},"request_id":"PairMockAAAAAAAAAAAAAA"}"#
        let app = launch(["HERDR_MOCK_ACCOUNT_PAIR": "approver", "HERDR_MOCK_PAIR_UNLISTED": "1",
                          "HERDR_MOCK_PUSH_TAP": push])
        let sheet = app.descendants(matching: .any)["pair-approve-sheet"]
        XCTAssertTrue(sheet.exists(within: 20), "the push opens the request")
        attach(app, "pair-approve-from-push")
        let deny = app.buttons["pair-approve-deny"]
        XCTAssertTrue(deny.waitForHittable(timeout: 5))
        deny.tap()
        XCTAssertTrue(sheet.gone(within: 8), "a denial taken by the service closes the sheet")

        let settings = app.buttons["fixture-open-settings"]
        XCTAssertTrue(settings.waitForHittable(timeout: 10))
        settings.tap()
        let account = app.buttons["settings-herdrup-account"]
        var reached = account.waitForHittable(timeout: 5)
        for _ in 0..<4 where !reached {
            app.swipeUp()
            reached = account.waitForHittable(timeout: 2)
        }
        XCTAssertTrue(reached, "Settings lists the HerdrUp account")
        account.tap()
        XCTAssertTrue(app.staticTexts["REQUESTS"].exists(within: 10), "pair_v1 shows REQUESTS instead of WEB ACCESS")
        XCTAssertFalse(app.staticTexts["WEB ACCESS"].exists)
        XCTAssertTrue(element(app, "account-web-access-none").exists, "no browser is asking")
        XCTAssertFalse(element(app, "account-pair-request").exists, "the denied request is gone")
        attach(app, "pair-requests-settings")
    }

    // MARK: New device

    func testPairingThisDeviceFromAnotherOneSavesTheMachines() throws {
        let app = launch(["HERDR_MOCK_ACCOUNT_PAIR": "new", "HERDR_MOCK_PAIR_UNREACHABLE": "laptop"],
                         hosts: keylessHosts)
        let pairFleet = app.buttons["pair-this-device-fleet-hel1"]
        XCTAssertTrue(pairFleet.waitForHittable(timeout: 20), "an account machine without a key here offers Pair this device")
        XCTAssertTrue(app.staticTexts["FROM YOUR ACCOUNT"].exists)
        XCTAssertTrue(app.buttons["pair-this-device-old-pi"].exists)
        attach(app, "pair-from-account")

        pairFleet.tap()
        let option = app.buttons["pair-device-approve-option"]
        XCTAssertTrue(option.waitForHittable(timeout: 5), "the sheet offers approving from another device")
        XCTAssertTrue(app.buttons["pair-device-qr-option"].exists)
        attach(app, "pair-device-sheet")
        option.tap()

        let code = element(app, "pair-device-code")
        XCTAssertTrue(code.exists(within: 10), "the waiting card shows")
        XCTAssertTrue(app.buttons["pair-device-cancel"].exists)
        let shown = poll(20) { code.label.count == 4 && code.label.allSatisfy(\.isNumber) ? code.label : nil }
        XCTAssertNotNil(shown, "the code shows once the other device opened the request: \(code.label)")
        XCTAssertEqual(shown, fixture(app, "fixture-pair-expected-code") { $0.count == 4 },
                       "this device's code is the one the approver computes")
        attach(app, "pair-device-waiting")

        XCTAssertTrue(element(app, "paired-by-section").exists(within: 20), "the approved machines are saved")
        XCTAssertTrue(app.staticTexts["PAIRED BY JERRY'S IPHONE"].exists)
        XCTAssertTrue(app.buttons["paired-machine-fleet-hel1"].exists(within: 5))
        XCTAssertTrue(app.buttons["paired-machine-Mac Studio"].exists(within: 5))
        let laptop = element(app, "paired-machine-laptop")
        XCTAssertTrue(poll(8) { laptop.label.contains("Join its network to connect") ? true : nil } ?? false, laptop.label)
        XCTAssertTrue(app.buttons["paired-use-herdr-pair-laptop"].exists)
        // build-box timed out on the approver: it stays under FROM YOUR ACCOUNT and says why.
        let buildBox = app.buttons.matching(NSPredicate(format: "label CONTAINS 'build-box' AND label CONTAINS 'timed out'")).firstMatch
        XCTAssertTrue(buildBox.exists(within: 5), "a machine the approver couldn't add says so")
        XCTAssertFalse(app.buttons["pair-this-device-fleet-hel1"].exists, "a paired machine no longer asks")
        attach(app, "pair-device-paired")

        // The approver tries build-box again: the newer envelope adds it here too.
        XCTAssertTrue(app.buttons["paired-machine-build-box"].exists(within: 20), "a retried machine arrives later")
        XCTAssertFalse(app.buttons["pair-this-device-build-box"].exists)
        XCTAssertTrue(app.buttons["pair-this-device-old-pi"].exists, "old-pi was not in the envelope")
        attach(app, "pair-device-retried")
    }

    func testANotApprovedRequestOffersAskAgainAndHerdrPair() throws {
        let app = launch(["HERDR_MOCK_ACCOUNT_PAIR": "new", "HERDR_MOCK_PAIR_OUTCOME": "denied"], hosts: keylessHosts)
        let pair = app.buttons["pair-this-device-laptop"]
        XCTAssertTrue(pair.waitForHittable(timeout: 20))
        pair.tap()
        let option = app.buttons["pair-device-approve-option"]
        XCTAssertTrue(option.waitForHittable(timeout: 5))
        option.tap()
        let ended = element(app, "pair-device-ended")
        XCTAssertTrue(ended.exists(within: 30), "the denial reaches this device")
        XCTAssertEqual(ended.label, "Not approved")
        XCTAssertTrue(app.buttons["pair-device-ask-again"].exists)
        XCTAssertTrue(app.buttons["pair-device-use-qr"].exists)
        XCTAssertTrue(app.buttons["pair-this-device-laptop"].exists, "nothing was saved")
        attach(app, "pair-device-not-approved")
    }

    // MARK: Helpers

    private let keylessHosts: [[String: Any]] = [
        ["id": UUID().uuidString, "host": "10.0.0.12", "username": "jerry", "nickname": "build-box", "authKind": "key"],
        ["id": UUID().uuidString, "host": "laptop", "username": "jerry", "nickname": "laptop", "authKind": "key"],
        ["id": UUID().uuidString, "host": "old-pi", "username": "pi", "nickname": "old-pi", "authKind": "key"],
    ]

    private func launch(_ env: [String: String], hosts: [[String: Any]] = []) -> XCUIApplication {
        let app = XCUIApplication.forUITest()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "account"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_SIGNED_IN"] = "1"
        for (key, value) in env { app.launchEnvironment[key] = value }
        let json = (try? JSONSerialization.data(withJSONObject: hosts)) ?? Data("[]".utf8)
        app.launchArguments += ["-dev.herdr.savedHosts.v1", "<" + json.map { String(format: "%02x", $0) }.joined() + ">",
                                "-dev.herdr.sharedMachines.v1", "<5b5d>"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad, app.windows.firstMatch.exists(within: 10), !app.isFullScreen {
            app.restoreFullScreen()
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// A fixture's label once `ready` accepts it.
    private func fixture(_ app: XCUIApplication, _ id: String, ready: (String) -> Bool) -> String {
        let element = element(app, id)
        if let label = poll(15, { element.exists && ready(element.label) ? element.label : nil }) { return label }
        XCTFail("\(id) never got ready: \(element.exists ? element.label : "missing")")
        return ""
    }

    private func waitValue(_ app: XCUIApplication, _ id: String, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let element = element(app, id)
        return poll(timeout) { element.exists && (element.value as? String) == value ? true : nil } ?? false
    }

    private func poll<T>(_ timeout: TimeInterval, _ read: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return read()
    }
}
