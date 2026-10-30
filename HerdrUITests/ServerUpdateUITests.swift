import XCTest
import CoreGraphics

/// In-app herdr updates (herdrup#565, proposal B) over the `serverupdate` mock server: the
/// Settings tab's "1" and the update card in Settings › Machines, in every state, on whichever
/// device runs the class (the iPhone app round, and the iPad by `only_device=ipad`).
final class ServerUpdateUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        XCUIApplication.launched(mock: "serverupdate", environment: ["HERDR_MOCK_UPDATE": scenario])
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func settingsTab(_ app: XCUIApplication) -> XCUIElement {
        isPad ? app.buttons.matching(NSPredicate(format: "label == 'Settings'")).firstMatch
              : app.tabBars.buttons["Settings"]
    }

    /// Opens Settings › Machines (the iPad split shows Machines by default).
    private func openMachines(_ app: XCUIApplication) {
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Settings tab")
        tab.tap()
        if !isPad {
            let machines = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Machines'")).firstMatch
            XCTAssertTrue(machines.waitForExistence(timeout: 10), "no Machines row")
            machines.tap()
        }
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["server-update-card"].firstMatch
    }

    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["server-update-title"].firstMatch
    }

    private func waitForTitle(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: "label == %@", text)
        return title(app).waitForExistence(timeout: 2)
            && XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title(app))],
                                timeout: timeout) == .completed
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "update-\(name)-\(isPad ? "ipad" : "iphone")"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Whether the Settings tab carries the red "1". Read from pixels: the system tab bar
    /// draws the badge without exposing it as the button's value.
    private func settingsTabHasBadge(_ app: XCUIApplication) -> Bool {
        guard let image = settingsTab(app).screenshot().image.cgImage else { return false }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where pixels[index] > 210 && pixels[index + 1] < 100 && pixels[index + 2] < 100 {
            red += 1
        }
        return red > 40
    }

    private func waitForBadge(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if settingsTabHasBadge(app) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func confirmUpdate(_ app: XCUIApplication, button: String = "Update") {
        app.buttons["server-update-button"].tap()
        let confirm = app.alerts.buttons[button]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        record(app, "confirm")
        confirm.tap()
    }

    // MARK: States

    func testAvailableShowsBadgeAndCard() {
        let app = launch("available")
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let badged = waitForBadge(app)
        record(app, "badge")
        XCTAssertTrue(badged, "the Settings tab should carry a red 1")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        XCTAssertTrue(app.staticTexts["Folders and avatars need herdr 0.9.5. mac-mini has 0.9.3."].exists)
        XCTAssertTrue(app.buttons["server-update-button"].exists)
        // The one update UI sits right under the machine's hero (proposal B, #572), whose
        // version line names the running build — where the retired staged-build card used
        // to be.
        let hero = app.descendants(matching: .any)["settings-machine-hero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "no machine hero")
        XCTAssertTrue(poll(10, every: 0.5) { hero.label.contains("herdr 0.9.3") },
                      "the hero should carry the daemon version line (got \(hero.label))")
        XCTAssertGreaterThan(card(app).frame.minY, hero.frame.maxY,
                             "the update card should sit under the machine's hero")
        XCTAssertFalse(app.buttons["Update & restart"].exists, "the retired staged-build card is gone")
        record(app, "available")
    }

    func testUpdatingShowsProgressAndTerminalsStayOpen() {
        let app = launch("updating")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Updating herdr"))
        let now = app.staticTexts["server-update-now"]
        let downloading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Downloading 12 of 38 MB'"), object: now)
        XCTAssertEqual(XCTWaiter().wait(for: [downloading], timeout: 15), .completed, "now: \(now.label)")
        XCTAssertTrue(app.staticTexts["Your terminals stay open. You can leave this screen."].exists)
        record(app, "updating")
    }

    /// The update drops the connection while it switches: the card follows it to Done.
    func testDoneAfterTheHandoff() {
        let app = launch("available")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "herdr 0.9.5 is running", timeout: 40))
        XCTAssertTrue(app.staticTexts["All 14 terminals stayed open. Folders and avatars are on."].exists)
        record(app, "done")
    }

    func testFailedOffersTryAgainAndCopyDetails() {
        let app = launch("failed")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Update didn't finish", timeout: 30))
        XCTAssertTrue(app.staticTexts["Nothing changed. herdr 0.9.3 is still running, and your terminals are fine."].exists)
        XCTAssertTrue(app.staticTexts["The download stopped at 21 of 38 MB."].exists)
        record(app, "failed")
        let copy = app.buttons["server-update-copy-details"]
        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Copied'"), object: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "Copy details: \(copy.label)")
        app.buttons["server-update-retry"].tap()
        XCTAssertTrue(waitForTitle(app, "herdr 0.9.5 is running", timeout: 40), "the retry should succeed")
    }

    func testRolledBackCannotBeRetried() {
        let app = launch("rolledback")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Update didn't finish", timeout: 40))
        XCTAssertTrue(app.staticTexts["The new version didn't pass its checks, so herdr switched back to 0.9.3. Your terminals are fine."].exists)
        XCTAssertFalse(app.buttons["server-update-retry"].exists)
        record(app, "rolledback")
    }

    func testRestartNeededDownloadsForTheNextRestart() {
        let app = launch("restart")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app, button: "Download")
        XCTAssertTrue(waitForTitle(app, "Downloaded. Finishes on next restart", timeout: 40))
        XCTAssertTrue(app.staticTexts["Restarting herdr closes terminals. Your layout comes back."].exists)
        record(app, "restart")
    }

    func testTooOldShowsTheCommandsToRunOnce() {
        let app = launch("old")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr once on mac-mini"))
        let handoff = app.buttons["Copy command: herdr update --handoff"]
        XCTAssertTrue(handoff.exists)
        handoff.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        record(app, "old")
    }

    /// Review of #566: Try again whose fresh check can't reach the manifest keeps the failed
    /// card and says why, instead of the card vanishing.
    func testTryAgainAfterTheCheckFailsKeepsTheFailedCard() {
        let app = launch("failedcheck")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Update didn't finish", timeout: 30))
        app.buttons["server-update-retry"].tap()
        let reason = app.staticTexts["mac-mini couldn't reach the update server."]
        XCTAssertTrue(reason.waitForExistence(timeout: 15), "Try again should say why nothing was installed")
        XCTAssertTrue(card(app).exists, "the card must stay")
        // The failed-check reason is already visible. Read the retained state now;
        // a second two-second waiter can expire while XCTest retrieves its label.
        XCTAssertEqual(title(app).label, "Update didn't finish", "the failed state must stay")
        record(app, "retry-check-failed")
    }

    /// Review of #566: update_apply drops the connection without starting, while the status file
    /// holds yesterday's failed attempt for the same build. That old outcome must not be shown:
    /// the update never started, so the card offers it again.
    func testALostApplyDoesNotShowAnOlderAttempt() {
        let app = launch("lostapply")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Updating herdr", timeout: 10))
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini", timeout: 30),
                      "the card should offer the update again; title: \(title(app).label)")
        XCTAssertFalse(app.buttons["server-update-retry"].exists)
        XCTAssertTrue(app.buttons["server-update-button"].exists)
        record(app, "lost-apply")
    }

    /// A connection that is not the owner's is refused the check: no badge, no card.
    func testGuestSeesNothing() {
        let app = launch("guest")
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        sleep(3)
        XCTAssertFalse(settingsTabHasBadge(app), "no badge for a non-owner")
        openMachines(app)
        sleep(3)
        XCTAssertFalse(card(app).exists, "no update card for a non-owner")
        record(app, "guest")
    }
}
