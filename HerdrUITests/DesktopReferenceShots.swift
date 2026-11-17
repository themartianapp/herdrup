import XCTest

/// Herdrup Desktop's pixel-parity references (herdrup-desktop#16): the Agents home on iPad,
/// landscape, over the desktop's fake herdr, in every state the list can show. Each state is
/// one attachment, `ref-<device>-<state>.png`, with its conditions beside it in
/// `ref-<device>-<state>.json`. design/reference/agent-list/README.md says how they become
/// the committed references.
///
/// `populated` and its expansions serve the desktop's own cmd/fakeherdr/agents.json. The
/// served states (folders, avatars, sessions, federated, needs you) serve
/// HerdrUITests/Fixtures/desktop-reference-<state>.json, which the desktop's fake herdr
/// serves too.
///
/// CI pins the status bar (`simctl status_bar override`) before this class runs; the app
/// (`HERDR_SCREENSHOT_MOCK=desktopref`) holds every animation still and pins its clock.
final class DesktopReferenceShots: DesktopReferenceCaptureCase {

    func testLoading() throws {
        let (app, device) = try launch("loading")
        XCTAssertTrue(app.activityIndicators.firstMatch.exists(within: 20),
                      "the sidebar should show its spinner while agent.list has not answered")
        capture(app, device: device, state: "loading")
    }

    func testEmpty() throws {
        let (app, device) = try launch("empty")
        XCTAssertTrue(app.staticTexts["no agents"].exists(within: 20),
                      "an empty agent.list should say so")
        capture(app, device: device, state: "empty")
    }

