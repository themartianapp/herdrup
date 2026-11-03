import XCTest

/// Exercises the first screen's actual command buttons. The phone is showing
/// commands intended for another machine, so tapping them must visibly confirm
/// a copy rather than behaving like inert code blocks.
final class OnboardingTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testInstallAndPairCommandsAreCopyable() {
        let app = XCUIApplication.launched(mock: "onboarding")

        XCTAssertTrue(
            app.descendants(matching: .any)["pairing-prerequisite-tailscale"]
                .waitForExistence(timeout: 8),
            "the first screen should name the two-device Tailscale prerequisite")
        XCTAssertTrue(
            app.descendants(matching: .any)["pairing-prerequisite-ssh"]
                .waitForExistence(timeout: 3),
            "the first screen should name SSH and macOS Remote Login")

        let install = app.buttons[
            "Copy command: curl -fsSL https://herdrup.app/install.sh | sh"
        ]
        XCTAssertTrue(install.waitForExistence(timeout: 8),
                      "the one-line fork installer should be visible and tappable")
        install.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2),
                      "tapping the installer should confirm the clipboard write")

        let pair = app.buttons["Copy command: herdr pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 3),
                      "the pairing command should be visible and tappable")
        pair.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2),
                      "tapping the pairing command should confirm the clipboard write")

        // Pairing doesn't start herdr; the first screen must say how (Discord, 2026-10-08).
        let start = app.buttons["Copy command: herdr"]
        XCTAssertTrue(start.waitForExistence(timeout: 3),
                      "the first screen should give the command that starts herdr after pairing")
    }

    /// Installing the fork doesn't restart a server that is already running, so the
    /// "missing features" notice must give the restart commands, not only "install it".
    func testForkNoticeGivesTheRestartCommands() {
        let app = XCUIApplication.launched(mock: "fork-notice")

        let stop = app.buttons["Copy command: herdr server stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8),
                      "the fork notice should give the command that stops the old server")
        XCTAssertTrue(app.buttons["Copy command: herdr"].exists,
                      "the fork notice should give the command that starts herdr again")
        stop.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2),
                      "tapping the restart command should confirm the clipboard write")
    }

    func testScannerExplainsBothCleanQRAlternatives() {
        let app = XCUIApplication.launched(mock: "pairing-guidance")

        let fallback = app.descendants(matching: .any)["pairing-qr-fallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 8),
                      "scanner guidance should explain what to do with a distorted QR")
        XCTAssertTrue(fallback.label.contains("herdr pair --open"),
                      "scanner guidance should offer a clean opened QR")
        XCTAssertTrue(fallback.label.contains("--qr-file"),
                      "scanner guidance should offer an SVG file")
    }
}
