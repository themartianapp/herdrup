import XCTest
import UIKit

/// Shared-surface receipts. The probe is populated only by actual CoreText draws;
/// screenshots retain the independent visual evidence in each result bundle.
class TerminalInteractionTestCase: XCTestCase {
    var app: XCUIApplication!
    override func setUp() { super.setUp(); continueAfterFailure = false }
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        super.tearDown()
    }

    /// Which fixture is mounted. The control fixture paints only a prompt line, so a
    /// painted-prompt assertion is meaningful there; the resize fixture seeds a hundred
    /// history records, where the prompt is legitimately off-viewport.
    private(set) var fixtureMode = ""

    func launch(_ mode: String, environment: [String: String] = [:]) {
        fixtureMode = mode
        app = XCUIApplication.forUITest()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mode
        app.launch()
        XCTAssertTrue(app.staticTexts["terminal-interaction-probe"].exists(within: 15))
        wait {
            ($0["opens"] as? Int) == 1 && ($0["requests"] as? Int ?? 0) > 0
                && ($0["covered"] as? Bool) == false && $0["top"] != nil
        }
    }

    func probe() -> [String: Any] {
        let label = app.staticTexts["terminal-interaction-probe"].label
        return (try? JSONSerialization.jsonObject(with: Data(label.utf8))) as? [String: Any] ?? [:]
    }

    @discardableResult
    func wait(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
              _ condition: @escaping ([String: Any]) -> Bool) -> [String: Any] {
        XCTAssertTrue(holds(within: timeout, condition),
                      "Last painted receipt: \(probe())", file: file, line: line)
        return probe()
    }

    /// Whether the probe satisfies `condition` within `timeout`, without failing the test.
    /// Uses the shared `poll` (#449), so a probe read started before the deadline is still
    /// judged: on a slow hosted runner one probe query took 14.3 s (CI 39150458634).
    func holds(within timeout: TimeInterval, _ condition: @escaping ([String: Any]) -> Bool) -> Bool {
        poll(timeout, every: 0.2) { condition(probe()) }
    }

    /// Check geometry before hit testing: clipped quick keys can raise
    /// "Activation point invalid" instead of returning false from `isHittable`.
    /// Menus additionally require an enabled, hittable match. Retained panes can
    /// publish identical frames, so waiting on the first geometric match alone
    /// can wait forever on the hidden copy while ignoring the visible control.
    func onscreen(_ identifier: String, timeout: TimeInterval = 10,
                  requiringHittable: Bool = false) -> XCUIElement? {
        // Identifier OR label: production keycaps carry only an accessibility label.
        let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       identifier, identifier))
        var found: XCUIElement?
        _ = poll(timeout, every: 0) {
            let visible = app.frame.insetBy(dx: -1, dy: -1)
            for index in 0..<matches.count {
                let candidate = matches.element(boundBy: index)
                let frame = candidate.frame
                guard frame.width > 0, frame.height > 0, visible.contains(frame) else { continue }
                if requiringHittable && (!candidate.isEnabled || !candidate.isHittable) { continue }
                found = candidate
                return true
            }
            return false
        }
        return found
    }

    /// The production control bar is a HORIZONTAL SCROLL VIEW, and on a 402 pt phone
    /// the ctrl cap sits beyond its right edge: eight cases failed with "activation
    /// point invalid" for tapping an off-viewport element, and asking `isHittable`
    /// about such an element RAISES that same error instead of answering false. So
    /// scroll the bar the way a reader does and judge reachability by frame geometry.
    func cap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if let ready = onscreen(identifier, timeout: 5) { return ready }
        for _ in 0..<6 {
            scrollControlBar()
            if let ready = onscreen(identifier, timeout: 2) { return ready }
        }
        XCTFail("control cap \(identifier) never scrolled into the viewport. \(elementDump())",
                file: file, line: line)
        return app.buttons[identifier].firstMatch
    }

    /// Drags the control bar ITSELF, in the leftmost cap's OWN coordinate space.
    ///
    /// `swipeLeft()` on a cap delivers the gesture to that button, so the bar never
    /// moved. Normalized window coordinates were no better: the window query is not
    /// guaranteed to be the main window, and a bad reference frame silently aims the
    /// drag at nothing. Offsets past 1.0 are multiples of the anchor's own frame, so
    /// this stays inside the bar's row by construction.
    func scrollControlBar() {
        let anchor = app.buttons["Escape"].firstMatch
        guard anchor.exists else { return }
        anchor.coordinate(withNormalizedOffset: CGVector(dx: 6.0, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        // Let any deceleration finish: the caller judges reachability by frame geometry, and
        // a cap read while the bar still glides can be tapped where it no longer is. Three
        // equal frames 0.15 s apart (`waitForStable`): a glide spans at least that.
        _ = waitForStable(timeout: 2, interval: 0.15, matches: 2) { anchor.frame }
    }


    /// Taps the terminal once any keyboard transition has come to rest, then waits for focus.
    ///
    /// A TAP DURING THE KEYBOARD'S HIDE SWEEP IS LOST. testExplicitKeycapAndKeyboardDismissalDisarm
    /// taps here right after "Collapse keyboard": with XCTest's one-second existence wait in
    /// front of it the tap landed 2.2 s after the collapse (#694's log) and focused; with the
    /// polling wait it landed 0.47 s after, inside the 441 ms keyboard-hide resize the receipt
    /// records, and the terminal never took focus (#716, runs j_811c0a13 and j_edd06db1). So
    /// the tap waits for what that second used to cover: the software keyboard's frame (or
    /// its absence) unchanged over 0.3 s, and the pane uncovered with its grid held for 0.5 s
    /// by the app's own measure (`stableMs`, longer than that 441 ms sweep).
    func focusTerminal() {
        XCTAssertTrue(terminal.exists(within: 5))
        let keyboard = app.keyboards.firstMatch
        _ = waitForStable(timeout: 5, interval: 0.15, matches: 2) { keyboard.exists ? keyboard.frame : .zero }
        wait { ($0["covered"] as? Bool) == false && ($0["stableMs"] as? Int ?? 0) >= 500 }
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        wait { ($0["focused"] as? Bool) == true }
    }

    /// Types into the terminal only once it actually owns the keyboard. A tap on a
    /// control cap or a return from dictation can leave the responder elsewhere for a
    /// beat, and a keystroke sent then goes nowhere — which reads as "the modifier
    /// leaked" when nothing was ever delivered.
    func typeDirect(_ text: String) {
        // RESTORE THE RESPONDER FIRST IF IT MOVED. Tapping a control cap — and the
        // drag that scrolls the bar to reach one — can take the responder off the
        // terminal, and then this wait simply never came true: the whole-suite iPhone
        // round failed here while the same case passed in isolation, and the warm
        // rerun passed, which is the signature of a lost responder rather than a
        // product defect.
        if (probe()["focused"] as? Bool) != true {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        }
        wait { ($0["focused"] as? Bool) == true }
        // Software keys must appear when no hardware keyboard is attached,
        // regardless of phone or tablet idiom. Otherwise a focused terminal can
        // silently drop the keystroke after a responder transition.
        if probe()["physicalKeyboard"] as? Bool != true, !app.keyboards.element.exists {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            XCTAssertTrue(app.keyboards.element.exists(within: 10),
                          "direct input needs the software keyboard. \(elementDump())")
        }
        app.typeText(text)
    }

    /// Direct input requires the terminal responder and either the attached
    /// hardware keyboard or a visible software keyboard on any device idiom.
    var canTypeDirectly: Bool {
        probe()["focused"] as? Bool == true &&
            (probe()["physicalKeyboard"] as? Bool == true || app.keyboards.element.exists)
    }

    /// Every button with its identifier, label and frame. Attached to a reachability
    /// failure so the next run explains itself instead of costing another CI round.
    func elementDump() -> String {
        let rows = app.buttons.allElementsBoundByIndex.map {
            "\($0.identifier.isEmpty ? "-" : $0.identifier)|\($0.label)|\($0.frame)"
        }
        return "app=\(app.frame) buttons=[" + rows.joined(separator: " ") + "]"
    }

    /// Text fields with their frames and enabled state, for a focus failure.
    func fieldDump() -> String {
        let rows = app.textFields.allElementsBoundByIndex.map {
            "\($0.identifier.isEmpty ? "-" : $0.identifier)|\($0.placeholderValue ?? "-")|\($0.frame)|enabled=\($0.isEnabled)"
        }
        return "textFields=[" + rows.joined(separator: " ") + "] keyboards=\(app.keyboards.count)"
    }

    /// Fixture commands are plain buttons in the harness bar, so one laid-out tap
    /// reaches them — no popover to present and nothing to scroll. Reaching is not
    /// landing, though: on a loaded host a `natural` tap took 23 s to synthesize and
    /// never registered, so the pane stayed on the fixture grid and the later font step
    /// could not change its columns. `landed` names the harness state the command sets.
    /// When it is given, a tap that did not produce that state is retried once, and
    /// the state is checked again before the retry so a slow tap is never sent twice.
    func command(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                 until landed: (([String: Any]) -> Bool)? = nil) {
        for attempt in 0..<2 {
            guard let item = onscreen("fixture-" + name) else {
                XCTFail("Fixture command \(name) never became usable", file: file, line: line)
                return
            }
            if attempt > 0, let landed, landed(probe()) { return }
            item.tap()
            guard let landed else { return }
            if holds(within: 5, landed) { return }
        }
        XCTFail("Fixture command \(name) never took effect. Last painted receipt: \(probe())",
                file: file, line: line)
    }

    /// `landed` for a grid fixture command: the harness recorded that fit as the pane's.
    func fixtureFit(_ grid: String) -> ([String: Any]) -> Bool {
        { $0["fixtureFit"] as? String == grid }
    }

    /// Opens a real menu, taps one of its items, and waits until `landed` reports that
    /// the tap took effect.
    ///
    /// Two CI failures shaped this. In one, the item was found and tapped and nothing
    /// happened: the font never changed, so the tap never reached the menu's action.
    /// In the other, on a loaded runner, just finding the item took 7 s, past the old
    /// 5 s budget, and the helper then dismissed the menu the item was sitting in. So
    /// the menu opens only once the pane has settled, the lookup gets a generous budget,
    /// nothing is dismissed, and the effect is checked rather than the tap. The one retry
    /// covers a dropped tap. `landed` is checked again before reopening, so a slow first
    /// tap is never applied twice.
    func menuItem(_ menu: String, _ item: String,
                  file: StaticString = #filePath, line: UInt = #line,
                  until landed: @escaping ([String: Any]) -> Bool) {
        for _ in 0..<2 {
            settled()
            if landed(probe()) { return }
            guard let control = onscreen(menu, timeout: 15, requiringHittable: true) else { break }
            control.tap()
            // An item that has not been presented sits in the tree with an infinite frame,
            // so this waits for actual geometry rather than tapping into nothing.
            guard let entry = onscreen(item, timeout: 20) else { continue }
            entry.tap()
            if holds(within: 5, landed) { return }
        }
        XCTFail("menu \(menu) never applied \(item). Last painted receipt: \(probe()). \(elementDump())",
                file: file, line: line)
    }

    /// The pane shows the asked-for grid, uncovered and completely drawn, and its grid,
    /// cover and completeness have not changed for 0.4 s. The app measures that quiet time
    /// (`stableMs`), so ONE probe read decides: timing it here between two reads failed on
    /// a CI runner where a single accessibility read took 12 s and the 15 s wait got only one.
    func settled(cols: Int? = nil, rows: Int? = nil) {
        wait {
            ($0["covered"] as? Bool) == false && ($0["complete"] as? Bool) == true
                && (cols == nil || ($0["cols"] as? Int) == cols)
                && (rows == nil || ($0["rows"] as? Int) == rows)
                && ($0["stableMs"] as? Int ?? 0) >= 400
        }
    }

    func attach(_ name: String) {
        attach(app, name)
    }

    func anchor(file: StaticString = #filePath, line: UInt = #line) {
        let state = wait { ($0["markerRow"] as? Int) == 0 && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(state["markerText"] as? String, "ANCHOR020", file: file, line: line)
        XCTAssertGreaterThanOrEqual(state["markerColumn"] as? Int ?? -1, 0, file: file, line: line)
        XCTAssertEqual(state["tail"] as? Bool, false, file: file, line: line)
    }

    var terminal: XCUIElement { app.terminalSurface }
}

final class TerminalResizeTests: TerminalInteractionTestCase {
    func testBoxedHistoryPansWithoutReflowOrFontShrinking() throws {
        launch("resize", environment: ["HERDR_HISTORY_BOX": "1"])
        command("natural")
        command("history")
        let before = wait { ($0["top"] as? String ?? "").contains("ANCHOR020") }
        let topRow = try XCTUnwrap(before["topPixelRow"] as? Int)
        let font = try XCTUnwrap(before["fontPoints"] as? Double)
        let contentWidth = try XCTUnwrap(before["contentWidth"] as? Double)
        let viewportWidth = try XCTUnwrap(before["viewportWidth"] as? Double)
        if contentWidth > viewportWidth {
            let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4))
            let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let panned = wait { ($0["top"] as? String ?? "").contains("╮") }
        if contentWidth > viewportWidth {
            XCTAssertGreaterThan(panned["leftPixelColumn"] as? Int ?? 0, 0)
        }
        XCTAssertEqual(panned["topPixelRow"] as? Int, topRow)
        XCTAssertEqual(panned["fontPoints"] as? Double, font)
        XCTAssertTrue((panned["visible"] as? String ?? "").contains("RIGHTEND │"))
        attach("original-width-history-right-edge")

        // Establish a different local target before asking the wider-viewer host.
        // A natural window can already fit 80x24, so repeating that fit is a no-op.
        command("80x24", until: fixtureFit("80x24")); settled(cols: 80, rows: 24)
        command("wider")
        command("120x24", until: fixtureFit("120x24"))
        let shared = wait { ($0["cols"] as? Int) == 140 && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(shared["fontPoints"] as? Double, font)
        XCTAssertGreaterThan(try XCTUnwrap(shared["contentWidth"] as? Double),
                             try XCTUnwrap(shared["viewportWidth"] as? Double))
        XCTAssertEqual(shared["topPixelRow"] as? Int, topRow)
        attach("shared-desktop-grid-readable-font")
    }

    // Three painted cycles here; the vendored core suite drives ten inside a long
    // wrapped line, where a cycle costs microseconds instead of two app launches'
    // worth of accessibility round trips.
    func testLogicalHistorySurvivesWidthCyclesAndHeightChange() {
        launch("resize")
        command("history"); anchor()
        let original = probe()["top"] as? String
        attach("history-before-80")
        for cycle in 0..<3 {
            command("120x24", until: fixtureFit("120x24")); settled(cols: 120, rows: 24); anchor()
            command("80x24", until: fixtureFit("80x24")); settled(cols: 80, rows: 24); anchor()
            XCTAssertEqual(probe()["top"] as? String, original, "Cycle \(cycle) drifted to another logical cell")
        }
        command("80x32", until: fixtureFit("80x32")); settled(cols: 80, rows: 32); anchor()
        command("80x24", until: fixtureFit("80x24")); settled(cols: 80, rows: 24); anchor()
        XCTAssertEqual(probe()["top"] as? String, original)
        XCTAssertEqual(probe()["opens"] as? Int, 1, "A resize must not replay/reset the stream")
        attach("history-after-cycles-and-height")
    }

    func testRealSidebarOrientationAndFontPreserveHistory() throws {
        launch("resize")
        guard probe()["iPad"] as? Bool == true else {
            throw XCTSkip("Actual sidebar/orientation receipt runs on the iPad destination; iPhone uses exact-grid sweeps")
        }
        XCTAssertNotNil(onscreen("terminal-sidebar-toggle", timeout: 5),
                        "The iPad receipt must exercise the actual sidebar")
        command("natural") { $0["naturalFit"] as? Bool == true }; settled()
        command("history"); anchor()
        let opens = probe()["opens"] as? Int
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            onscreen("terminal-sidebar-toggle")?.tap()
            settled(); anchor(); attach("sidebar-\(orientation.rawValue)")
            XCUIDevice.shared.orientation = orientation
            settled(); anchor(); attach("orientation-\(orientation.rawValue)")
            onscreen("terminal-sidebar-toggle")?.tap()
            settled(); anchor()
        }
        let originalColumns = try XCTUnwrap(probe()["cols"] as? Int)
        let originalFont = try XCTUnwrap(probe()["fontPoints"] as? Double)
        // By title: on iOS 27 the Text size entries lose their identifiers (see `menuEntry`),
        // and `onscreen` matches an identifier or a label.
        menuItem("terminal-actions", "Increase") {
            ($0["fontPoints"] as? Double ?? 0) > originalFont
        }
        wait { state in
            guard let columns = state["cols"] as? Int else { return false }
            return columns < originalColumns
        }
        settled(); anchor(); attach("larger-font-history")
        menuItem("terminal-actions", "Decrease") {
            ($0["fontPoints"] as? Double) == originalFont
        }
        settled(cols: originalColumns); anchor()
        XCTAssertEqual(probe()["opens"] as? Int, opens)
    }

    func testReturningToEarlierTargetStillUsesLatestQuietWindow() {
        launch("resize")
        command("history"); anchor()
        let before = probe()["requests"] as? Int ?? 0
        command("bounce")
        let until = Date().addingTimeInterval(0.6)
        repeat {
            XCTAssertEqual(probe()["markerRow"] as? Int, 0,
                           "The painted history marker moved during the geometry sweep")
        } while Date() < until
        settled(cols: 120); anchor()
        XCTAssertEqual(probe()["requests"] as? Int, before + 1)
        attach("bounce-coalesced-without-intermediate-reflow")
    }

    func testStationaryTargetAndSupersededInflightRequests() {
        launch("resize")
        let initial = probe()["requests"] as? Int ?? 0
        command("120x24", until: fixtureFit("120x24")); settled(cols: 120)
        XCTAssertEqual(probe()["requests"] as? Int, initial + 1)
        command("delayed")
        command("80x24")
        wait { ($0["requests"] as? Int ?? 0) > initial + 1 }
        command("120x24")
        settled(cols: 120)
        wait { ($0["requests"] as? Int ?? 0) == initial + 3 }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("superseded-request-final-grid")
    }

    func testOrderedGeometryResponseAndWiderViewerDoNotReconnect() {
        launch("resize")
        command("history"); anchor()
        for scenario in ["beforeMarker", "afterResponse", "delayed", "wider"] {
            command(scenario)
            command("120x24")
            settled(cols: scenario == "wider" ? 140 : 120)
            anchor(); attach("ordered-\(scenario)")
            XCTAssertEqual(probe()["opens"] as? Int, 1)
            command("quiet")
            command("80x24", until: fixtureFit("80x24")); settled(cols: 80); anchor()
        }
        command("server"); settled(cols: 120); anchor()
        attach("unsolicited-authoritative-resize")
    }

    func testSplitSynchronizedAlternateFrameStaysHidden() {
        launch("resize")
        command("history"); anchor()
        command("synchronized")
        command("120x24")
        // Sample the actual presentation across the fixture's split redraw, retaining
        // transition screenshots. A hidden incomplete backing draw may occur, but it
        // must never be published as live. Fixed sampling: a spin loop attached dozens
        // of full screenshots for one assertion.
        for index in 0..<6 {
            let state = probe()
            XCTAssertFalse((state["visible"] as? String ?? "").contains("INCOMPLETE"))
            attach("split-frame-\(index)")
            // Kept: the measurement — fixed samples spread across the split redraw.
            if index < 5 { Thread.sleep(forTimeInterval: 0.15) }
        }
        settled(cols: 120); anchor()
        XCTAssertEqual(probe()["alternate"] as? Bool, false)
        attach("normal-buffer-restored")
    }

    func testFailureAndNoRedrawReleaseCoverAtAuthoritativeGrid() {
        launch("resize")
        command("history"); anchor()
        command("failure"); command("120x24")
        wait { ($0["failures"] as? Int ?? 0) > 0 }
        settled(cols: 80); anchor()
        XCTAssertEqual(probe()["effectiveCols"] as? Int, 80)
        attach("failed-request-real-grid-no-frozen-cover")
        command("quiet"); command("80x32")
        settled(cols: 80, rows: 32); anchor()
        attach("no-output-height-resize-revealed")
    }

    func testLiveTailBusyOutputAndExplicitReturnToTail() {
        launch("resize")
        command("busy")
        wait { ($0["appended"] as? Int ?? 0) >= 3 }
        command("120x24", until: fixtureFit("120x24")); settled(cols: 120)
        wait { ($0["tail"] as? Bool) == true && ($0["visible"] as? String ?? "").contains("APPENDED") }
        command("history"); anchor()
        command("80x24", until: fixtureFit("80x24")); settled(cols: 80); anchor()
        command("tail")
        wait { ($0["tail"] as? Bool) == true && ($0["visible"] as? String ?? "").contains("fixture>") }
        command("quiet")
        let receipt = wait {
            ($0["appendedRecords"] as? [Int])?.last == ($0["appended"] as? Int)
        }
        let appended = receipt["appended"] as? Int ?? 0
        XCTAssertEqual(receipt["records"] as? [Int], Array(0..<100), "Seed records were lost or replayed")
        XCTAssertEqual(receipt["appendedRecords"] as? [Int], Array(1...max(1, appended)),
                       "Live records were duplicated, reordered or dropped")
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("busy-output-tail-restored")
    }

    func testMountedPaneSwitchResetAndCloseDuringResize() {
        launch("resize")
        wait { ($0["mounted"] as? Int) == 2 }
        command("history"); anchor()
        command("delayed"); command("120x24")
        command("switch")
        wait { ($0["pane"] as? String) == "ix:b" && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        settled(cols: 120); anchor()
        command("reset")
        wait { ($0["epoch"] as? Int) == 8 && ($0["covered"] as? Bool) == false }
        // Reset replaces the visible seed, not the reader's decision to follow.
        // Returning explicitly must expose the new epoch rather than an old cover.
        command("tail")
        wait { ($0["visible"] as? String ?? "").contains("RESET-EPOCH8") }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        command("80x24"); command("close")
        wait { ($0["mounted"] as? Int) == 1 && ($0["pane"] as? String) == "ix:b" && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("close-inflight-surviving-pane")
    }

    /// A control-bar keycap is input too, and it lives outside the terminal surface.
    ///
    /// Review found this at d750df7: keyCap/rawCap only cleared the modifier and sent,
    /// so during a delayed resize their bytes reached the agent while the retained
    /// frame stayed up. An input whose effect is hidden reads as ignored and invites a
    /// second one, which is the whole hazard the cover exists to avoid.
    func testExternalKeycapDuringCoveredResizeTakesControlOnce() {
        launch("resize")
        command("history"); anchor()
        let before = probe()["previous"] as? Int ?? 0
        // Reach the cap FIRST, so the scroll that reveals it is not part of the timed
        // window below.
        let keycap = cap("^P")
        command("delayed"); command("120x24")
        // THE COVER MUST BE UP BEFORE THE TAP, or this case would pass on a build with
        // no cancellation at all: the quiet/deadline path removes the frame within
        // about a second anyway. Review flagged exactly that.
        // TIGHT POLLING, NOT A PREDICATE EXPECTATION. XCTNSPredicateExpectation
        // re-evaluates about once a second, and this cover is deliberately short-lived,
        // so the wait could miss it entirely and report a cover that never appeared.
        let sawCover = poll(4, every: 0) { (probe()["covered"] as? Bool) == true }
        XCTAssertTrue(sawCover, "no retained frame appeared for this resize: \(probe())")
        keycap.tap()
        // And it must go NOW, not by the deadline. The deadline is 140 ms of settle
        // plus one second; a 600 ms ceiling can only be met by the input cancelling it.
        var cleared = false
        let start = Date()
        while Date().timeIntervalSince(start) < 0.6 {
            if (probe()["covered"] as? Bool) == false { cleared = true; break }
        }
        XCTAssertTrue(cleared, "the keycap did not cancel the retained frame: \(probe())")
        wait { ($0["previous"] as? Int) == before + 1 }
        attach("keycap-cancels-cover")
        settled(cols: 120)
        XCTAssertEqual(probe()["previous"] as? Int, before + 1,
                       "one keycap tap must deliver exactly one input")
        XCTAssertEqual(probe()["opens"] as? Int, 1)
    }

    func testDraggingDuringCoveredResizeTakesControl() {
        launch("resize")
        command("history"); anchor()
        command("delayed"); command("120x24")
        // Three drags with a beat between them, the gesture ScrollTests already proves
        // moves this terminal; one flick can land inside the scroll view's slop.
        for _ in 0..<3 {
            let from = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35))
            let to = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: to)
            // Kept: the beat between drags, so each lands as its own gesture.
            Thread.sleep(forTimeInterval: 0.2)
        }
        wait { ($0["covered"] as? Bool) == false && ($0["markerRow"] as? Int) != 0 }
        settled(cols: 120)
        XCTAssertNotEqual(probe()["markerRow"] as? Int, 0, "Late reveal restored the stale history anchor")
        attach("gesture-cancels-covered-resize")
    }

    // MARK: width-claim lifecycle

    /// One pane's width-claim counters from the harness: `claims` (lock:true), `releases`
    /// (lock:false), `inactiveReleases` (released while the app was not active) and the
    /// `ttl` the last claim asked for.
    private func claimCount(_ key: String, pane: String, in receipt: [String: Any]) -> Int {
        let panes = receipt["claimsByPane"] as? [String: Any]
        return (panes?[pane] as? [String: Any])?[key] as? Int ?? 0
    }

    /// A hidden pane hands its width back once the grace runs out, so another device viewing
    /// the agent is not held at this one's width; fronting it again re-claims. Claims ask for
    /// the short TTL, so a claim that could not be released lapses quickly.
    func testHiddenPaneReleasesAfterGraceAndReclaimsWhenShown() {
        launch("resize", environment: ["HERDR_CLAIM_GRACE_MS": "2000"])
        wait { ($0["mounted"] as? Int) == 2 }
        let start = wait { self.claimCount("claims", pane: "ix:a", in: $0) > 0 }
        XCTAssertEqual(claimCount("ttl", pane: "ix:a", in: start), 90_000, "claims must ask for the short TTL")
        XCTAssertEqual(claimCount("releases", pane: "ix:a", in: start), 0)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:b" }
        let released = wait { self.claimCount("releases", pane: "ix:a", in: $0) == 1 }
        let claimsWhileHidden = claimCount("claims", pane: "ix:a", in: released)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        wait { self.claimCount("claims", pane: "ix:a", in: $0) > claimsWhileHidden }
        XCTAssertEqual(claimCount("releases", pane: "ix:a", in: probe()), 1, "a re-shown pane must not release again")
    }

    /// A quick switch away and back inside the grace sends no release (and so no second
    /// winsize change and agent redraw).
    func testQuickHideAndShowWithinGraceSendsNoRelease() {
        launch("resize", environment: ["HERDR_CLAIM_GRACE_MS": "20000"])
        wait { ($0["mounted"] as? Int) == 2 }
        wait { self.claimCount("claims", pane: "ix:a", in: $0) > 0 }
        command("switch")
        wait { ($0["pane"] as? String) == "ix:b" }
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        // Long enough for an immediate or short-timer release to have landed.
        XCTAssertFalse(holds(within: 4) { self.claimCount("releases", pane: "ix:a", in: $0) > 0 },
                       "a hide/show inside the grace released the claim: \(probe())")
    }

    /// Going to the background releases the claim BEFORE the app comes back (a release sent
    /// while inactive), and the pane claims again on return. The grace is long, so only the
    /// background can have released.
    func testAppBackgroundReleasesClaimAndReturnReclaims() {
        launch("resize", environment: ["HERDR_CLAIM_GRACE_MS": "600000"])
        let before = wait { self.claimCount("claims", pane: "ix:a", in: $0) > 0 }
        let claimsBefore = claimCount("claims", pane: "ix:a", in: before)
        let releasesBefore = claimCount("inactiveReleases", pane: "ix:a", in: before)
        XCUIDevice.shared.press(.home)
        // Wait for THIS background's release, read from the receipt while the app is still
        // in the background (reading the probe does not bring the app forward), instead of a
        // fixed dwell counted from the press. Counting from `releasesBefore` means an earlier
        // release cannot satisfy it. A synchronization improvement, not a reproduced fix: in
        // CI 39251022452 the app entered the background 2.5 s after Home and was back 1.31 s
        // later with no release, and that red was not reproduced. The 30 s bound is new.
        XCTAssertTrue(holds(within: 30) {
            self.claimCount("inactiveReleases", pane: "ix:a", in: $0) > releasesBefore
        }, "no release went out before the app was brought back: \(probe())")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "the app did not return to the foreground")
        XCTAssertTrue(app.staticTexts["terminal-interaction-probe"].exists(within: 30),
                      "the probe never came back after reactivation")
        let after = wait { self.claimCount("claims", pane: "ix:a", in: $0) > claimsBefore }
        XCTAssertGreaterThanOrEqual(claimCount("inactiveReleases", pane: "ix:a", in: after), 1,
                                    "no release went out while the app was in the background")
    }
}