    func testPopulated() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        capture(app, device: device, state: "populated")
    }

    func testIdleExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        expand(app, "Idle, 2", showing: [row(app, "w2:p2"), row(app, "w2:p3")])
        capture(app, device: device, state: "idle-expanded")
    }

    func testArchivedExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        expand(app, "Archived, 1", showing: [app.staticTexts["old-spike"]])
        capture(app, device: device, state: "archived-expanded")
    }

    func testAllExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        // Archived first: it is the last row, so opening Idle first could push it below
        // the 11-inch fold before it is tapped.
        expand(app, "Archived, 1", showing: [app.staticTexts["old-spike"]])
        expand(app, "Idle, 2", showing: [row(app, "w2:p2"), row(app, "w2:p3")])
        capture(app, device: device, state: "all-expanded")
    }

    /// Folders and stars (`agent_groups`): Herdr open with its two agents, Enyo closed, and
    /// vetrina starred.
    func testFolders() throws {
        let (app, device) = try launch("folders", served: "folders")
        let herdr = element(app, "agent-folder-herdr"), enyo = element(app, "agent-folder-enyo")
        XCTAssertTrue(herdr.exists(within: 20), "the folders document should load")
        XCTAssertTrue(enyo.exists(within: 10), "Enyo should be listed")
        XCTAssertTrue(row(app, "w1:p1").exists(within: 10), "vetrina should be listed")
        XCTAssertTrue(row(app, "w1:p1").label.contains("starred"), "vetrina should show its star, got \(row(app, "w1:p1").label)")
        XCTAssertEqual(herdr.value as? String, "collapsed, 1 waiting, 0 stopped", "folders start closed")
        herdr.tap()
        if !poll(3, every: 0.25, { (herdr.value as? String)?.hasPrefix("expanded") == true }) { herdr.tap() }
        XCTAssertTrue(poll(10, every: 0.25) { (herdr.value as? String)?.hasPrefix("expanded") == true },
                      "tapping Herdr should open it")
        for pane in ["w1:p2", "w1:p3"] {
            XCTAssertTrue(row(app, pane).exists(within: 10), "open Herdr should show \(pane)")
        }
        XCTAssertTrue((enyo.value as? String)?.hasPrefix("collapsed") == true, "Enyo should stay closed")
        XCTAssertFalse(row(app, "w2:p1").exists, "closed Enyo should hide enyo-review")
        capture(app, device: device, state: "folders")
    }

    /// Avatars (`agent_avatar`): atlas's uploaded picture, nova's mascot, quill's initial tile.
    func testAvatars() throws {
        let (app, device) = try launch("avatars", served: "avatars")
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            XCTAssertTrue(row(app, pane).exists(within: 20), "\(pane) should be listed")
        }
        XCTAssertTrue(avatar(app, in: row(app, "w1:p1"), "image", named: "Photo"), "atlas should show its picture")
        XCTAssertTrue(avatar(app, in: row(app, "w1:p2"), "cub", named: "Cub"), "nova should show the Cub mascot")
        XCTAssertTrue(avatar(app, in: row(app, "w1:p3"), "initial", named: "Initial Q"), "quill should show its initial tile")
        capture(app, device: device, state: "avatars")
    }

    /// Session pills: default (this one), personal and work running, work with 2 waiting.
    func testSessions() throws {
        let (app, device) = try launch("sessions", served: "sessions")
        XCTAssertTrue(row(app, "w1:p1").exists(within: 20), "the roster should load")
        XCTAssertTrue(app.buttons["work, 2 need you"].exists(within: 20),
                      "work's pill should count its 2 waiting agents")
        XCTAssertTrue(app.buttons["personal"].exists, "personal should have a pill with no count")
        XCTAssertTrue(app.buttons["default"].exists, "the default session should have a pill")
        XCTAssertTrue(app.buttons["default"].isSelected, "the home is on the default session")
        XCTAssertFalse(app.buttons["scratch"].exists, "a stopped session has no pill")
        capture(app, device: device, state: "sessions")
    }

    /// Federated rows: mcb-air/scout reachable, mac-studio/render offline, homelab/backup
    /// unconfirmed (degraded peer, last known blocked).
    func testFederated() throws {
        let (app, device) = try launch("federated", served: "federated")
        for pane in ["w1:p1", "air/w1:p2", "studio/w1:p4", "nas/w2:p1"] {
            XCTAssertTrue(row(app, pane).exists(within: 20), "\(pane) should be listed")
        }
        XCTAssertTrue(row(app, "air/w1:p2").label.contains("mcb-air/scout"),
                      "a federated agent is named by its machine label, got \(row(app, "air/w1:p2").label)")
        XCTAssertTrue(element(app, "agent-row-stale-marker").exists(within: 10),
                      "the degraded peer's row should be marked stale")
        capture(app, device: device, state: "federated")
    }

    /// The needs-you pill: scrolled to the end of the list, the 3 waiting rows are out of
    /// sight and the pill under the top bar counts them.
    func testNeedsYouPill() throws {
        let (app, device) = try launch("needs-you", served: "needs-you")
        XCTAssertTrue(row(app, "w1:p1").exists(within: 20), "the roster should load")
        let pill = element(app, "needs-you-pill")
        XCTAssertFalse(pill.exists, "no pill while the waiting rows are on screen")
        // The end of the list, not a drag distance: the one scroll position every run, and
        // the desktop, can reach exactly. Working rows sort by pane id as strings (no
        // completed turns), so the last row is auth, w2:p9. Once it is on screen, three more
        // swipes pin the list against its end.
        let roster = app.scrollViews["agent-roster-scroll"]
        let last = row(app, "w2:p9")
        for _ in 0..<12 where !(last.exists && last.isHittable) { roster.swipeUp() }
        for _ in 0..<3 { roster.swipeUp() }
        XCTAssertTrue(last.waitForHittable(timeout: 5), "the last row should be on screen")
        XCTAssertTrue(pill.exists(within: 5), "the pill should show once the waiting rows are out of sight")
        XCTAssertEqual(pill.label, "3 agents need you")
        capture(app, device: device, state: "needs-you-pill")
    }

    /// The minimised sidebar: the rail's needs-you and working counts.
    func testNeedsYouRail() throws {
        let (app, device) = try launch("needs-you", served: "needs-you")
        XCTAssertTrue(row(app, "w1:p1").exists(within: 20), "the roster should load")
        let toggle = app.buttons["terminal-sidebar-toggle"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 10), "the sidebar's Minimise button should be on screen")
        toggle.tap()
        let count = app.descendants(matching: .any)["3 need you"]
        XCTAssertTrue(count.exists(within: 10), "the rail should count 3 agents that need you")
        XCTAssertTrue(app.descendants(matching: .any)["20 working"].exists, "the rail should count 20 working")
        capture(app, device: device, state: "needs-you-rail")
    }


    // MARK: Roster

    private func row(_ app: XCUIApplication, _ paneID: String) -> XCUIElement {
        element(app, "agent-row-\(paneID)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Whether `row` draws the avatar `kind` (`agent-avatar-<kind>`, labelled `named`): by
    /// that avatar inside the row, or, where the row merges its children into one element,
    /// by the row's label (as AgentAvatarUITests checks). Waits for a picture to load.
    private func avatar(_ app: XCUIApplication, in row: XCUIElement, _ kind: String, named: String) -> Bool {
        poll(15, every: 0.25) {
            guard row.exists else { return false }
            let frame = row.frame
            let inside = app.descendants(matching: .any).matching(identifier: "agent-avatar-\(kind)")
                .allElementsBoundByIndex
                .contains { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.label.contains(named) }
            let loading = app.descendants(matching: .any)["agent-avatar-loading"].exists
            return inside || (!loading && row.label.contains(named))
        }
    }

    /// The fixture as the roster first draws it: needs you (api-review, docs), the
    /// unreachable studio/render, working (web, infra), then Idle and Archived closed.
    private func assertDefaultRoster(_ app: XCUIApplication) {
        let roster = app.descendants(matching: .any)["agent-roster-scroll"]
        XCTAssertTrue(roster.exists(within: 20), "the roster should load")
        for pane in ["w1:p1", "w1:p2", "studio/w1:p4", "w1:p3", "w2:p1"] {
            XCTAssertTrue(row(app, pane).exists(within: 10), "\(pane) should be listed")
        }
        XCTAssertTrue(app.buttons["Idle, 2"].exists, "Idle should be a closed row of two")
        XCTAssertEqual(app.buttons["Idle, 2"].value as? String, "collapsed")
        XCTAssertTrue(app.buttons["Archived, 1"].exists, "Archived should be a closed row of one")
        XCTAssertEqual(app.buttons["Archived, 1"].value as? String, "collapsed")
        XCTAssertFalse(row(app, "w2:p2").exists, "closed Idle should hide release")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists, "a loaded roster shows no spinner")
    }

    private func expand(_ app: XCUIApplication, _ label: String, showing rows: [XCUIElement]) {
        let toggle = app.buttons[label]
        XCTAssertTrue(toggle.exists(within: 10), "\(label) should be listed")
        toggle.tap()
        // One more tap if the first never reached the row (seen once on the 11-inch, run
        // 40685403456): the row reports its state, so a second tap cannot close it again.
        if !rows[0].exists(within: 3), toggle.value as? String == "collapsed" { toggle.tap() }
        for row in rows {
            XCTAssertTrue(row.exists(within: 10), "opening \(label) should show its agents")
        }
        XCTAssertEqual(toggle.value as? String, "expanded")
    }

}
