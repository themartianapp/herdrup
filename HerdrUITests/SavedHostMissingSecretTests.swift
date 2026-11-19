import XCTest

/// A saved host whose key is not in this phone's Keychain: what a phone set up from
/// another phone has, because the host list moves with the backup and the keys
/// (ThisDeviceOnly) do not. Tapping it, or holding it and choosing Edit, must ask for
/// the key and offer to connect, not open the plain editor, which claims a key is
/// saved and only offers Save.
final class SavedHostMissingSecretTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingAHostWithoutItsKeyAsksForTheKeyAndOffersConnect() throws {
        let (app, row) = try launchWithAKeylessHost()
        row.tap()
        assertReconnectEditor(app)
    }

    func testEditingAHostWithoutItsKeyAsksForTheKeyAndOffersConnect() throws {
        let (app, row) = try launchWithAKeylessHost()
        var opened = false
        for _ in 0..<3 where !opened {
            row.press(forDuration: 1.0)
            let edit = app.buttons["Edit"]
            if edit.exists(within: 3) {
                edit.tap()
                opened = true
            }
        }
        XCTAssertTrue(opened, "holding the host offers Edit")
        assertReconnectEditor(app)
    }

    private func launchWithAKeylessHost() throws -> (XCUIApplication, XCUIElement) {
        // A fresh id each run, so no key a previous run stored can match it.
        let host: [String: Any] = [
            "id": UUID().uuidString, "host": "duo-mac.example.ts.net", "username": "jerry",
            "nickname": "Duo Mac", "authKind": "key",
        ]
        let json = try JSONSerialization.data(withJSONObject: [host])
        let app = XCUIApplication.forUITest()
        // The argument domain wins over the app-group defaults the store reads, and
        // writes nothing to them.
        app.launchArguments += ["-dev.herdr.savedHosts.v1",
                                "<" + json.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Duo Mac")).firstMatch
        XCTAssertTrue(row.exists(within: 15), "the seeded host is listed")
        return (app, row)
    }

    private func assertReconnectEditor(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Reconnect"].exists(within: 10),
                      "a host without its key opens the reconnect editor, not Edit host")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                           "This phone doesn't have the key"))
            .firstMatch.exists, "the editor says why it opened")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add private key"))
            .firstMatch.exists, "the key row asks for a key instead of claiming one is saved")
        XCTAssertTrue(app.buttons["Save & Connect"].exists, "the editor offers to connect")
    }
}
