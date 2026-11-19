import XCTest

/// The owner's guest-access flow over the stateful `share` / `sharedaccess` mocks: sharing an
/// agent from its ••• menu, the invite that results, and revoking or cancelling from
/// Settings → Shared access. Each case also attaches a screenshot of the screen it proves.
final class GuestShareTests: XCTestCase {
    private var app: XCUIApplication!
    /// How long a screen may take to react to an action. Generous because on a busy shared
    /// simulator host a single XCUITest step has taken over a minute; only the final state
    /// matters here, not the latency.
    private static let actionTimeout: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    /// `still` makes llm-opt idle: the WORKING pill's endless pulse keeps the app from ever
    /// going idle, which costs a minute per XCUITest action. Only the screenshot keeps it.
    private func launch(_ mode: String, ownerName: String = "Jerry", pendingInvite: Bool = false,
                        still: Bool = true, environment: [String: String] = [:]) {
        var launchEnvironment = ["HERDR_MOCK_OWNER_NAME": ownerName].merging(environment) { _, new in new }
        if still { launchEnvironment["HERDR_MOCK_STILL"] = "1" }
        if pendingInvite { launchEnvironment["HERDR_MOCK_GUEST_INVITE"] = "1" }
        app = XCUIApplication.launched(mock: mode, environment: launchEnvironment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
    }

    /// No settle wait: UI tests run with animations off, so sheets and rows are already in
    /// place by the time the caller's own waits pass. The shots are receipts, not assertions.
    private func shoot(_ name: String) {
        attach(XCUIScreen.main.screenshot(), name)
    }

    private func openShareSheet() {
        let menu = element("terminal-actions")
        XCTAssertTrue(menu.exists(within: 20), "the pane header never rendered")
        let item = app.buttons["Share with someone"]
        for _ in 0..<3 where !item.exists {
            menu.tap()
            _ = item.exists(within: 3)
        }
        XCTAssertTrue(item.exists, "••• should offer Share with someone")
        item.tap()
        XCTAssertTrue(element("guest-share-name").exists(within: Self.actionTimeout), "share sheet did not open")
    }

    private func typeGuestName(_ name: String) {
        let field = element("guest-share-name")
        field.tap()
        field.typeText(name)
    }

    // MARK: Share + invite

    /// The design's frames (mock row 1) with llm-opt WORKING, for the owner-*.png screenshots.
    /// Opt-in (`TEST_RUNNER_HERDR_CAPTURE_GUEST_SCREENS=1`): the WORKING pill's endless pulse
    /// keeps the app from idling, so every action here waits out XCUITest's 60 s idle timeout
    /// and the capture takes over ten minutes, which the CI iPhone round cannot afford. The
    /// same flows are proven quickly by the tests below.
    func testCaptureShareScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERDR_CAPTURE_GUEST_SCREENS"] == "1",
                          "screenshot capture only; set TEST_RUNNER_HERDR_CAPTURE_GUEST_SCREENS=1")
        launch("share", still: false)
        XCTAssertTrue(text(containing: "Shared with plotarmordev").exists(within: 30))
        shoot("owner-4-chip")
        openShareSheet()
        typeGuestName("plotarmordev\n")
        shoot("owner-1-share")
        element("guest-share-create").tap()
        XCTAssertTrue(element("guest-invite-qr").exists(within: 30))
        shoot("owner-2-invite")
    }

    func testShareShowsTheLabelThenCreatesAnInviteWithQRAndLinks() {
        launch("share")
        // The chip names the guest who already holds llm-opt.
        XCTAssertTrue(text(containing: "Shared with plotarmordev").exists(within: 20),
                      "the pane header should say who the agent is shared with")

        openShareSheet()
        XCTAssertFalse(element("guest-owner-name").exists, "a known owner name must not be asked again")
        let create = element("guest-share-create")
        XCTAssertFalse(create.isEnabled, "Create invite needs a name first")

        typeGuestName("plotarmordev")
        XCTAssertTrue(text(containing: "plotarmordev (via HerdrUp):").exists(within: Self.actionTimeout),
                      "the preview must show the exact label the agent will see")
        XCTAssertTrue(text(containing: "Type into the terminal").exists)
        XCTAssertTrue(text(containing: "keystrokes can't carry a name").exists)
        XCTAssertTrue(create.isEnabled)

        create.tap()
        XCTAssertTrue(element("guest-invite-qr").exists(within: Self.actionTimeout), "no QR code after Create invite")
        XCTAssertTrue(app.staticTexts["Invite for plotarmordev"].exists)
        XCTAssertTrue(text(containing: "Works once · expires in 24 h").exists)
        XCTAssertTrue(text(containing: "Jerry's Mac Studio").exists)
        XCTAssertTrue(element("guest-invite-send").exists, "Send… (share sheet) is missing")
        let copy = element("guest-invite-copy")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].exists(within: Self.actionTimeout), "Copy link gave no feedback")
    }

    func testAnInvalidNameIsRejectedBeforeAnythingIsSent() {
        launch("share")
        openShareSheet()
        typeGuestName("-bad name")
        XCTAssertTrue(element("guest-share-name-error").exists(within: Self.actionTimeout),
                      "a name the daemon would reject must be flagged")
        XCTAssertFalse(element("guest-share-create").isEnabled)

        // 33 characters: one over the daemon's limit.
        let field = element("guest-share-name")
        field.clearAndType(String(repeating: "a", count: 33))
        XCTAssertFalse(element("guest-share-create").isEnabled, "33 characters exceeds the name rule")
        field.clearAndType(String(repeating: "a", count: 32))
        XCTAssertTrue(element("guest-share-create").isEnabled, "32 characters is allowed")
        XCTAssertFalse(element("guest-share-name-error").exists)
    }

    func testFirstShareAsksForTheOwnersNameOnce() {
        launch("share", ownerName: "-")
        openShareSheet()
        let owner = element("guest-owner-name")
        XCTAssertTrue(owner.exists, "the first share must ask for Your name")
        typeGuestName("plotarmordev")
        XCTAssertFalse(element("guest-share-create").isEnabled, "the invite needs the owner's name")

        owner.tap()
        owner.typeText("Jerry")
        let create = element("guest-share-create")
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(element("guest-invite-qr").exists(within: Self.actionTimeout))

        // Close and share again: the name is remembered.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(element("guest-invite-qr").gone(within: Self.actionTimeout))
        openShareSheet()
        XCTAssertFalse(element("guest-owner-name").exists, "Your name must only be asked the first time")
    }

    // MARK: Shared access

    private func openSharedAccess() {
        let row = app.staticTexts["Shared access"]
        XCTAssertTrue(row.exists(within: 20), "Settings should list Shared access")
        row.tap()
        XCTAssertTrue(text(containing: "PEOPLE").exists(within: Self.actionTimeout), "Shared access did not open")
    }

    func testSharedAccessListsPeopleAndTheActivityLog() {
        launch("sharedaccess")
        openSharedAccess()
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists(within: Self.actionTimeout))
        XCTAssertTrue(text(containing: "llm-opt on Jerry's Mac Studio").exists)
        XCTAssertTrue(text(containing: "active · 2 min ago").exists)
        XCTAssertTrue(text(containing: "SHA256:9f3a·e71c·04bd·c21e").exists, "the key fingerprint must be shown")

        // The log, newest first: upload, prompt, joined.
        let entries = app.descendants(matching: .any).matching(identifier: "guest-log-entry")
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.element(boundBy: 0).label.contains("prompt-set-v2.jsonl"))
        XCTAssertTrue(entries.element(boundBy: 1).label.contains("rerun the TensorFold bench"))
        XCTAssertTrue(entries.element(boundBy: 2).label.contains("Accepted your invite"))
        shoot("owner-3-shared-access")
    }

    func testRevokeAsksFirstThenRemovesThePersonAndLogsIt() {
        launch("sharedaccess")
        openSharedAccess()
        let revoke = element("guest-revoke-plotarmordev")
        XCTAssertTrue(revoke.exists(within: Self.actionTimeout))
        revoke.tap()

        let confirm = app.buttons["Revoke"].firstMatch
        XCTAssertTrue(app.staticTexts["Revoke plotarmordev?"].exists(within: Self.actionTimeout),
                      "revoking must ask for confirmation")
        shoot("owner-5-revoke-confirm")
        XCTAssertTrue(revoke.exists, "nothing is revoked before the confirmation")
        confirm.tap()

        XCTAssertTrue(element("guest-revoke-plotarmordev").gone(within: Self.actionTimeout))
        XCTAssertTrue(text(containing: "Nobody has access").exists)
        XCTAssertTrue(text(containing: "Access revoked").exists(within: Self.actionTimeout),
                      "the revoke must show up in the activity log")
    }

    func testCancellingAPendingInviteRemovesIt() {
        launch("sharedaccess", pendingInvite: true)
        openSharedAccess()
        let cancel = element("guest-cancel-sam")
        XCTAssertTrue(cancel.exists(within: Self.actionTimeout), "the pending invite should be listed")
        XCTAssertTrue(text(containing: "PENDING INVITES").exists)
        shoot("owner-6-pending-invite")
        cancel.tap()
        XCTAssertTrue(cancel.gone(within: Self.actionTimeout))
        XCTAssertFalse(text(containing: "PENDING INVITES").exists)
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "cancelling an invite must not touch guests")
    }

    /// mcb-air is a saved machine with no agents, so nothing in the agent list names it. Its
    /// guest must still be listed, from its own daemon, and be revocable there.
    func testAGuestOnASavedMachineWithoutAgentsIsListedAndRevocable() {
        launch("sharedaccess", environment: ["HERDR_MOCK_SAVED_PEER_GUEST": "1"])
        openSharedAccess()
        let revoke = element("guest-revoke-sam")
        XCTAssertTrue(revoke.exists(within: Self.actionTimeout),
                      "a guest on an agent-less saved machine must be listed")
        XCTAssertTrue(text(containing: "notes on mcb-air").exists, "the row must name the machine that holds it")
        revoke.tap()
        XCTAssertTrue(app.staticTexts["Revoke sam?"].exists(within: Self.actionTimeout))
        app.buttons["Revoke"].firstMatch.tap()
        XCTAssertTrue(revoke.gone(within: Self.actionTimeout))
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "only sam is revoked")
    }

    /// A failed guest.audit must read as a failure, not as a guest who did nothing, and must
    /// not hide the people and invites that did load.
    func testAFailedAuditSaysSoInsteadOfAnEmptyLog() {
        launch("sharedaccess", pendingInvite: true, environment: ["HERDR_MOCK_AUDIT_FAIL": "1"])
        openSharedAccess()
        let failure = element("guest-log-failure")
        XCTAssertTrue(failure.exists(within: Self.actionTimeout), "the audit failure must be shown")
        XCTAssertTrue(failure.label.contains("Couldn't load the activity log"))
        XCTAssertTrue(failure.label.contains("audit.jsonl is unreadable"), "the reason must be shown: \(failure.label)")
        XCTAssertFalse(text(containing: "Nothing yet").exists, "a failed log is not an empty one")
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "people still load")
        XCTAssertTrue(element("guest-cancel-sam").exists, "invites still load")
        shoot("owner-7-audit-failed")
    }

    // MARK: Share Gram (herdrup#338)

    /// Taps a SwiftUI switch row on its switch (the right edge), until its value reads `on`.
    private func setSwitch(_ id: String, on: Bool) {
        let row = element(id)
        XCTAssertTrue(row.exists(within: Self.actionTimeout), "\(id) is missing")
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        let want = on ? "1" : "0"
        for _ in 0..<3 where (row.value as? String) != want {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            _ = poll(3, every: 0.25) { (row.value as? String) == want }
        }
        XCTAssertEqual(row.value as? String, want, "\(id) should be \(on ? "on" : "off")")
    }

    func testShareGramIsOffByDefaultAndGoesOutWithTheInvite() {
        launch("share")
        openShareSheet()
        typeGuestName("plotarmordev\n")
        let toggle = element("guest-share-gram")
        XCTAssertTrue(toggle.exists(within: Self.actionTimeout), "the sheet should offer Share Gram")
        XCTAssertEqual(toggle.value as? String, "0", "Gram is not shared unless the owner asks")
        setSwitch("guest-share-gram", on: true)
        shoot("guest-gram-owner-share-switch")
        element("guest-share-create").tap()
        let gram = element("guest-invite-gram")
        XCTAssertTrue(gram.exists(within: Self.actionTimeout), "the invite should state its Gram sharing")
        XCTAssertTrue(gram.label.contains("Shared") && !gram.label.contains("Not shared"),
                      "the daemon stored share_gram: \(gram.label)")
    }

    func testSharedAccessTurnsShareGramOnForAnExistingGuest() {
        launch("sharedaccess")
        openSharedAccess()
        XCTAssertEqual(element("guest-share-gram-plotarmordev").value as? String, "0")
        setSwitch("guest-share-gram-plotarmordev", on: true)
        XCTAssertTrue(text(containing: "llm-opt on Jerry's Mac Studio · Gram shared").exists(within: Self.actionTimeout), "the reloaded list shows the guest.update")
        shoot("guest-gram-owner-guest-toggle")
    }
}
