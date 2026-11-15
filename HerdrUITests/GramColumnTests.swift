import XCTest

/// Gram's column on iPad and Mac (#541): the conversation column Chat uses, at the width the
/// two share, resized from the same hidden edge handles (symmetric drag, 560 pt minimum, snaps
/// at Readable, Wide and Full, double tap resets, a readout while dragging), with the composer
/// under it at its width. iPhone keeps the full-width feed and composer, with no handles.
///
/// The `list` mock clears the stored width at launch unless `HERDR_MOCK_COLUMN_WIDTH=keep`,
/// so each test starts at the default (Wide).
final class GramColumnTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchGram(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication.launched(mock: "list", environment: environment)
        let tab = app.buttons["Gram"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.tap()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    /// Polls `read` until `done` holds or `timeout` passes; returns the last reading.
    @discardableResult
    private func settle(within timeout: TimeInterval = 5, _ read: () -> CGFloat, until done: (CGFloat) -> Bool) -> CGFloat {
        var value = read()
        let deadline = Date().addingTimeInterval(timeout)
        while !done(value), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            value = read()
        }
        return value
    }

    /// How many times a Gram row's body has run (`gram-row-renders`, DEBUG mock runs).
    private func rowRenders(_ app: XCUIApplication) -> Int {
        let probe = element(app, "gram-row-renders")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG row-render probe should be present")
        return Int(probe.label) ?? -1
    }

    /// A real touch drag on the column's right-edge handle: press just inside the edge (still
    /// on the handle's band, and clear of a window edge when the column is Full) at the feed's
    /// mid-height, below the floating header, then drag `dx` points sideways.
    private func dragRightEdge(_ app: XCUIApplication, by dx: CGFloat) {
        let column = element(app, "gram-column").frame
        let feed = app.scrollViews["gram-feed"].frame
        let origin = app.frame.origin
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: column.maxX - 6 - origin.x, dy: feed.midY - origin.y))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    /// Gram's composer card sits under the column at its width (less the card's 12 pt inset on
    /// each side), centred on it.
    private func assertComposerMatchesColumn(_ app: XCUIApplication, _ moment: String) {
        let column = element(app, "gram-column").frame
        let card = element(app, "composer-card")
        XCTAssertTrue(card.exists, app.debugDescription)
        XCTAssertEqual(card.frame.width, column.width - 24, accuracy: 2, "\(moment): the composer takes the column's width")
        XCTAssertEqual(card.frame.midX, column.midX, accuracy: 2, "\(moment): the composer is centred under the column")
    }

    /// An agent's bubble grows with the column on regular width (owner request 2026-10-27): up
    /// to 80 % of it, never under 520, and at most 520 once the column is too narrow for more.
    /// Measured on clientloop's code + file card (`g2`), which fills its whole cap.
    private func assertAgentBubbleFollowsColumn(_ app: XCUIApplication, atMinimum: Bool, _ moment: String) {
        let bubble = element(app, "gram-bubble-g2")
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        let column = element(app, "gram-column").frame.width
        if atMinimum {
            let width = settle({ bubble.frame.width }, until: { $0 <= 520.5 })
            XCTAssertLessThanOrEqual(width, 520.5, "\(moment): at the \(Int(column)) pt column the agent's card keeps today's 520 cap")
        } else {
            let width = settle({ bubble.frame.width }, until: { $0 > 520.5 })
            XCTAssertGreaterThan(width, 520.5, "\(moment): at the \(Int(column)) pt column the agent's card grows past 520")
            XCTAssertLessThanOrEqual(width, column * 0.8 + 0.5, "\(moment): the agent's card takes at most 80 % of the \(Int(column)) pt column")
        }
    }

    /// iPhone keeps today's layout: no handles, a full-width feed and composer. iPad shows
    /// both handles, named for VoiceOver, on the column's edges.
    func testGramWidthHandlesOnlyOnRegularWidth() {
        let app = launchGram()
        let feed = app.scrollViews["gram-feed"]
        let column = element(app, "gram-column")
        XCTAssertTrue(column.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(feed.waitForExistence(timeout: 5), app.debugDescription)
        let left = element(app, "gram-width-handle-left")
        let right = element(app, "gram-width-handle-right")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(right.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(left.exists, app.debugDescription)
            // Gram's own width (the feed's scroll view runs on under the floating sidebar).
            let area = element(app, "gram-width-area")
            XCTAssertTrue(area.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(right.label, "Gram width")
            XCTAssertTrue((right.value as? String)?.hasSuffix("points") == true
                          || (right.value as? String)?.contains("points,") == true,
                          "the handle reads its width: \(String(describing: right.value))")
            // Wide (1000), or the whole feed when that is narrower (Full).
            let wide = min(1000, area.frame.width)
            let width = settle({ column.frame.width }, until: { abs($0 - wide) < 0.5 })
            XCTAssertEqual(width, wide, accuracy: 0.5, "Gram's column starts at the shared default, Wide")
            XCTAssertEqual(column.frame.midX, area.frame.midX, accuracy: 1, "the column is centred")
            if column.frame.width <= area.frame.width - 44 {
                XCTAssertEqual(left.frame.midX, column.frame.minX, accuracy: 1, "the left handle sits on the column's edge")
                XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the right handle sits on the column's edge")
            } else {
                // Full: the bands stay inside the feed, clear of the sidebar and the window edge.
                XCTAssertGreaterThanOrEqual(left.frame.minX, area.frame.minX - 0.5, "the left handle stays inside Gram")
                XCTAssertLessThanOrEqual(right.frame.maxX, area.frame.maxX + 0.5, "the right handle stays inside Gram")
            }
            assertComposerMatchesColumn(app, "iPad Gram")
            record(app, "iPad Gram column with its edge handles")
        } else {
            XCTAssertFalse(left.exists, "no width handles on iPhone")
            XCTAssertFalse(right.exists, "no width handles on iPhone")
            XCTAssertEqual(column.frame.width, feed.frame.width, accuracy: 1, "the phone's column spans the feed")
            let card = element(app, "composer-card")
            XCTAssertTrue(card.exists, app.debugDescription)
            XCTAssertEqual(card.frame.width, feed.frame.width - 24, accuracy: 2, "the phone's composer keeps the full width")
            record(app, "iPhone Gram keeps the full-width feed and composer")
        }
    }

    /// Dragging the right edge resizes Gram's column around its centre and the composer
    /// follows, without re-rendering the rows per tick; near 720 it snaps to Readable with its
    /// readout; the width survives a relaunch; a double tap resets to Wide. An agent's bubble
    /// grows past 520 at Wide and keeps to 520 at the 560 pt minimum.
    func testDraggingTheGramEdgeResizesTheColumn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Gram's width is resizable on regular width only")
        // Landscape gives the detail column room for Wide (1000) and a drag down to Readable.
        XCUIDevice.shared.orientation = .landscapeLeft
        rotated = true
        let hold = ["HERDR_COLUMN_WIDTH_READOUT_HOLD": "8"]
        let app = launchGram(environment: hold)
        let feed = app.scrollViews["gram-feed"]
        let column = element(app, "gram-column")
        let right = element(app, "gram-width-handle-right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(feed.waitForExistence(timeout: 5), app.debugDescription)
        // Gram's own width (the feed's scroll view runs on under the floating sidebar).
        let area = element(app, "gram-width-area")
        XCTAssertTrue(area.waitForExistence(timeout: 5), app.debugDescription)
        var available = settle(within: 8, { area.frame.width }, until: { $0 > 1000 })
        // An earlier class may leave the app in a smaller window (iPadOS restores its size):
        // minimising the sidebar gives Gram the window's width.
        if available < 780 {
            let minimise = app.buttons.matching(NSPredicate(format: "label == %@", "Minimise sidebar")).firstMatch
            XCTAssertTrue(minimise.waitForExistence(timeout: 5), "Gram only \(available) pt wide: \(app.debugDescription)")
            minimise.tap()
            minimisedSidebar = true
            available = settle(within: 8, { area.frame.width }, until: { $0 >= 780 })
        }
        XCTAssertGreaterThanOrEqual(available, 780, "Gram needs room to drag down to Readable: \(app.debugDescription)")
        let wide = min(1000, available)
        let initial = settle({ column.frame.width }, until: { abs($0 - wide) < 0.5 })
        XCTAssertEqual(initial, wide, accuracy: 0.5, "the column starts Wide (or Full when narrower)")
        XCTAssertEqual(column.frame.midX, area.frame.midX, accuracy: 1, "the column is centred")
        if initial <= available - 44 {
            XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the handle sits on the column's edge")
        }
        assertComposerMatchesColumn(app, "Wide")
        assertAgentBubbleFollowsColumn(app, atMinimum: false, "Wide")
        let initialMinX = column.frame.minX
        record(app, "Gram column at Wide (\(Int(initial)) pt of \(Int(available)))")

        // Inwards: both edges move in by the drag, so the column narrows by twice it and stays
        // centred. The target stays clear of Readable's snap zone.
        let shrink: CGFloat = abs(initial - 120 - 720) <= 16 ? 200 : 120
        // The width is the column's frame, not a row input: rows reflow in layout, but a drag's
        // many ticks must not re-run their bodies. One pass of the drawn rows is the bound;
        // per-tick invalidation would be many times that.
        Thread.sleep(forTimeInterval: 1)
        let drawnRows = Int((element(app, "gram-feed-messages").value as? String)?
            .split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(drawnRows, 0, "the feed reports how many messages it draws")
        let rendersBeforeDrag = rowRenders(app)
        dragRightEdge(app, by: -shrink / 2)
        let narrowed = settle({ column.frame.width }, until: { abs($0 - (initial - shrink)) <= 4 })
        XCTAssertEqual(narrowed, initial - shrink, accuracy: 4, "each point of drag narrows the column by two")
        Thread.sleep(forTimeInterval: 0.6)
        let dragRenders = rowRenders(app) - rendersBeforeDrag
        XCTAssertLessThanOrEqual(dragRenders, drawnRows, "a width drag re-rendered \(dragRenders) Gram rows (\(drawnRows) drawn)")
        XCTAssertEqual(column.frame.minX - initialMinX, shrink / 2, accuracy: 2, "the left edge moves in with the right")
        XCTAssertEqual(column.frame.midX, area.frame.midX, accuracy: 1, "the column stays centred")
        assertComposerMatchesColumn(app, "Narrowed")

        // Aim at 714: within 12 pt of Readable, so it lands on exactly 720.
        dragRightEdge(app, by: -(narrowed - 714) / 2)
        // The readout first, straight off the release: it stays only for the hold, and on a
        // loaded runner each frame query below can take seconds (#681, job j_7d38e2ee).
        pollLabel(app, "gram-width-readout", "the readout names Readable", timeout: 3) { $0 == "720 pt · Readable" }
        let readable = settle({ column.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(readable, 720, accuracy: 0.5, "a width near 720 snaps to Readable")
        XCTAssertEqual(right.value as? String, "720 points, Readable")
        XCTAssertEqual(column.frame.midX, area.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(app, "Readable")
        record(app, "Gram column snapped to Readable with its readout")

        // Remembered: a relaunch that keeps the stored width shows Readable again.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        let again = launchGram(environment: hold.merging(["HERDR_MOCK_COLUMN_WIDTH": "keep"]) { _, new in new })
        let againFeed = element(again, "gram-width-area")
        let againColumn = element(again, "gram-column")
        let againRight = element(again, "gram-width-handle-right")
        XCTAssertTrue(againRight.waitForExistence(timeout: 10), again.debugDescription)
        let kept = settle({ againColumn.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(kept, 720, accuracy: 0.5, "the chosen width survives a relaunch")
        assertComposerMatchesColumn(again, "After relaunch")
        record(again, "Readable remembered across a relaunch")

        // A double tap on a handle resets to Wide (Full when Gram is narrower).
        againRight.doubleTap()
        let againWide = min(1000, againFeed.frame.width)
        let reset = settle({ againColumn.frame.width }, until: { abs($0 - againWide) < 0.5 })
        XCTAssertEqual(reset, againWide, accuracy: 0.5, "a double tap resets to Wide")
        XCTAssertEqual(againColumn.frame.midX, againFeed.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(again, "After reset")
        if againFeed.frame.width > 1000.5 {
            XCTAssertEqual(againRight.value as? String, "1000 points, Wide")
        }
        record(again, "Double tap resets the Gram column to Wide")

        // Down to the 560 pt minimum (the drag overshoots it and stops there): the agent's
        // bubble keeps to 520.
        dragRightEdge(again, by: -(reset - 560) / 2 - 40)
        let minimum = settle({ againColumn.frame.width }, until: { abs($0 - 560) < 0.5 })
        XCTAssertEqual(minimum, 560, accuracy: 0.5, "the column stops at its 560 pt minimum")
        assertAgentBubbleFollowsColumn(again, atMinimum: true, "Minimum")
        record(again, "Gram column at its minimum, the agent's bubble at 520")
    }

    /// Set by the drag test: puts the iPad back as the other tests expect it, pass or fail.
    private var rotated = false
    private var minimisedSidebar = false

    override func tearDown() {
        if minimisedSidebar {
            let app = XCUIApplication()
            let expand = app.buttons.matching(NSPredicate(format: "label == %@", "Expand sidebar")).firstMatch
            if app.state == .runningForeground, expand.exists { expand.tap() }
            minimisedSidebar = false
        }
        if rotated {
            XCUIDevice.shared.orientation = .portrait
            rotated = false
        }
        super.tearDown()
    }
}
