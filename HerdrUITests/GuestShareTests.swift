import UIKit
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

    /// Opens a PEOPLE row's page, where the guest's agents, devices and removal live.
    private func openPerson(_ name: String) {
        let row = element("guest-person-\(name)")
        XCTAssertTrue(row.exists(within: Self.actionTimeout), "\(name) should be listed")
        row.tap()
        XCTAssertTrue(element("guest-person-header").exists(within: Self.actionTimeout), "\(name)'s page did not open")
    }

    /// Remove <name> on the open person page, through its confirmation; the page closes.
    private func removePerson(_ name: String, shot: String? = nil) {
        let remove = element("guest-person-remove")
        XCTAssertTrue(remove.exists(within: Self.actionTimeout))
        for _ in 0..<3 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        // iOS 27 nests a button of the same label inside each alert action: `.firstMatch`
        // or the tap fails on "Multiple matching elements found".
        let confirm = app.alerts.buttons["Remove \(name)"].firstMatch
        XCTAssertTrue(confirm.exists(within: Self.actionTimeout), "removing must ask for confirmation")
        XCTAssertTrue(app.staticTexts["Remove \(name)?"].exists)
        if let shot { shoot(shot) }
        XCTAssertTrue(remove.exists, "nothing is revoked before the confirmation")
        confirm.tap()
        XCTAssertTrue(remove.gone(within: Self.actionTimeout), "the page closes once \(name) is gone")
    }

    func testSharedAccessListsPeopleAndTheActivityLog() {
        launch("sharedaccess")
        openSharedAccess()
        XCTAssertTrue(element("guest-person-plotarmordev").exists(within: Self.actionTimeout))
        XCTAssertTrue(text(containing: "llm-opt on Jerry's Mac Studio").exists)
        XCTAssertTrue(text(containing: "Only this device · iPhone").exists, "a share from before accounts is one device")
        XCTAssertTrue(text(containing: "active · 2 min ago").exists)

        // The log, newest first: upload, prompt, joined.
        let entries = app.descendants(matching: .any).matching(identifier: "guest-log-entry")
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.element(boundBy: 0).label.contains("prompt-set-v2.jsonl"))
        XCTAssertTrue(entries.element(boundBy: 1).label.contains("rerun the TensorFold bench"))
        XCTAssertTrue(entries.element(boundBy: 2).label.contains("Accepted your invite"))
        shoot("owner-3-shared-access")

        openPerson("plotarmordev")
        XCTAssertTrue(element("guest-device-iPhone").label.contains("SHA256:9f3a·e71c·04bd·c21e"),
                      "the device's key fingerprint must be shown")
    }

    func testRevokeAsksFirstThenRemovesThePersonAndLogsIt() {
        launch("sharedaccess")
        openSharedAccess()
        openPerson("plotarmordev")
        removePerson("plotarmordev", shot: "owner-5-revoke-confirm")

        XCTAssertTrue(text(containing: "Nobody has access").exists(within: Self.actionTimeout))
        XCTAssertFalse(element("guest-person-plotarmordev").exists)
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
        XCTAssertTrue(element("guest-person-plotarmordev").exists, "cancelling an invite must not touch guests")
    }

    /// mcb-air is a saved machine with no agents, so nothing in the agent list names it. Its
    /// guest must still be listed, from its own daemon, and be revocable there.
    func testAGuestOnASavedMachineWithoutAgentsIsListedAndRevocable() {
        launch("sharedaccess", environment: ["HERDR_MOCK_SAVED_PEER_GUEST": "1"])
        openSharedAccess()
        let row = element("guest-person-sam")
        XCTAssertTrue(row.exists(within: Self.actionTimeout),
                      "a guest on an agent-less saved machine must be listed")
        XCTAssertTrue(text(containing: "notes on mcb-air").exists, "the row must name the machine that holds it")
        openPerson("sam")
        removePerson("sam")
        XCTAssertTrue(element("guest-person-plotarmordev").exists(within: Self.actionTimeout), "only sam is revoked")
        XCTAssertFalse(row.exists)
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
        XCTAssertTrue(element("guest-person-plotarmordev").exists, "people still load")
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
        openPerson("plotarmordev")
        XCTAssertEqual(element("guest-share-gram-llm-opt").value as? String, "0")
        setSwitch("guest-share-gram-llm-opt", on: true)
        XCTAssertTrue(text(containing: "on Jerry's Mac Studio · since").exists, "the agent row names the machine")
        XCTAssertTrue(text(containing: "· Gram shared").exists(within: Self.actionTimeout),
                      "the reloaded page shows the guest.update")
        shoot("guest-gram-owner-guest-toggle")
    }

    // MARK: People with a HerdrUp account (account-linked shares, frames o1-o3)

    /// The account-shares design's people (`HERDR_MOCK_ACCOUNT_PEOPLE=1`): Nike holds llm-opt
    /// and orgstudio on her HerdrUp account (iPhone, MacBook, a browser), sam a plain share on
    /// one iPhone.
    private func openAccountPeople() {
        launch("sharedaccess", environment: ["HERDR_MOCK_ACCOUNT_PEOPLE": "1"])
        openSharedAccess()
    }

    /// A design comparison shot, kept as `iphone-`/`ipad-` + `name` (as TopicsDesignShotsTests).
    private func designShot(_ name: String) {
        attach(app.screenshot(), (UIDevice.current.userInterfaceIdiom == .pad ? "ipad-" : "iphone-") + name)
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
    }

    /// o1: one row per person. Nike's two shares are one row naming both agents and every
    /// device; sam's plain share says it is one device; the log has Nike's added device.
    func testPeopleListOneRowPerPersonWithTheirDevices() {
        openAccountPeople()
        let nike = element("guest-person-Nike")
        XCTAssertTrue(nike.exists(within: Self.actionTimeout))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "guest-person-Nike").count, 1,
                       "two shares of one account are one person")
        XCTAssertTrue(nike.label.contains("llm-opt, orgstudio on Jerry's Mac Studio"), nike.label)
        XCTAssertTrue(nike.label.contains("HerdrUp account · iPhone, MacBook, Browser (Chrome on macOS)"), nike.label)
        XCTAssertTrue(nike.label.contains("active"), nike.label)

        let sam = element("guest-person-sam")
        XCTAssertTrue(sam.exists)
        XCTAssertTrue(sam.label.contains("llm-opt on Jerry's Mac Studio"), sam.label)
        XCTAssertTrue(sam.label.contains("Only this device · iPhone"), sam.label)
        XCTAssertTrue(text(containing: "2 people · 2 agents").exists, "the header counts people, not shares")

        let added = text(containing: "Nike added a device")
        XCTAssertTrue(added.exists, "the activity log shows the added device")
        XCTAssertTrue(added.label.contains("Browser (Chrome on macOS)"), added.label)
        designShot("shares-o1-people")
    }

    /// o2: Nike's page lists both agents and all three devices; ⋯ → Remove device takes the
    /// MacBook off every share it may use.
    func testPersonPageListsAgentsAndDevicesAndRemovesADevice() {
        openAccountPeople()
        openPerson("Nike")
        let header = element("guest-person-header")
        XCTAssertTrue(header.label.contains("HerdrUp account · 3 devices"), header.label)
        XCTAssertTrue(header.label.contains("Active now on iPhone"), header.label)
        for agent in ["llm-opt", "orgstudio"] {
            XCTAssertTrue(element("guest-agent-\(agent)").exists, "\(agent) is listed")
            XCTAssertTrue(element("guest-agent-remove-\(agent)").exists, "\(agent) has its own Remove")
        }
        for device in ["iPhone", "MacBook", "Browser (Chrome on macOS)"] {
            XCTAssertTrue(element("guest-device-\(device)").exists, "\(device) is listed")
            XCTAssertTrue(element("guest-device-menu-\(device)").exists, "\(device) has its ⋯")
        }
        XCTAssertTrue(element("guest-device-iPhone").label.contains("active now"))
        XCTAssertTrue(text(containing: "signs in to HerdrUp there and opens a share").exists)
        XCTAssertFalse(text(containing: "notification").exists, "a new device sends the owner no push")
        XCTAssertTrue(element("guest-person-remove").exists)
        designShot("shares-o2-person")

        let menu = element("guest-device-menu-MacBook")
        reveal(menu)
        menu.tap()
        let remove = app.buttons["Remove device"].firstMatch
        XCTAssertTrue(remove.exists(within: Self.actionTimeout), "⋯ offers Remove device")
        remove.tap()
        XCTAssertTrue(element("guest-device-MacBook").gone(within: Self.actionTimeout), "the MacBook is removed")
        XCTAssertTrue(element("guest-device-iPhone").exists && element("guest-device-Browser (Chrome on macOS)").exists,
                      "the other devices keep the share")
        XCTAssertTrue(header.label.contains("HerdrUp account · 2 devices"), header.label)
    }

    /// An agent's Remove ends that one share only.
    func testRemovingOneAgentKeepsTheOther() {
        openAccountPeople()
        openPerson("Nike")
        let remove = element("guest-agent-remove-orgstudio")
        XCTAssertTrue(remove.exists)
        remove.tap()
        let confirm = app.alerts.buttons["Remove orgstudio"].firstMatch
        XCTAssertTrue(confirm.exists(within: Self.actionTimeout), "removing an agent asks first")
        confirm.tap()
        XCTAssertTrue(element("guest-agent-orgstudio").gone(within: Self.actionTimeout))
        XCTAssertTrue(element("guest-agent-llm-opt").exists, "Nike keeps llm-opt")
    }

    /// o3: Remove Nike asks first, naming the agents, the machine and every device, then
    /// revokes the person: the page closes and her row is gone, sam's stays.
    func testRemovingAPersonAsksThenRemovesEveryShare() {
        openAccountPeople()
        openPerson("Nike")
        let remove = element("guest-person-remove")
        reveal(remove)
        remove.tap()
        let confirm = app.alerts.buttons["Remove Nike"].firstMatch
        XCTAssertTrue(confirm.exists(within: Self.actionTimeout), "removing Nike asks first")
        XCTAssertTrue(app.staticTexts["Remove Nike?"].exists)
        XCTAssertTrue(text(containing: "Nike loses llm-opt and orgstudio on Jerry's Mac Studio on all 3 devices").exists,
                      "the confirmation names what goes")
        XCTAssertTrue(app.alerts.buttons["Cancel"].firstMatch.exists)
        designShot("shares-o3-confirm")
        confirm.tap()

        XCTAssertTrue(remove.gone(within: Self.actionTimeout), "the page closes once Nike is gone")
        XCTAssertTrue(element("guest-person-sam").exists(within: Self.actionTimeout), "sam keeps his share")
        XCTAssertFalse(element("guest-person-Nike").exists, "Nike's row is gone")
        XCTAssertTrue(text(containing: "Access revoked").exists(within: Self.actionTimeout),
                      "the revoke shows in the activity log")
    }
}
