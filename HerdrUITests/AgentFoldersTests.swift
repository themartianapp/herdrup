import XCTest

/// Agent folders and stars (herdrup#552) over the `folders` mock daemon, which advertises
/// `agent_groups` and keeps the document in memory: Enyo (enyo-review waiting, enyo-efm
/// stopped, enyo working, enyo-scout idle) and Herdr (herdr-ios waiting, herdr-app working),
/// vetrina starred, and a dozen more working agents so the waiting rows can scroll away.
final class AgentFoldersTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
        XCUIApplication.launched(mock: "folders", environment: environment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func row(_ app: XCUIApplication, _ paneID: String) -> XCUIElement {
        element(app, "agent-row-\(paneID)")
    }

    private func folder(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        element(app, "agent-folder-\(id)")
    }

    /// Waits for the list and the folders document: the Enyo folder row is on screen.
    private func waitForFolders(_ app: XCUIApplication) -> XCUIElement {
        let enyo = folder(app, "enyo")
        XCTAssertTrue(enyo.exists(within: 15), "the folders did not load")
        XCTAssertTrue(enyo.waitForHittable(timeout: 5), "the Enyo folder row is not on screen")
        return enyo
    }

    /// Scrolls the list (down, or back `up`) until `element` is on screen, at most `swipes` times.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false, swipes: Int = 6) {
        let scroll = app.scrollViews["agent-roster-scroll"]
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            if up { scroll.swipeDown(velocity: .slow) } else { scroll.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.waitForHittable(timeout: 3), "\(element) never came on screen")
    }

    /// Swipes right on `row` until its swipe actions show; returns the action `identifier`.
    private func swipeAction(_ identifier: String, on row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let action = element(app, identifier)
        for _ in 0..<3 where !action.exists {
            row.swipeRight()
            _ = action.exists(within: 2)
        }
        XCTAssertTrue(action.waitForHittable(timeout: 3), "swiping right did not reveal \(identifier)")
        return action
    }

    /// Taps `folder` and waits until it reads `expanded` (or collapsed), tapping once more if
    /// the first tap did nothing. On a loaded simulator the synthesized tap's touch-up can reach
    /// the app after the row's long-press menu has started to lift, and that cancels the tap:
    /// run 40574364856's iPad recording shows the lift on the Enyo row at the tap, then the
    /// folder staying closed for 25 s. A second tap is what a person would do; the folder must
    /// then open or close exactly as asked.
    private func toggle(_ folder: XCUIElement, toExpanded expanded: Bool) {
        let state = expanded ? "expanded" : "collapsed"
        func done() -> Bool { (folder.value as? String)?.hasPrefix(state) == true }
        folder.tap()
        if !poll(10, every: 0.25, done) {
            folder.tap()
        }
        XCTAssertTrue(poll(10, every: 0.25, done), "tapping \(folder) did not make it \(state)")
    }

    func testClosedFolderShowsWaitingCountAndOpensOnTap() {
        var app = launch()
        let enyo = waitForFolders(app)
        let herdr = folder(app, "herdr")

        // Closed: one row with the count, who needs you, and the amber and red counts.
        XCTAssertEqual(enyo.label, "Enyo, 4 agents, enyo-review needs you · enyo-efm stopped")
        XCTAssertEqual(enyo.value as? String, "collapsed, 1 waiting, 1 stopped")
        XCTAssertFalse(row(app, "w1:p3").exists, "a closed folder hides enyo-review")
        // A starred agent goes first in its state: vetrina before jarvis, both waiting.
        let vetrina = row(app, "w1:p2"), jarvis = row(app, "w1:p1")
        XCTAssertTrue(vetrina.label.contains("starred"), "vetrina shows its star, got \(vetrina.label)")
        XCTAssertLessThan(vetrina.frame.minY, jarvis.frame.minY, "the starred agent is first")
        // Folders sit after the starred agents of their state and before the others
        // (owner report 2026-10-28: they had sunk to the bottom of the section).
        XCTAssertLessThan(vetrina.frame.minY, enyo.frame.minY, "starred agents come before the folders")
        XCTAssertLessThan(enyo.frame.minY, herdr.frame.minY, "folders in their order")
        XCTAssertLessThan(herdr.frame.minY, jarvis.frame.minY, "folders come before the unstarred agents")

        // Tap opens it in place: its agents, most urgent first, under it and indented.
        toggle(enyo, toExpanded: true)
        let review = row(app, "w1:p3")
        XCTAssertTrue(review.waitForHittable(timeout: 5), "tap opens the folder")
        XCTAssertEqual(enyo.value as? String, "expanded, 1 waiting, 1 stopped")
        XCTAssertGreaterThanOrEqual(review.frame.minY, enyo.frame.maxY - 1, "members sit under their folder")
        let members = ["w1:p3", "w3:p1", "w2:p12", "w4:p1"].map { row(app, $0) }
        XCTAssertTrue(members.allSatisfy(\.exists), "every member is listed")
        XCTAssertEqual(members.map(\.frame.minY), members.map(\.frame.minY).sorted(),
                       "waiting, stopped, working, idle")

        // Tap again closes it.
        toggle(enyo, toExpanded: false)
        XCTAssertTrue(poll(5, every: 0.1) { !review.exists }, "a second tap closes the folder")

        // One open, one closed, a star: the screenshot.
        toggle(herdr, toExpanded: true)
        XCTAssertTrue(row(app, "w1:p4").waitForHittable(timeout: 5), "Herdr opens")
        row(app, "w1:p4").waitForSettledFrame()
        attach(app, "agent-folders")

        // Open folders are this device's, kept across a launch.
        app.terminate()
        app = launch(["HERDR_MOCK_KEEP_OPEN_FOLDERS": "1"])
        _ = waitForFolders(app)
        XCTAssertTrue(row(app, "w1:p4").exists(within: 5), "Herdr is still open after a relaunch")
        XCTAssertFalse(row(app, "w1:p3").exists, "Enyo is still closed")
    }

    /// Owner report 2026-10-28: the folder picture showed every agent's initial even when it
    /// wears a mascot. Each cell is the agent's own avatar, as its row draws it.
    func testFolderPictureShowsItsAgentsAvatars() {
        let app = launch()
        let enyo = waitForFolders(app)
        let herdr = folder(app, "herdr")
        XCTAssertTrue(herdr.exists(within: 5))
        XCTAssertFalse(row(app, "w1:p3").exists, "Enyo is closed: only its picture shows its agents")

        func cell(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "folder-avatar-\(name)").firstMatch
        }
        let expected: [(String, XCUIElement, String, String)] = [
            ("enyo-review", enyo, "mascot:bot", "Bot"),
            ("enyo-efm", enyo, "initial", "Initial E"),
            ("enyo", enyo, "mascot:tri", "Tri"),
            ("enyo-scout", enyo, "mascot:drop", "Drop"),
            ("herdr-ios", herdr, "initial", "Initial H"),
            ("herdr-app", herdr, "mascot:cub", "Cub"),
        ]
        for (name, owner, kind, label) in expected {
            let picture = cell(name)
            XCTAssertTrue(picture.exists(within: 5), "\(owner) has no picture cell for \(name)")
            XCTAssertTrue(poll(5, every: 0.1) { (picture.value as? String) == kind },
                          "\(name)'s cell should show \(kind), got \(String(describing: picture.value))")
            XCTAssertEqual(picture.label, label, "\(name)'s cell reads as its avatar")
            let center = CGPoint(x: picture.frame.midX, y: picture.frame.midY)
            XCTAssertTrue(owner.frame.contains(center), "\(name)'s cell sits in its folder's row")
        }

        enyo.waitForSettledFrame()
        attach(enyo.screenshot(), "agent-folder-avatars-row")
        attach(app, "agent-folder-avatars")
    }

    func testNeedsYouPillCountsAgentsInClosedFolders() {
        let app = launch()
        _ = waitForFolders(app)
        XCTAssertFalse(row(app, "w1:p3").exists, "both folders closed")
        let pill = element(app, "needs-you-pill")
        let scroll = app.scrollViews["agent-roster-scroll"]
        for _ in 0..<6 where !pill.exists { scroll.swipeUp() }
        XCTAssertTrue(pill.exists(within: 3), "the pill appears once the waiting rows scroll away")
        XCTAssertEqual(pill.label, "4 agents need you",
                       "jarvis and vetrina, plus enyo-review and herdr-ios inside closed folders")
    }

    func testSwipeToStarMovesTheAgentToTheTopOfItsState() {
        let app = launch()
        _ = waitForFolders(app)
        // Working, loose, by pane id: bank-qa (w2:p1), omp-docs, mcb-sync, huurjacht, trend-scout…
        let trendScout = row(app, "w2:p3"), bankQA = row(app, "w2:p1")
        scrollTo(trendScout, in: app)
        XCTAssertLessThan(bankQA.frame.minY, trendScout.frame.minY)
        XCTAssertFalse(trendScout.label.contains("starred"))

        let star = swipeAction("agent-swipe-star", on: trendScout, in: app)
        XCTAssertTrue(element(app, "agent-swipe-move").exists, "the swipe offers Move to folder too")
        star.waitForSettledFrame()
        attach(app, "agent-folders-swipe")
        star.tap()

        XCTAssertTrue(poll(5, every: 0.1) { trendScout.label.contains("starred") }, "the row shows its star")
        XCTAssertTrue(poll(5, every: 0.1) { trendScout.frame.minY < bankQA.frame.minY },
                      "the starred agent is now first among the working agents")
        XCTAssertEqual(trendScout.value as? String, "working", "but it stays in its state")
        XCTAssertFalse(poll(1.5, every: 0.1) { app.alerts.count > 0 }, "the server took the change")

        // Unstar from the long-press menu puts it back. The row moved up the list: find it.
        scrollTo(trendScout, in: app, up: true)
        trendScout.press(forDuration: 1.0)
        let unstar = app.buttons["Unstar"]
        XCTAssertTrue(unstar.exists(within: 5), "long-press offers Unstar")
        XCTAssertTrue(app.buttons["Move to folder"].exists, "and Move to folder")
        unstar.tap()
        XCTAssertTrue(poll(5, every: 0.1) { bankQA.frame.minY < trendScout.frame.minY }, "unstarred, back in place")
    }

    func testNewFolderFromASwipe() {
        let app = launch()
        _ = waitForFolders(app)
        let jarvis = row(app, "w1:p1")
        swipeAction("agent-swipe-move", on: jarvis, in: app).tap()

        let newFolder = app.buttons["New folder…"]
        XCTAssertTrue(newFolder.exists(within: 5), "Move offers a new folder")
        XCTAssertTrue(app.buttons["Enyo"].exists && app.buttons["Herdr"].exists, "and the existing ones")
        newFolder.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.exists(within: 5), "a new folder asks for its name")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.exists(within: 3))
        field.tap()
        field.typeText("Ops")
        alert.buttons["Create"].tap()

        // The new folder holds jarvis and opens on this device, so jarvis stays in sight.
        let ops = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'agent-folder-' AND label BEGINSWITH 'Ops, '"))
            .firstMatch
        XCTAssertTrue(ops.exists(within: 5), "the Ops folder appears")
        XCTAssertEqual(ops.label, "Ops, 1 agent, jarvis needs you")
        XCTAssertTrue(jarvis.waitForHittable(timeout: 5))
        XCTAssertGreaterThanOrEqual(jarvis.frame.minY, ops.frame.maxY - 1, "jarvis is inside it")
        XCTAssertFalse(poll(1.5, every: 0.1) { app.alerts.count > 0 }, "the server took the change")

        // Delete from the folder's long-press: jarvis goes back to the list.
        ops.press(forDuration: 1.0)
        let delete = app.buttons["Delete folder"]
        XCTAssertTrue(delete.exists(within: 5), "folder long-press offers Delete")
        XCTAssertTrue(app.buttons["Rename"].exists)
        delete.tap()
        XCTAssertTrue(poll(5, every: 0.1) { !ops.exists }, "the folder is gone")
        XCTAssertTrue(jarvis.waitForHittable(timeout: 5), "and jarvis is back in the list")
    }

    func testNoCapabilityShowsNoFolders() {
        let app = launch(["HERDR_MOCK_GROUPS": "off"])
        let review = row(app, "w1:p3")
        XCTAssertTrue(review.exists(within: 15), "the roster did not load")
        // Give the ping time to answer: nothing about folders may arrive.
        let folders = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'agent-folder-'"))
        XCTAssertFalse(poll(2, every: 0.1) { folders.count > 0 }, "an older server shows no folder rows")
        XCTAssertTrue(review.isHittable, "enyo-review is a plain row")
        XCTAssertFalse(row(app, "w1:p2").label.contains("starred"), "and no stars")

        // A row with no swipe actions is a plain button (a swipe there is a tap), so the
        // long-press menu is where the folder actions would show.
        let jarvis = row(app, "w1:p1")
        jarvis.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename"].exists(within: 5))
        XCTAssertFalse(app.buttons["Star"].exists, "no Star in the long-press menu")
        XCTAssertFalse(app.buttons["Move to folder"].exists, "no Move to folder either")
    }
}
