import XCTest

/// Saved desktop request370331, through the real proposal-B Settings split view.
/// These are capture instruments, not copy-pinning product regression tests. The common
/// launch/capture helpers enforce both reference iPads, dark @2x, and the fixed clock;
/// the native capture workflow supplies the matching fixed status bar.
final class DesktopSettingsReferenceShots: DesktopReferenceCaptureCase {
    private static let settingsMachinesSHA256 = "3dfefaef702bc3b4e7c1108ecf9526e7bd4ec2da432ae36559e33d9f112b39ec"
    private static let settingsEmptySHA256 = "bb0c47ca8e3f85f48f0b2a976baf8c1fcaf047031f1d4c8264a9b2b33f21bab1"
    private static let settingsDaemonLine = "herdr 0.9.5 · 4c1e9a2"

    /// Index at its top with Machines selected and the connected machine/version hero.
    /// Then the detail's bottom stop: all six saved profiles, the extra unsaved peer,
    /// setup action and aggregate reach. No profile is represented only off screen.
    func testSettingsMachinesReferences() throws {
        let (app, device) = try launch("settings", served: "settings-machines",
                                       sha256: Self.settingsMachinesSHA256)
        let (index, detail, detailViewport) = try openReferenceSettings(app)
        XCTAssertTrue(detail.staticTexts["atlas-mini"].exists(within: 20),
                      "machine.status must load, rather than capturing the empty fallback")
        XCTAssertTrue(detail.staticTexts["reachable · 2 agents"].exists(within: 20),
                      "the reachable saved profile must match both agent machine IDs")
        requireSettingsVisible(app.buttons["settings-machine-card"], in: index.frame)
        requireSettingsVisible(app.descendants(matching: .any)["settings-machine-hero"], in: detailViewport)
        capture(app, device: device, state: "settings-machines-index")

        // Pin to a reproducible boundary, not a device-specific partial swipe distance.
        let reach = detail.descendants(matching: .any)["settings-federation-reach"]
        for _ in 0..<8 where !reach.isHittable { detail.swipeUp() }
        for _ in 0..<3 { detail.swipeUp() }
        let profileRows = [
            ("atlas-mini", "reachable · 2 agents"),
            ("birch-air", "degraded · 1 agent"),
            ("cedar-linux", "offline · 1 agent"),
            ("delta-nas", "Disabled"),
            ("ember-box", "Coordinator off"),
            ("fjord-laptop", "Not federated (stale)"),
            ("guest-lab", "1 agent"),
        ]
        for (name, status) in profileRows {
            requireSettingsVisible(detail.staticTexts[name], in: detailViewport)
            requireSettingsVisible(detail.staticTexts[status], in: detailViewport)
        }
        requireSettingsVisible(detail.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "How to add a machine")).firstMatch, in: detailViewport)
        requireSettingsVisible(reach, in: detailViewport)
        XCTAssertTrue(reach.label.contains("5 machines") && reach.label.contains("5 agents")
                      && reach.label.contains("1 offline"),
                      "the footer counts this box plus four agent-derived peers, not saved profiles")
        XCTAssertTrue(app.buttons["settings-machine-card"].isSelected)
        capture(app, device: device, state: "settings-machines-federation")
    }

    /// The real empty federation card: no saved profiles AND no agent-derived peers.
    func testSettingsEmptyMachinesReference() throws {
        let (app, device) = try launch("settings", served: "settings-empty",
                                       sha256: Self.settingsEmptySHA256)
        let (_, detail, detailViewport) = try openReferenceSettings(app)
        requireSettingsVisible(detail.staticTexts["No saved machines yet."], in: detailViewport)
        requireSettingsVisible(detail.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "How to add a machine")).firstMatch, in: detailViewport)
        let reach = detail.descendants(matching: .any)["settings-federation-reach"]
        requireSettingsVisible(reach, in: detailViewport)
        XCTAssertTrue(reach.label.contains("1 machine") && reach.label.contains("0 agents"),
                      "the empty card must not retain peers from the populated fixture")
        XCTAssertFalse(detail.buttons["Federate"].exists)
        XCTAssertFalse(detail.buttons["Unfederate"].exists)
        capture(app, device: device, state: "settings-machines-empty")
    }

    /// Proposal B removed the old App & About destination. Its honest equivalent is
    /// the inline ABOUT group at the sidebar's bottom, including the real bundle-version
    /// footer. Machines remains selected; no About selection or external browser is faked.
    func testSettingsAboutIndexReference() throws {
        let (app, device) = try launch("settings", served: "settings-machines",
                                       sha256: Self.settingsMachinesSHA256)
        let (index, detail, detailViewport) = try openReferenceSettings(app)
        XCTAssertTrue(detail.staticTexts["reachable · 2 agents"].exists(within: 20))
        let footer = index.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "herdrup mobile ")).firstMatch
        for _ in 0..<12 where !footer.isHittable { index.swipeUp() }
        for _ in 0..<3 { index.swipeUp() }
        requireSettingsVisible(index.staticTexts["ABOUT"], in: index.frame)
        requireSettingsVisible(index.buttons["settings-discord"], in: index.frame)
        for link in ["Privacy Policy", "Terms of Service", "Open source on GitHub"] {
            requireSettingsVisible(index.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", link)).firstMatch, in: index.frame)
        }
        requireSettingsVisible(footer, in: index.frame)
        requireSettingsVisible(index.staticTexts["dark only, on purpose"], in: index.frame)
        XCTAssertTrue(app.buttons["settings-machine-card"].isSelected,
                      "scrolling About into view must not invent an About destination")
        requireSettingsVisible(app.descendants(matching: .any)["settings-machine-hero"], in: detailViewport)
        capture(app, device: device, state: "settings-about-index")
    }

    /// Navigate via the section picker and machine card, never a rendered test-only view.
    /// Geometry rejects a compact/pushed Settings page masquerading as an iPad split.
    private func openReferenceSettings(_ app: XCUIApplication) throws -> (XCUIElement, XCUIElement, CGRect) {
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForHittable(timeout: 20))
        settings.tap()
        let card = app.buttons["settings-machine-card"]
        XCTAssertTrue(card.waitForHittable(timeout: 20))
        card.tap()
        let hero = app.descendants(matching: .any)["settings-machine-hero"]
        let ready = NSPredicate { _, _ in
            hero.exists && hero.label.contains("Connected") && hero.label.contains(Self.settingsDaemonLine)
        }
        XCTAssertTrue(waitForSettings(ready), "the connected daemon's fixed version + SHA must be present")
        XCTAssertTrue(card.isSelected, "Machines must be selected in the proposal-B index")
        let index = app.scrollViews.containing(.button, identifier: "settings-machine-card").firstMatch
        let detail = app.scrollViews.containing(.any, identifier: "settings-machine-hero").firstMatch
        XCTAssertTrue(index.exists && detail.exists)
        // iOS 27 exposes the detail scroll container from x=0 even though its visible
        // content starts beside the sidebar (confirmed in both first-run failure videos).
        // Prove the split with simultaneously visible children, not that container's origin.
        XCTAssertGreaterThan(hero.frame.minX, index.frame.maxX - 1,
                             "the Machines hero must lie to the right of the Settings index")
        XCTAssertGreaterThan(hero.frame.minX, card.frame.maxX,
                             "the selected machine card and hero must occupy separate columns")
        XCTAssertGreaterThan(min(card.frame.maxY, hero.frame.maxY),
                             max(card.frame.minY, hero.frame.minY),
                             "both column children must be visible side by side, not stacked")
        let detailViewport = detail.frame.intersection(CGRect(
            x: index.frame.maxX, y: app.frame.minY,
            width: max(0, app.frame.maxX - index.frame.maxX), height: app.frame.height))
        XCTAssertFalse(detailViewport.isEmpty, "the Machines column must have a visible viewport")
        requireSettingsVisible(card, in: index.frame)
        requireSettingsVisible(hero, in: detailViewport)
        XCTAssertTrue(app.staticTexts["Machines"].exists)
        return (index, detail, detailViewport)
    }

    private func requireSettingsVisible(_ element: XCUIElement, in viewport: CGRect,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForHittable(timeout: 10), "required reference content is not visible",
                      file: file, line: line)
        XCTAssertFalse(element.frame.isEmpty, "required reference content has no visible bounds",
                       file: file, line: line)
        XCTAssertTrue(viewport.contains(element.frame), "required reference content is clipped",
                      file: file, line: line)
    }

    private func waitForSettings(_ predicate: NSPredicate) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 20) == .completed
    }
}
