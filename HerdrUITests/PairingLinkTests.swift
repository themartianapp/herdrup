import UIKit
import XCTest

/// Pairing without the camera: a pasted code, a `herdrup://pair#` link, and a guest-only
/// phone adding its own machine. Each must reach the confirmation (host, user, host key)
/// and connect nothing until Connect is tapped.
final class PairingLinkTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// A v2 code as Deimos Forge shows it. The host is a TEST-NET address that is never
    /// contacted: these tests stop at the confirmation.
    private static let json =
        #"{"v":2,"host":"192.0.2.44","port":4021,"user":"forge","token":"t0k3n","fp":"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ssh_port":2222}"#

    private static var link: String {
        let base64url = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "herdrup://pair#" + base64url
    }

    func testPastingACodeShowsTheConfirmation() {
        let app = XCUIApplication.launched(mock: "onboarding")
        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()

        UIPasteboard.general.string = Self.json
        tapPaste(in: app, identifier: "pairing-paste-button")
        assertConfirmation(app, "pairing-paste-confirmation")
    }

    func testOpeningALinkWhileRunningShowsTheConfirmation() {
        let app = XCUIApplication.launched(mock: "onboarding")
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 10))
        app.open(URL(string: Self.link)!)
        assertConfirmation(app, "pairing-link-running")
    }

    func testOpeningALinkColdShowsTheConfirmation() {
        let app = XCUIApplication.launched(mock: "onboarding")
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 10))
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.open(URL(string: Self.link)!)
        assertConfirmation(app, "pairing-link-cold")
    }

    /// A guest-only phone opens straight into its one share, with no way back to the machine
    /// list; its Settings must still offer pairing a machine of its own.
    func testAGuestOnlyPhoneCanPairItsOwnMachineFromSettings() {
        let app = XCUIApplication.launched(mock: "guest")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10))
        let settingsTab = app.tabBars.firstMatch.buttons["Settings"]
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = poll(3, every: 0.25) { settingsTab.isSelected }
        }

        let scan = app.buttons["guest-settings-scan-pairing"]
        for _ in 0..<4 where !scan.isHittable { app.swipeUp() }
        XCTAssertTrue(scan.waitForExistence(timeout: 10), "guest Settings should offer Scan pairing code")
        attach(app, "pairing-guest-settings")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan to connect"].waitForExistence(timeout: 10),
                      "Scan pairing code should open the pairing sheet")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(scan.waitForExistence(timeout: 10))

        UIPasteboard.general.string = Self.link
        tapPaste(in: app, identifier: "guest-settings-paste-pairing")
        assertConfirmation(app, "pairing-guest-paste-confirmation")
    }

    // MARK: - Helpers

    /// The system PasteButton may not carry the identifier set on it, so fall back to its
    /// label.
    private func tapPaste(in app: XCUIApplication, identifier: String) {
        let byID = app.buttons[identifier]
        let button = byID.waitForExistence(timeout: 5) ? byID : app.buttons["Paste"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "a Paste pairing code button should show")
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func assertConfirmation(_ app: XCUIApplication, _ shot: String) {
        let host = app.staticTexts["pairing-confirm-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 15), "the confirmation should show")
        XCTAssertEqual(host.label, "192.0.2.44")
        XCTAssertEqual(app.staticTexts["pairing-confirm-user"].label, "forge")
        XCTAssertEqual(app.staticTexts["pairing-confirm-port"].label, "2222")
        XCTAssertEqual(app.staticTexts["pairing-confirm-fingerprint"].label,
                       "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertTrue(app.buttons["pairing-confirm-connect"].exists,
                      "nothing connects before Connect is tapped")
        XCTAssertFalse(app.staticTexts["Connecting…"].exists)
        attach(app, shot)
    }
}
