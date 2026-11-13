import Darwin
import UIKit
import XCTest

/// Pairing without the camera: a pasted code, a `herdrup://pair#` link, and a guest-only
/// phone adding its own machine. Each must reach the confirmation (host, user, host key)
/// and connect nothing until Connect is tapped; and after "Open it", nothing connects
/// again without a tap.
final class PairingLinkTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// The nickname a machine paired by `testGoingBackAfterOpeningAPairedMachineDoesNotReconnect`
    /// is saved under (`user@host`).
    private static let pairedNickname = "forge@127.0.0.1"

    /// A v2 code as Deimos Forge shows it. The host is a TEST-NET address that is never
    /// contacted: these tests stop at the confirmation.
    private static let json =
        #"{"v":2,"host":"192.0.2.44","port":4021,"user":"forge","token":"t0k3n","fp":"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ssh_port":2222}"#

    private static var link: String { pairingLink(json) }

    private static func pairingLink(_ json: String) -> String {
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

    /// Pair for real (against a stub `herdr pair` listener on loopback), tap "Open it", go
    /// back to the machine list: the app must stay there. Opening the paired machine once
    /// must not leave anything behind that reconnects the next time the list shows.
    func testGoingBackAfterOpeningAPairedMachineDoesNotReconnect() throws {
        let daemon = try StubPairingDaemon()
        defer { daemon.stop() }
        let json = #"{"v":2,"host":"127.0.0.1","port":\#(daemon.port),"user":"forge","token":"t0k3n","fp":"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ssh_port":2222}"#

        // The mock list starts connected; its Back is the disconnect. Saved hosts start
        // empty (argument domain); in a mock the key stays in memory, nothing is pinned and
        // the list is never written, so nothing outlives the run.
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launchArguments = ["-dev.herdr.savedHosts.v1", "<5b5d>"]
        app.launch()
        let back = Self.backButton(app)
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()

        let scan = app.buttons["Scan pairing code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10), "Back should show the machine list")
        scan.tap()
        UIPasteboard.general.string = json
        tapPaste(in: app, identifier: "pairing-paste-button")
        let connect = app.buttons["pairing-confirm-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "the confirmation should show")
        connect.tap()

        let openIt = app.buttons["Open it"]
        XCTAssertTrue(openIt.waitForExistence(timeout: 20), "pairing with the stub listener should succeed")
        attach(app, "pairing-paired")
        openIt.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Open it should connect to the paired machine")
        back.tap()

        let row = Self.pairedRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Back should show the machine list with the paired machine")
        // The bug this guards: the list replayed the pairing and connected by itself.
        XCTAssertFalse(poll(4, every: 0.25) { back.exists },
                       "returning to the machine list must not reconnect without a tap")
        XCTAssertTrue(row.exists)
        attach(app, "pairing-back-stays-on-machines")
    }

    /// Pair for real from a `herdrup://pair#` link: the sheet that opens on a link (or a
    /// guest Settings paste) is the confirmation, not the scanner, and its Connect must save
    /// the machine too ("Open it" shows only once the save succeeded). The save publishes the
    /// machine list, which in a Debug build stops the app if it happens off the main thread
    /// (#664), so this fails rather than warns.
    func testConnectingFromALinkSavesTheMachine() throws {
        let daemon = try StubPairingDaemon()
        defer { daemon.stop() }
        let json = #"{"v":2,"host":"127.0.0.1","port":\#(daemon.port),"user":"forge","token":"t0k3n","fp":"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ssh_port":2222}"#

        let app = XCUIApplication.launched(mock: "onboarding")
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 10))
        app.open(URL(string: Self.pairingLink(json))!)
        let connect = app.buttons["pairing-confirm-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15), "the link should open its confirmation")
        connect.tap()

        XCTAssertTrue(app.buttons["Open it"].waitForExistence(timeout: 20),
                      "pairing with the stub listener should succeed")
        attach(app, "pairing-link-paired")
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

    private static func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[UIDevice.current.userInterfaceIdiom == .pad ? "agents-back" : "Back"].firstMatch
    }

    private static func pairedRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", pairedNickname)).firstMatch
    }
}

/// A one-shot stand-in for `herdr pair`'s listener: accepts one connection on loopback,
/// reads the redeem line, and answers `pair.ok` (versions 1 and 2 need no proof). The app
/// in the simulator shares the Mac's loopback with this test runner.
private final class StubPairingDaemon {
    struct Failure: Error {}

    let port: Int
    private let listener: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure() }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw Failure()
        }
        listener = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { Self.serveOnce(fd) }
    }

    func stop() { Darwin.close(listener) }

    private static func serveOnce(_ listener: Int32) {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { Darwin.close(connection) }
        var byte: UInt8 = 0
        while read(connection, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
        let reply = Array(#"{"type":"pair.ok"}"#.utf8) + [UInt8(ascii: "\n")]
        _ = reply.withUnsafeBufferPointer { write(connection, $0.baseAddress, $0.count) }
    }
}
