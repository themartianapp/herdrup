import XCTest

/// "Approve a browser?" (web owner access I1, approval-flow option D) over the account mock
/// (`HERDR_SCREENSHOT_MOCK=account`, `HERDR_MOCK_ACCOUNT_APPROVAL=1`, App/AccountMock.swift): a
/// browser asks while the app is open, this device claims it, the browser reveals, and the test
/// types the code the mock browser shows (`fixture-browser-code`). The real `BrowserApproval` and
/// `WebAccessApproval` run against the mock service; the machines are `OwnerAccessMock`'s
/// ("fleet-hel1" admits browsers, "Mac Studio" needs a herdr update).
final class WebAccessApprovalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testApprovingABrowserWithItsCodeGrantsTheMachines() throws {
        let app = try launch()
        let sheet = app.descendants(matching: .any)["web-approve-sheet"]
        XCTAssertTrue(sheet.exists(within: 20), "the sheet opens by itself when a browser asks")
        XCTAssertTrue(app.staticTexts["Approve a browser?"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["web-approve-terminal-warning"].exists(within: 3),
                      "terminal is the default access, and its warning shows while it is chosen")
        let approve = app.buttons["web-approve-approve"]
        XCTAssertFalse(approve.isEnabled, "no approval before the code")

        let code = browserCode(app)
        let field = app.textFields["web-approve-code"]
        XCTAssertTrue(field.waitForHittable(timeout: 10), "the code field opens once the browser shows its code")
        field.tap()
        field.typeText(code == "0000" ? "1111" : "0000")
        let error = app.descendants(matching: .any)["web-approve-error"]
        XCTAssertTrue(error.exists(within: 5), "a wrong code says so")
        XCTAssertTrue(error.label.contains("2 tries left"), error.label)
        attach(app, "web-approve-wrong-code")

        field.typeText(code)
        XCTAssertTrue(app.descendants(matching: .any)["web-approve-matched"].exists(within: 5))
        XCTAssertTrue(approve.isEnabled)

        // The rows open in place: Access shows the choice, and Chat only hides the warning.
        app.buttons["web-approve-row-access"].tap()
        let chatOnly = app.buttons["web-approve-scope-Chat only"]
        XCTAssertTrue(chatOnly.waitForHittable(timeout: 3))
        chatOnly.tap()
        XCTAssertTrue(app.descendants(matching: .any)["web-approve-terminal-warning"].gone(within: 3))
        app.buttons["web-approve-row-for"].tap()
        let week = app.buttons["web-approve-length-7 days"]
        XCTAssertTrue(week.waitForHittable(timeout: 3))
        week.tap()
        attach(app, "web-approve-matched")

        approve.tap()
        let result = app.descendants(matching: .any)["web-approve-result"]
        XCTAssertTrue(result.exists(within: 15), "the approval reports what each machine did")
        XCTAssertTrue(result.label.contains("fleet-hel1"), result.label)
        XCTAssertTrue(result.label.contains("Mac Studio needs a herdr update"), result.label)
        attach(app, "web-approve-approved")
        app.buttons["web-approve-done"].tap()
        XCTAssertTrue(sheet.gone(within: 5))
    }

    func testDenyClosesTheSheet() throws {
        let app = try launch()
        let sheet = app.descendants(matching: .any)["web-approve-sheet"]
        XCTAssertTrue(sheet.exists(within: 20))
        let deny = app.buttons["web-approve-deny"]
        XCTAssertTrue(deny.waitForHittable(timeout: 5))
        deny.tap()
        XCTAssertTrue(sheet.gone(within: 8), "a denial taken by the service closes the sheet")
    }

    // MARK: Helpers

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication.forUITest()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "account"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_SIGNED_IN"] = "1"
        app.launchEnvironment["HERDR_MOCK_ACCOUNT_APPROVAL"] = "1"
        app.launchArguments += ["-dev.herdr.savedHosts.v1", "<5b5d>", "-dev.herdr.sharedMachines.v1", "<5b5d>"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad, app.windows.firstMatch.exists(within: 10), !app.isFullScreen {
            app.restoreFullScreen()
        }
        return app
    }

    /// The code the mock browser shows, once this device has claimed the request.
    private func browserCode(_ app: XCUIApplication) -> String {
        let fixture = app.descendants(matching: .any)["fixture-browser-code"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if fixture.exists, fixture.label.count == 4 { return fixture.label }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the mock browser never showed a code")
        return ""
    }
}
