import UIKit
import XCTest

/// The guest's pane, against GuestMockTransport (a host that refuses anything a guest may
/// not call and records it). The `guest-forbidden-calls` probe lists those refused calls.
final class GuestPaneTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func forbiddenCalls(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["guest-forbidden-calls"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG forbidden-calls probe should exist")
        return probe.label
    }

    /// Opens the header's ⋯ and taps the entry `item` (titled `label`), waiting for the menu
    /// to present it.
    private func tapMenuItem(_ app: XCUIApplication, _ item: String, label: String, _ what: String) {
        let actions = app.buttons["guest-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "the guest header should offer ⋯")
        actions.tap()
        let entry = app.menuEntry(item, label: label)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), what)
        entry.tap()
    }

    /// Closes an open menu by tapping outside it (the header's title area).
    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// The terminal's `terminal-grid-probe`: "cols=C rows=R font=F fill=X".
    private func grid(_ app: XCUIApplication) -> (cols: Int, font: Double, fill: Double)? {
        let probe = app.descendants(matching: .any)["terminal-grid-probe"]
        guard probe.exists else { return nil }
        var fields: [String: String] = [:]
        for pair in probe.label.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let cols = fields["cols"].flatMap({ Int($0) }),
              let font = fields["font"].flatMap({ Double($0) }),
              let fill = fields["fill"].flatMap({ Double($0) }) else { return nil }
        return (cols, font, fill)
    }

    /// Polls the grid probe until `condition` holds; fails with the last reading otherwise.
    @discardableResult
    private func waitForGrid(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 10,
                             _ condition: ((cols: Int, font: Double, fill: Double)) -> Bool)
        -> (cols: Int, font: Double, fill: Double) {
        var last: (cols: Int, font: Double, fill: Double)?
        let met = poll(timeout, every: 0.25) {
            last = grid(app)
            guard let reading = last else { return false }
            return condition(reading)
        }
        if met, let reading = last { return reading }
        XCTFail("\(what): last grid \(String(describing: last))")
        return last ?? (0, 0, 0)
    }

    /// Reported by the guest: fitted to a desktop-wide terminal, the text was unreadable and
    /// could not be changed. The guest's terminal now proposes the grid that fits its own text
    /// size, and A+ makes that grid narrower; the agent's stream follows, still without the
    /// terminal taking any input.
    func testLargerTextResizesTheAgentsTerminal() {
        let app = XCUIApplication.launched(mock: "guestpane")
        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        // The mock host's pane starts 120 columns wide; the guest's first proposal replaces it
        // with the grid that fits the guest's screen at the default text size.
        let before = waitForGrid(app, "the guest's fit should replace the desktop's 120 columns") {
            $0.cols != 120 && $0.font == 12.5 && $0.fill <= 1.0
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "guest-resize-before")

        // The guest's own text size lives in ⋯ → Text size, where the owner's is.
        tapMenuItem(app, "guest-font-increase", label: "Increase", "the guest pane's ⋯ should offer Increase")
        let after = waitForGrid(app, "A+ should make the agent's grid narrower") {
            $0.cols < before.cols && $0.font > before.font
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "guest-resize-after")

        tapMenuItem(app, "guest-font-decrease", label: "Decrease", "the guest pane's ⋯ should offer Decrease")
        waitForGrid(app, "A− should widen the agent's grid again") {
            $0.cols > after.cols && $0.font < after.font
        }
        XCTAssertEqual(app.keyboards.count, 0, "resizing must not raise a keyboard")
        XCTAssertEqual(forbiddenCalls(app), "", "resizing is a call a guest may make")
    }

    /// A guest on iPad re-proposes when the pane's width changes, as the owner's pane does.
    func testRotationReproposesTheGuestsGrid() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPhone is portrait-only; rotation re-proposes on iPad")
        }
        let app = XCUIApplication.launched(mock: "guestpane")
        let portrait = waitForGrid(app, "the guest's first fit") { $0.cols != 120 }
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForGrid(app, "landscape should propose a wider grid") { $0.cols > portrait.cols }
        attach(app, "guest-resize-landscape")
    }

    /// A host older than guest resizing refuses `pane.set_pty_size` with `guest_forbidden`. The
    /// pane keeps today's fit-to-width view, drops the size controls, and never asks again:
    /// not on a retry, not on a relayout.
    func testOldHostKeepsTheFitToWidthViewAndStopsProposing() {
        let app = XCUIApplication.launched(mock: "guestoldhost")
        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["View-only · this host doesn't support guest resizing"]
            .waitForExistence(timeout: 10), "the pane should say why the size can't change")
        // ⋯ still opens (Copy), but holds no Text size on an older host.
        let actions = app.buttons["guest-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        XCTAssertTrue(app.buttons["Copy screen"].waitForExistence(timeout: 5), "the ⋯ menu should open")
        XCTAssertFalse(app.menuEntry("guest-font-increase", label: "Increase").exists, "no size controls on an older host")
        XCTAssertFalse(app.menuEntry("guest-font-decrease", label: "Decrease").exists, "no size controls on an older host")
        dismissMenu(app)
        // Fitted: the widest whole-pixel cell that keeps all 120 columns inside the width.
        let fitsWidth = { (reading: (cols: Int, font: Double, fill: Double)) -> Bool in
            let slack = Double(reading.cols) / Double(UIScreen.main.scale * terminal.frame.width)
            // The probe prints `fill` to two decimals: allow its half-step of rounding.
            return reading.cols == 120 && reading.fill <= 1.0 && reading.fill > 1.0 - slack - 0.005
        }
        waitForGrid(app, "the host's 120 columns should fill the width", fitsWidth)
        // Anything that would re-propose: a rotation on iPad, a keyboard raising and dropping.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCUIDevice.shared.orientation = .portrait
        let input = app.textViews["guest-composer-input"]
        input.tap()
        Thread.sleep(forTimeInterval: 1)
        if app.buttons["guest-keyboard-button"].exists { app.buttons["guest-keyboard-button"].tap() }
        Thread.sleep(forTimeInterval: 3)
        waitForGrid(app, "the fallback should still fit the width", fitsWidth)
        attach(app, "guest-resize-old-host")
        XCTAssertEqual(forbiddenCalls(app), "pane.set_pty_size",
                       "one refusal, then no further set_pty_size calls")
    }

    /// Watching never sends anything a guest may not send: no keyboard from the terminal, no
    /// quick keys while the agent isn't asking anything, and a sent message goes out as a prompt.
    func testTerminalIsViewOnly() {
        let app = XCUIApplication.launched(mock: "guestpane")

        XCTAssertTrue(app.staticTexts["WORKING"].waitForExistence(timeout: 10),
                      "the running agent's status pill should render")
        XCTAssertTrue(app.staticTexts["Shared by Jerry"].exists)
        XCTAssertTrue(app.staticTexts["Message llm-opt as plotarmordev"].exists,
                      "the composer should name the agent and the guest")
        XCTAssertTrue(app.staticTexts["guest-view-only-note"].exists)
        XCTAssertFalse(app.staticTexts["jarvis"].exists, "an agent not shared with the guest must not show")

        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        // Let the stream seed and the fit-to-width settle before the screenshot and taps.
        Thread.sleep(forTimeInterval: 2)
        attach(app, "guest-pane")

        for _ in 0..<3 {
            terminal.tap()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertEqual(app.keyboards.count, 0, "tapping the terminal must not raise a keyboard")
        XCTAssertFalse(app.buttons["terminal-ctrl"].exists, "a guest pane has no quick keys")
        XCTAssertFalse(app.descendants(matching: .any)["guest-menu-keys"].exists,
                       "no menu keys while the agent isn't asking anything")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(forbiddenCalls(app), "", "watching must not call anything a guest may not call")

        let input = app.textViews["guest-composer-input"]
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("rerun it on Q4 too")
        let send = app.buttons["guest-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "typing should offer Send")
        send.tap()
        XCTAssertTrue(app.staticTexts["Message llm-opt as plotarmordev"].waitForExistence(timeout: 5),
                      "a delivered message clears the composer")
        XCTAssertFalse(app.descendants(matching: .any)["guest-note"].exists, "the send should not fail")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(forbiddenCalls(app), "", "sending must go out as agent.prompt only")
    }

    /// Reported on TestFlight 176: with the keyboard up, the guest composer (attach, mic,
    /// send) had no way to put it away, and the view-only terminal takes no taps. It must
    /// offer the standard composer's collapse button, and tapping it hides the keyboard.
    func testKeyboardCanBeDismissedFromTheComposer() throws {
        let app = XCUIApplication.launched(mock: "guestpane")
        let input = app.textViews["guest-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let collapse = app.buttons["guest-keyboard-button"]
        XCTAssertFalse(collapse.exists, "no collapse button while the keyboard is down")

        input.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no full software keyboard on this destination; nothing to dismiss")
        }
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "a visible software keyboard must be dismissible")
        XCTAssertTrue(app.buttons["guest-attach-button"].exists, "the collapse button sits beside attach, not over it")
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "guest-pane-keyboard")

        collapse.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the collapse button puts the keyboard away")
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5), "the button goes with the keyboard")
    }

    /// A guest scrolls back past what streamed in since connecting: like the owner's pane, the
    /// guest's backfills the agent's scrollback with `agent.read`, and a swipe down on the
    /// terminal brings those older rows into view. The mock's stream paints only the current
    /// screen, so an `earlier NNN` row at the top can only have come from the backfill.
    func testSwipeRevealsScrollbackFromBeforeTheGuestConnected() {
        let app = XCUIApplication.launched(mock: "guestpane")

        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let topRow = app.descendants(matching: .any)["terminal-top-row-probe"]
        XCTAssertTrue(topRow.waitForExistence(timeout: 10),
                      "the DEBUG top-row probe should publish once the stream seeds")
        // Let the backfill, the seed and the fit-to-width settle.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(topRow.label.contains("earlier"),
                       "the pane should open on the live screen, not in history: \(topRow.label)")

        let high = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "guest-scrollback")
        XCTAssertTrue(topRow.label.contains("earlier"),
                      "a swipe down should reveal the backfilled scrollback: \(topRow.label)")
        XCTAssertEqual(forbiddenCalls(app), "", "the backfill is an allowed agent.read")
    }

    /// With the agent out of the foreground the host refuses the guest: the pane says so and
    /// the composer can't be used.
    func testPausedAgentDisablesTheComposer() {
        let app = XCUIApplication.launched(mock: "guestpaused")

        XCTAssertTrue(app.buttons["guest-attach-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["guest-attach-button"].isEnabled, "attach is disabled while paused")
        XCTAssertFalse(app.buttons["guest-mic-button"].isEnabled, "dictation is disabled while paused")

        app.textViews["guest-composer-input"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(app.keyboards.count, 0, "the paused composer must not take input")
        attach(app, "guest-paused")
    }

    /// A blocked agent's menu (a plan approval, a permission prompt) is the guest's to
    /// answer: the owner's menu keys show under the terminal and go out as `pane.send_keys`,
    /// and nothing types text.
    func testBlockedAgentOffersTheMenuKeys() {
        let app = XCUIApplication.launched(mock: "guestblocked")

        XCTAssertTrue(app.staticTexts["llm-opt is asking a question · answer with the keys below"]
            .waitForExistence(timeout: 10), "the question banner should render")
        XCTAssertTrue(app.staticTexts["NEEDS YOU"].exists)
        XCTAssertFalse(app.staticTexts["NEEDS JERRY"].exists, "the guest can answer, so it doesn't wait for Jerry")
        XCTAssertTrue(app.descendants(matching: .any)["guest-menu-keys"].exists, "the menu keys should show")
        XCTAssertTrue(app.textViews["guest-composer-input"].exists, "the guest can still send a message")
        Thread.sleep(forTimeInterval: 2)
        attach(app, "guest-blocked")

        app.buttons["Down"].tap()
        app.buttons["Enter"].tap()
        let hostCalls = app.descendants(matching: .any)["guest-host-calls"]
        XCTAssertTrue(poll(6, every: 0.3) { hostCalls.label.contains("pane.send_keys:Down;pane.send_keys:Enter") },
                      "the keys reach the host in order as pane.send_keys: \(hostCalls.label)")
        XCTAssertEqual(forbiddenCalls(app), "", "menu keys are allowed while the agent is blocked")
        XCTAssertFalse(app.descendants(matching: .any)["guest-note"].exists, "the keys should not fail")
    }

    /// A host older than guest answers refuses the guest's menu key: back to waiting for the
    /// owner, with the banner and pill that say so and no keys.
    func testBlockedAgentOnAnOlderHostWaitsForTheOwner() {
        let app = XCUIApplication.launched(mock: "guestblocked", environment: ["HERDR_MOCK_GUEST_OWNER_ANSWERS": "1"])

        let keys = app.descendants(matching: .any)["guest-menu-keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10), "the keys show until the host refuses one")
        app.buttons["Enter"].tap()
        XCTAssertTrue(app.staticTexts["llm-opt is asking a question only Jerry can answer"]
            .waitForExistence(timeout: 10), "the owner banner should render")
        XCTAssertTrue(app.staticTexts["NEEDS JERRY"].exists)
        XCTAssertFalse(keys.exists, "no menu keys once the host keeps answers for the owner")
        XCTAssertFalse(app.descendants(matching: .any)["guest-note"].exists, "the refusal is not an error")
        attach(app, "guest-blocked-owner-answers")
    }

    // MARK: Header

    /// The owner's agent header for a guest: back, Find, Reconnect and ⋯ (Copy screen, Copy
    /// recent output, Text size, notifications). The owner-only Share and Close are absent,
    /// and so is the quick-key bar; the status pill and "Shared by" chip stay under it.
    func testHeaderOffersTheGuestsButtonsAndNoOwnerOnlyActions() {
        let app = XCUIApplication.launched(mock: "guestpane", environment: ["HERDR_MOCK_STILL": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["guest-terminal"].waitForExistence(timeout: 10))
        for id in ["guest-back", "guest-find", "guest-refresh", "guest-actions"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "the header should offer \(id)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["guest-status-pill"].exists, "the status pill stays")
        XCTAssertTrue(app.staticTexts["Shared by Jerry"].exists, "the Shared by chip stays")
        XCTAssertFalse(app.descendants(matching: .any)["guest-menu-keys"].exists,
                       "a guest pane has no quick keys while the agent isn't asking anything")
        XCTAssertFalse(app.buttons["guest-font-increase"].exists, "A+ moved into the ⋯ menu")

        app.buttons["guest-actions"].tap()
        for label in ["Copy screen", "Copy recent output", "Increase", "Decrease", "Reset"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "⋯ should offer \(label)")
        }
        XCTAssertFalse(app.buttons["Share with someone"].exists, "only the owner can share")
        XCTAssertFalse(app.buttons["terminal-share"].exists, "only the owner can share")
        XCTAssertFalse(app.buttons["Close agent"].exists, "only the owner can close the agent")
        attach(app, "guest-actions-menu")
        app.buttons["Copy screen"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(forbiddenCalls(app), "", "Copy screen is an allowed agent.read")
    }

    /// Reconnect and refresh opens a new stream (`pane.stream`) and re-reads the agent, both
    /// calls a guest may make.
    func testRefreshReconnectsTheStream() {
        let app = XCUIApplication.launched(mock: "guestpane", environment: ["HERDR_MOCK_STILL": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["guest-terminal"].waitForExistence(timeout: 10))
        let opens = app.descendants(matching: .any)["guest-stream-opens"]
        XCTAssertTrue(poll(10, every: 0.25) { (Int(opens.label) ?? 0) >= 1 }, "the pane should open a stream")
        Thread.sleep(forTimeInterval: 2)
        let before = Int(opens.label) ?? 0
        app.buttons["guest-refresh"].tap()
        XCTAssertTrue(poll(10, every: 0.25) { (Int(opens.label) ?? 0) > before },
                      "Refresh should open a new stream (was \(before), now \(opens.label))")
        XCTAssertTrue(app.descendants(matching: .any)["guest-terminal"].waitForExistence(timeout: 5))
        XCTAssertEqual(forbiddenCalls(app), "", "a reconnect calls only what a guest may")
    }

    /// The owner's jump-to-latest button: it appears once the guest scrolls up into history,
    /// and a tap returns the terminal to its newest output (and the button goes).
    func testLatestPillAppearsInHistoryAndReturnsToTheTail() {
        let app = XCUIApplication.launched(mock: "guestpane", environment: ["HERDR_MOCK_STILL": "1"])
        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let topRow = app.descendants(matching: .any)["terminal-top-row-probe"]
        XCTAssertTrue(topRow.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        let latest = app.buttons["guest-latest"]
        XCTAssertFalse(latest.exists, "no pill at the tail")
        let live = topRow.label

        let high = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "scrolled into history, the Latest pill should show")
        XCTAssertNotEqual(topRow.label, live, "the swipe should have moved into history")
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, "guest-latest-pill")

        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5), "back at the tail, the pill goes")
        XCTAssertTrue(poll(5, every: 0.25) { topRow.label == live },
                      "the tap should return to the live screen: \(topRow.label)")
        XCTAssertEqual(forbiddenCalls(app), "", "jumping to the tail sends nothing")
    }
}
