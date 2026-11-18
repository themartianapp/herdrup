import UIKit
import XCTest

/// A guest's Gram tab and push for the shared agent (herdrup#338), over GuestMockTransport.
/// `HERDR_MOCK_GUEST_FEATURES` sets what the mock host's hello advertises. The DEBUG probes
/// `guest-host-calls` (the Gram and push calls the host answered, with their arguments) and
/// `guest-forbidden-calls` (calls it refused) are the host's side of each check.
final class GuestGramPaneTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// `HERDR_MOCK_STILL` keeps the agent idle: the WORKING pill's pulse never ends, and an
    /// app that never idles costs every XCUITest action its full idle timeout.
    private func launch(_ mock: String = "guestpane", features: String?,
                        environment: [String: String] = [:]) -> XCUIApplication {
        var still = ["HERDR_MOCK_STILL": "1"]
        if let features { still["HERDR_MOCK_GUEST_FEATURES"] = features }
        return .launched(mock: mock, environment: still.merging(environment) { _, new in new })
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func probe(_ app: XCUIApplication, _ id: String) -> String {
        let probe = element(app, id)
        XCTAssertTrue(probe.exists(within: 5), "the DEBUG probe \(id) should exist")
        return probe.label
    }

    /// The agent page's Gram button opens the shell's Gram tab on that agent's own feed (#697).
    private func openAgentPage(_ app: XCUIApplication) {
        let row = app.buttons["guest-agent-row"]
        XCTAssertTrue(row.exists(within: 10), "the shared agent's row should render")
        row.tap()
    }

    private func openGramTab(_ app: XCUIApplication) {
        let tab = app.buttons["guest-tab-gram"]
        // Already on the agent page (a test that checked its badge first): don't tap the row
        // under it again.
        if !tab.exists { openAgentPage(app) }
        XCTAssertTrue(tab.exists(within: 10), "a host that shares Gram should offer the Gram button")
        let list = element(app, "guest-gram-list")
        for _ in 0..<3 where !list.exists {
            if tab.exists { tab.tap() }
            _ = list.exists(within: 3)
        }
        // Which half failed, if one did: the shell's tab, or the agent's feed in it.
        XCTAssertTrue(app.tabBars.buttons["Gram"].isSelected, "the Gram button should select the shell's Gram tab")
        XCTAssertTrue(list.exists, "the Gram button should open the agent's Gram")
    }

    // MARK: Gram tab

    /// The agent's Gram lists its Grams and the guest's own post, oldest first as the owner's
    /// Gram does, and counts the unread ones until the guest looks: then they are marked read
    /// on the host, for this guest only.
    func testGramTabListsTheSharedAgentsGramsAndMarksThemReadWhenViewed() {
        let app = launch("guest", features: "gram")
        openAgentPage(app)
        let badge = element(app, "guest-gram-unread")
        XCTAssertTrue(badge.exists(within: 10), "unread Grams should show a count before Gram opens")
        XCTAssertEqual(badge.label, "2")
        XCTAssertTrue(app.buttons["guest-tab-terminal"].exists)

        openGramTab(app)
        XCTAssertTrue(app.tabBars.buttons["Gram"].isSelected, "the Gram button lands on the shell's Gram tab")
        let rows = ["gm-1", "gm-2", "gm-3", "gm-4"].map { element(app, "guest-gram-row-\($0)") }
        for row in rows { XCTAssertTrue(row.exists(within: 5), "row \(row) should render") }
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY, "oldest first")
        XCTAssertLessThan(rows[2].frame.minY, rows[3].frame.minY, "oldest first")
        XCTAssertTrue(app.staticTexts["Here's the Q5 table: decode is up 36% over Q4, prefill flat."].exists)
        XCTAssertTrue(app.staticTexts["Delivered to llm-opt"].exists,
                      "the guest's own post carries the owner's status line to the agent")
        XCTAssertTrue(app.buttons["guest-gram-file-gm-4"].exists, "the agent's file is offered")

        pollLabel(app, "guest-host-calls", "viewing the list should mark its unread Grams read") {
            $0.contains("gram.mark_read:gm-2,gm-4")
        }
        rows[3].waitForSettledFrame()
        attach(app, "guest-gram-tab")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "", "the Gram tab calls only what a guest may")
    }

    /// The owner's conversation: oldest at the top, opening pinned to the bottom with the
    /// newest Gram in view above the composer; the guest's own post sits on the right, the
    /// agent's on the left under one sender line per run.
    func testGramTabIsOldestFirstWithTheNewestVisibleAtTheBottom() {
        let app = launch("guest", features: "gram")
        openGramTab(app)
        let newest = element(app, "guest-gram-row-gm-4")
        let mine = element(app, "guest-gram-row-gm-3")
        let older = element(app, "guest-gram-row-gm-2")
        XCTAssertTrue(newest.exists(within: 5))
        XCTAssertTrue(poll(5, every: 0.25) { newest.isHittable }, "the newest Gram is in view on open")
        let input = element(app, "guest-gram-composer")
        XCTAssertTrue(input.exists)
        XCTAssertLessThan(newest.frame.maxY, input.frame.minY + 1, "the newest Gram sits above the composer")
        // Pinned to the bottom: nothing is drawn below the newest.
        for id in ["gm-0", "gm-1", "gm-2", "gm-3"] {
            XCTAssertLessThan(element(app, "guest-gram-row-\(id)").frame.maxY, newest.frame.maxY,
                              "the newest Gram is the last row")
        }
        XCTAssertLessThan(older.frame.minY, mine.frame.minY, "oldest first")
        XCTAssertLessThan(mine.frame.minY, newest.frame.minY, "oldest first")
        XCTAssertGreaterThan(mine.frame.midX, older.frame.midX, "the guest's own post sits on the right")
        XCTAssertFalse(element(app, "guest-view-only-note").exists, "the view-only note is the terminal's")
        XCTAssertFalse(app.buttons["guest-find"].exists, "Find is the terminal's")
        newest.waitForSettledFrame()
        attach(app, "guest-gram-oldest-first")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// An older page that fails says so on the top sentinel with a retry, instead of spinning
    /// on "Loading older messages…" with nothing left to re-trigger it (herdrup#473); a tap
    /// asks again and the page lands above the first one. The first page is taller than the
    /// screen (gm-f30 its oldest), so only the reader's scroll up asks for the older page.
    func testAFailedOlderPageOffersARetryThatLoadsIt() {
        let app = launch("guest", features: "gram", environment: ["HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE": "1"])
        openGramTab(app)
        XCTAssertTrue(element(app, "guest-gram-row-gm-4").exists(within: 5))
        let list = element(app, "guest-gram-list")
        let sentinel = element(app, "guest-gram-loading-older")
        let retry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Tap to retry")).firstMatch
        // Up to the top, and no further (a pull there refreshes): the sentinel comes on screen
        // and asks for the older page, which fails.
        for _ in 0..<12 where !(sentinel.exists && sentinel.isHittable) && !retry.exists {
            list.swipeDown()
        }
        XCTAssertTrue(retry.exists(within: 8),
                      "the failed page should offer a retry, not spin; sentinel says \(sentinel.exists ? sentinel.label : "nothing")")
        XCTAssertFalse(element(app, "guest-gram-row-gm-older-1").exists, "the failed page drew nothing")
        attach(app, "guest-gram-older-page-failed")

        retry.tap()
        let older = element(app, "guest-gram-row-gm-older-1")
        XCTAssertTrue(older.exists(within: 8), "the retry should load the older page")
        XCTAssertLessThan(older.frame.minY, element(app, "guest-gram-row-gm-f30").frame.minY,
                          "the older page sits above the first one")
        XCTAssertFalse(retry.exists, "the failure clears once the page loads")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// herdr#298: a file the host's store expired (gm-0, a picture with no caption) draws as
    /// a chip naming it "no longer available", never an empty row body. It is not a button
    /// and tapping it fetches nothing from the host.
    func testAnExpiredGramFileDrawsAsAnInertChip() {
        let app = launch("guest", features: "gram")
        openGramTab(app)
        let row = element(app, "guest-gram-row-gm-0")
        XCTAssertTrue(row.exists(within: 5), "the expired message keeps its row")
        let list = element(app, "guest-gram-list")
        // The oldest message sits at the top of the bottom-pinned feed.
        for _ in 0..<4 where !row.isHittable { list.swipeDown() }
        let chip = element(app, "guest-gram-expired-gm-0")
        XCTAssertTrue(chip.exists(within: 3), "the row should show the expired file")
        XCTAssertEqual(chip.label, "q4-baseline.png, no longer available")
        XCTAssertNotEqual(chip.elementType, .button, "an expired file is not a button")
        XCTAssertFalse(app.buttons["guest-gram-file-gm-0"].exists, "nothing offers it to open")

        chip.tap()
        // Kept: an inert tap must have had time to act before "nothing was fetched" means anything.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(probe(app, "guest-host-calls").contains("gram.get_file_chunk:gm-0"),
                       "tapping the expired chip fetches nothing")
    }

    /// A file downloads from the host in its bounded pieces and opens.
    func testOpeningAGramFileDownloadsItInPiecesAndOpensIt() {
        let app = launch("guest", features: "gram")
        openGramTab(app)
        let file = app.buttons["guest-gram-file-gm-4"]
        XCTAssertTrue(file.exists(within: 5))
        file.tap()

        // The viewer covers the pane; its probe reappears once the viewer is dismissed.
        let opened = { (calls: String) in calls.contains("opened:tensorfold-q5.md") }
        let deadline = Date().addingTimeInterval(20)
        var calls = ""
        while Date() < deadline {
            let probe = element(app, "guest-host-calls")
            if probe.exists { calls = probe.label; if opened(calls) { break } }
            for label in ["Done", "Close"] where app.buttons[label].exists {
                attach(app, "guest-gram-file-open")
                app.buttons[label].tap()
            }
            // Kept: the poll loop's interval between re-checks of the probe.
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(opened(calls), "the file should download and open: \(calls)")
        XCTAssertTrue(calls.contains("gram.get_file_chunk:gm-4@0"), calls)
        XCTAssertTrue(calls.contains("gram.get_file_chunk:gm-4@1024"), "later pieces start where the last ended: \(calls)")
        XCTAssertFalse(element(app, "guest-gram-file-error").exists, "the download should not fail")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// Without Gram sharing, or on a host older than the features object, there is no Gram
    /// button or tab and the app never asks for Gram.
    func testNoGramTabWhenTheHostDoesNotShareGram() {
        for features in ["none", nil] as [String?] {
            let app = launch("guest", features: features)
            openAgentPage(app)
            XCTAssertTrue(element(app, "guest-terminal").exists(within: 10))
            XCTAssertTrue(element(app, "guest-view-only-note").exists(within: 10))
            // Kept: a negative check; the features answer must have had time to add a Gram button or tab.
            Thread.sleep(forTimeInterval: 3)
            XCTAssertFalse(app.buttons["guest-tab-gram"].exists, "no Gram button for features \(String(describing: features))")
            XCTAssertFalse(app.tabBars.buttons["Gram"].exists, "no Gram tab for features \(String(describing: features))")
            XCTAssertFalse(element(app, "guest-push-prompt").exists, "no push offer without push")
            XCTAssertEqual(probe(app, "guest-forbidden-calls"), "", "the app must not ask for Gram")
            XCTAssertEqual(probe(app, "guest-host-calls"), "")
            app.terminate()
        }
    }

    // MARK: Push

    /// The first open on a host that takes guest push explains why, then "Turn on" registers
    /// this device's token with every status kind on and Gram pushes as shared.
    func testTurningOnPushRegistersThisDeviceWithTheHost() {
        let app = launch(features: "gram,push")
        let prompt = element(app, "guest-push-prompt")
        XCTAssertTrue(prompt.exists(within: 10), "the first open should explain notifications")
        XCTAssertEqual(probe(app, "guest-host-calls").contains("notifications.register_device"), false,
                       "nothing registers before the guest says yes")
        attach(app, "guest-push-prompt")
        app.buttons["guest-push-enable"].tap()

        pollLabel(app, "guest-host-calls", "Turn on should register the device") {
            $0.contains("notifications.register_device:device_token=mock-apns-token-guest,platform=apns,"
                + "notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=true")
        }
        XCTAssertTrue(prompt.gone(within: 5), "the explanation goes once answered")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// Where the owner doesn't share Gram, the device registers for status pushes only.
    func testPushWithoutGramRegistersStatusKindsOnly() {
        let app = launch(features: "push")
        let enable = app.buttons["guest-push-enable"]
        XCTAssertTrue(enable.exists(within: 10))
        enable.tap()
        pollLabel(app, "guest-host-calls", "Turn on should register the device") {
            $0.contains("notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=false")
        }
        XCTAssertFalse(app.buttons["guest-tab-gram"].exists)
    }

    /// A tapped Gram push for the share opens its agent on the Gram tab; a status push opens
    /// the terminal. Neither lands on an owner screen.
    func testTappedGuestPushOpensTheSharesGramOrTerminal() {
        let payload = { (kind: String) in
            #"{"aps":{"alert":{"title":"llm-opt","body":"New Gram"}},"herdr_guest":{"host_id":"AAECAwQFBgcICQoLDA0ODw","guest_id":"g-7f2c","kind":"\#(kind)","gram_id":"gm-4"}}"#
        }
        var app = launch("guest", features: "gram", environment: ["HERDR_MOCK_PUSH_TAP": payload("gram")])
        XCTAssertTrue(element(app, "guest-gram-list").exists(within: 15),
                      "a Gram push should open the share's Gram tab")
        XCTAssertTrue(element(app, "guest-gram-row-gm-4").exists(within: 5))
        app.terminate()

        app = launch("guest", features: "gram", environment: ["HERDR_MOCK_PUSH_TAP": payload("status")])
        XCTAssertTrue(element(app, "guest-terminal").exists(within: 15),
                      "a status push should open the share's terminal")
        XCTAssertTrue(app.buttons["guest-tab-gram"].exists(within: 5))
        XCTAssertFalse(element(app, "guest-gram-list").exists, "a status push opens the terminal, not Gram")
    }

    // MARK: One Gram across agents (#697)

    /// Review 3 (#702): a page that failed under the floor, then the conversation left and
    /// reopened. The reopened feed's refresh clears the failure, and that alone must page
    /// again: on fd1d1a5e the floor task had exited on the old failure and its id
    /// (floor/hidden/attempts) didn't change when the refresh cleared it, so the screen kept
    /// a disabled spinner with no rows forever.
    func testReopeningAfterAFailedFloorPageLoadsTheRows() {
        let app = launch("guest", features: "gram", environment: [
            "HERDR_MOCK_GUEST_GRAM_ONE_MS_PAGE": "1", "HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE": "1",
        ])
        openGramTab(app)
        let pager = element(app, "guest-gram-loading-older")
        XCTAssertTrue(poll(10, every: 0.25) { pager.exists && pager.label.contains("Tap to retry") },
                      "the first older page fails under the floor")
        let back = app.buttons["guest-gram-back"]
        XCTAssertTrue(back.exists(within: 5))
        back.tap()
        let row = app.buttons["guest-gram-agent-w1-3"]
        XCTAssertTrue(row.exists(within: 5), "back on the inbox list")
        row.tap()
        XCTAssertTrue(element(app, "guest-gram-row-gm-4").exists(within: 10),
                      "reopened, the feed pages on by itself and shows its rows")
        XCTAssertTrue(element(app, "guest-gram-row-gm-2").exists)
        XCTAssertFalse(pager.exists && pager.label.contains("Loading older"), "no spinner left behind")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// A first page the strict floor hides entirely (one Gram, more to come) pages on by
    /// itself; when that page fails, the screen says so with Retry instead of spinning, and
    /// the tap loads it.
    func testAFailedPageUnderTheFloorOffersRetry() {
        let app = launch("guest", features: "gram", environment: [
            "HERDR_MOCK_GUEST_GRAM_ONE_MS_PAGE": "1", "HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE": "1",
        ])
        openGramTab(app)
        let retry = element(app, "guest-gram-loading-older")
        XCTAssertTrue(poll(10, every: 0.25) { retry.exists && retry.label.contains("Tap to retry") },
                      "the failed page offers Retry: \(retry.exists ? retry.label : "none")")
        XCTAssertFalse(element(app, "guest-gram-row-gm-4").exists, "the floor still hides the held Gram")
        attach(app, "guest-gram-floor-page-failed")
        retry.tap()
        XCTAssertTrue(element(app, "guest-gram-row-gm-4").exists(within: 10), "Retry loads the page")
        XCTAssertTrue(element(app, "guest-gram-row-gm-2").exists, "with the older Grams")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// Two shared agents with Gram on one machine: the Gram tab's "All agents" row opens one
    /// feed with both agents' Grams under their names, and a Reply from one message's menu
    /// goes to that message's agent, though the composer's default is the newest one's.
    func testAllAgentsFeedMergesAgentsAndRepliesToTheMessagesAgent() {
        let app = launch("guestmachine", features: "gram")
        let gramTab = app.tabBars.buttons["Gram"]
        XCTAssertTrue(gramTab.exists(within: 15), "shares with Gram add the shell's Gram tab")
        gramTab.tap()
        let all = app.buttons["guest-gram-all"]
        XCTAssertTrue(all.exists(within: 10), "the inbox opens with the All agents row")
        XCTAssertTrue(app.buttons["guest-gram-agent-w1-3"].exists, "one row per shared agent")
        XCTAssertTrue(app.buttons["guest-gram-agent-w2-4"].exists, "one row per shared agent")
        XCTAssertTrue(app.buttons["guest-gram-agent-w2-9"].exists, "one row per shared agent")
        attach(app, "guest-gram-inbox")
        all.tap()

        let llm = element(app, "guest-gram-row-gm-4")
        let enyo = element(app, "guest-gram-row-gm-e2")
        XCTAssertTrue(llm.exists(within: 10), "llm-opt's Gram is in the combined feed")
        XCTAssertTrue(enyo.exists(within: 5), "enyo-ui's Gram is in the combined feed")
        XCTAssertTrue(app.staticTexts["llm-opt"].exists, "each agent's Grams carry its name")
        XCTAssertTrue(app.staticTexts["enyo-ui"].exists, "each agent's Grams carry its name")
        XCTAssertLessThan(enyo.frame.minY, llm.frame.minY, "enyo-ui's (5 min ago) sits above llm-opt's (2 min ago)")
        let to = element(app, "guest-gram-to")
        XCTAssertTrue(to.exists(within: 5))
        XCTAssertEqual(to.value as? String, "llm-opt", "a new message defaults to the newest Gram's agent")

        enyo.press(forDuration: 1.2)
        let reply = app.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.exists(within: 5), "a message's menu offers Reply")
        reply.tap()
        XCTAssertEqual(to.value as? String, "enyo-ui · Jerry · Jerry's Mac Studio · w2-4",
                       "Reply addresses the composer to the message's agent, told apart from the other enyo-ui")
        let composer = element(app, "guest-gram-composer")
        composer.tap()
        composer.typeText("Ship it")
        app.buttons["guest-gram-send"].tap()
        let calls = pollLabel(app, "guest-host-calls", "the reply should post to enyo-ui's grant") {
            $0.contains("gram.post.to:")
        }
        XCTAssertTrue(calls.contains("gram.post.to:enyo-ui@w2-4"), "the reply went to enyo-ui's share: \(calls)")
        XCTAssertFalse(calls.contains("gram.post.to:llm-opt"), "nothing went to llm-opt: \(calls)")
        attach(app, "guest-gram-all-agents-reply")
    }

    /// Only a Gram tab on screen marks what it shows read: a Gram that lands while the guest
    /// is on Agents is fetched but stays unread until the Gram tab is back.
    func testAHiddenGramTabDoesNotMarkArrivalsRead() {
        let app = launch("guestmachine", features: "gram", environment: ["HERDR_MOCK_GUEST_GRAM_ARRIVAL": "1"])
        let gramTab = app.tabBars.buttons["Gram"]
        XCTAssertTrue(gramTab.exists(within: 15))
        gramTab.tap()
        let all = app.buttons["guest-gram-all"]
        XCTAssertTrue(all.exists(within: 10))
        all.tap()
        pollLabel(app, "guest-host-calls", "the open feed marks what it shows") { $0.contains("gm-e2") }

        app.tabBars.buttons["Agents"].tap()
        let lists = probe(app, "guest-host-calls").components(separatedBy: "gram.list").count
        let arrives = app.buttons["guest-fixture-gram-arrives"]
        XCTAssertTrue(arrives.exists(within: 5))
        arrives.tap()
        pollLabel(app, "guest-host-calls", "the arrival is fetched") {
            $0.components(separatedBy: "gram.list").count > lists
        }
        // Kept: a negative check; a hidden tab's wrongful mark_read must have had time to go out.
        Thread.sleep(forTimeInterval: 3)
        let hidden = probe(app, "guest-host-calls")
        XCTAssertFalse(hidden.components(separatedBy: ";").contains { $0.hasPrefix("gram.mark_read") && $0.contains("gm-e3") },
                       "a hidden Gram tab must not mark the arrival read: \(hidden)")

        gramTab.tap()
        pollLabel(app, "guest-host-calls", "back on the Gram tab, the arrival is read") {
            $0.components(separatedBy: ";").contains { $0.hasPrefix("gram.mark_read") && $0.contains("gm-e3") }
        }
    }

    // MARK: Attachments

    /// An accepted asynchronous provider belongs to this draft. Neither the Send
    /// button nor the shared command-return action may snapshot the draft first.
    func testSendWaitsForAnAcceptedDropToFinishStaging() {
        let app = launch(features: nil, environment: ["HERDR_MOCK_DELAYED_DROP": "1"])
        let input = app.textViews["guest-composer-input"]
        XCTAssertTrue(input.exists(within: 10))
        input.tap()
        input.typeText("summarise this")
        app.buttons["guest-fixture-drop-file"].tap()
        let finish = app.buttons["guest-fixture-finish-staging"]
        XCTAssertTrue(poll(10, every: 0.25) { finish.isEnabled },
                      "the real item provider should be waiting for its bytes")
        let send = app.buttons["guest-send-button"]
        XCTAssertFalse(send.isEnabled, "Send must wait for the accepted file")
        // Exercise the same send() entry point as command-return even though its
        // visible button is disabled. This is not a physical keyboard event.
        app.buttons["guest-fixture-send-shortcut"].tap()
        finish.tap()
        let chip = app.buttons["Remove delayed-report.pdf"]
        XCTAssertTrue(chip.exists(within: 10))
        XCTAssertTrue(poll(10, every: 0.25) { send.isEnabled })
        send.tap()
        let calls = pollLabel(app, "guest-host-calls", "the complete draft should be delivered",
                              timeout: 15) { $0.contains("agent.prompt:") }
            .components(separatedBy: ";")
        let prompts = calls.filter { $0.hasPrefix("agent.prompt:") }
        XCTAssertEqual(prompts.count, 1, "no text-only message may overtake the file: \(calls)")
        XCTAssertTrue(prompts.first?.contains("summarise this") == true)
        XCTAssertTrue(prompts.first?.contains("delayed-report.pdf") == true)
        XCTAssertTrue(poll(10, every: 0.25) { !chip.exists })
        attach(app, "guest-delayed-drop-delivered")
    }

    /// herdrup#345: the host answers a guest's `gram.post` with its guest projection (no
    /// direction or read fields). The app took that for a failure after the post had landed, so
    /// the agent was never prompted and the next Send re-posted an upload the host had used up.
    func testAttachingAFileUploadsPostsAndPromptsTheAgent() {
        let app = launch(features: nil, environment: ["HERDR_MOCK_PICKED_FILE": "1"])
        let calls = sendWithAttachment(app, text: "summarise this")

        XCTAssertEqual(calls.filter { $0.hasPrefix("gram.upload_chunk:") }.count, 1, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("gram.upload.discard:") },
                       "a sent file's upload is consumed by its post, not discarded: \(calls)")
        let posts = calls.filter { $0.hasPrefix("gram.post:") }
        XCTAssertEqual(posts.count, 1, "one post for the one file: \(calls)")
        XCTAssertTrue(posts.first?.hasPrefix("gram.post:picked-notes.txt@") == true, "\(posts)")
        XCTAssertTrue(posts.first?.hasSuffix("=gp-1") == true, "the post should land: \(posts)")
        let prompt = calls.first { $0.hasPrefix("agent.prompt:") } ?? ""
        XCTAssertTrue(prompt.hasPrefix("agent.prompt:summarise this"), prompt)
        XCTAssertTrue(prompt.contains("File picked-notes.txt attached via Herdr Gram message gp-1"), prompt)
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// A post the host refuses for want of a staged upload (an earlier post used it) uploads the
    /// file again and posts once more, instead of failing the send on every retry.
    func testAStaleUploadIsUploadedAgainAndPostedOnce() {
        let app = launch(features: nil, environment: ["HERDR_MOCK_PICKED_FILE": "1",
                                                      "HERDR_MOCK_GUEST_STALE_UPLOAD": "1"])
        let calls = sendWithAttachment(app, text: "")

        let uploads = calls.filter { $0.hasPrefix("gram.upload_chunk:") }
        XCTAssertEqual(uploads.count, 2, "the refused upload is replaced: \(calls)")
        XCTAssertNotEqual(uploads.first, uploads.last, "under a fresh upload id: \(uploads)")
        let posts = calls.filter { $0.hasPrefix("gram.post:") }
        XCTAssertEqual(posts.count, 2, "\(calls)")
        XCTAssertTrue(posts.first?.hasSuffix("=no_staged_upload") == true, "\(posts)")
        XCTAssertTrue(posts.last?.hasSuffix("=gp-1") == true, "\(posts)")
        let prompt = calls.first { $0.hasPrefix("agent.prompt:") } ?? ""
        XCTAssertTrue(prompt.contains("File picked-notes.txt attached via Herdr Gram message gp-1"), prompt)
    }

    /// herdrup#455: a post the host refuses while it still holds the upload connection
    /// (`upload_in_progress`) is asked again, without uploading again, as the owner's
    /// composers do. The guest used to fail the send outright.
    func testAPostRefusedWhileTheUploadFinishesIsAskedAgain() {
        let app = launch(features: nil, environment: ["HERDR_MOCK_PICKED_FILE": "1",
                                                      "HERDR_MOCK_GUEST_POST_IN_PROGRESS": "2"])
        let calls = sendWithAttachment(app, text: "")

        XCTAssertEqual(calls.filter { $0.hasPrefix("gram.upload_chunk:") }.count, 1,
                       "the bytes are uploaded once: \(calls)")
        let posts = calls.filter { $0.hasPrefix("gram.post:") }
        XCTAssertEqual(posts.count, 3, "two refusals, then the post lands: \(calls)")
        XCTAssertEqual(Set(posts.map { $0.components(separatedBy: "=").first ?? "" }).count, 1,
                       "every try posts the same upload: \(posts)")
        XCTAssertTrue(posts.last?.hasSuffix("=gp-1") == true, "\(posts)")
        let prompt = calls.first { $0.hasPrefix("agent.prompt:") } ?? ""
        XCTAssertTrue(prompt.contains("File picked-notes.txt attached via Herdr Gram message gp-1"), prompt)
    }

    /// Picks the harness's file through the paperclip, types `text` and sends. Waits for the
    /// agent's prompt, checks the composer cleared without a note, and returns the host's calls.
    private func sendWithAttachment(_ app: XCUIApplication, text: String) -> [String] {
        let paperclip = app.buttons["guest-attach-button"]
        XCTAssertTrue(paperclip.exists(within: 10))
        XCTAssertTrue(poll(10, every: 0.25) { paperclip.isEnabled }, "the composer should open")
        paperclip.tap()
        let file = app.buttons["composer-attach-file"]
        XCTAssertTrue(file.exists(within: 5), "the paperclip should open the attach sheet")
        file.tap()
        let chip = app.staticTexts["picked-notes.txt"]
        XCTAssertTrue(chip.exists(within: 10), "the picked file should stage a chip")
        // The bytes go up as soon as the file is picked (herdrup#523 item 11), but nothing
        // reaches the agent until Send.
        let staged = pollLabel(app, "guest-host-calls", "the picked file should upload before Send",
                               timeout: 15) { $0.contains("gram.upload_chunk:") }
        XCTAssertFalse(staged.contains("gram.post:"), "picking a file must not post it: \(staged)")
        XCTAssertFalse(staged.contains("agent.prompt:"), "picking a file must not prompt the agent: \(staged)")

        if !text.isEmpty {
            let input = app.textViews["guest-composer-input"]
            input.tap()
            input.typeText(text)
        }
        let send = app.buttons["guest-send-button"]
        XCTAssertTrue(send.exists(within: 5), "a staged file should be sendable")
        send.tap()

        let calls = pollLabel(app, "guest-host-calls", "the agent should be prompted with the file",
                              timeout: 15) { $0.contains("agent.prompt:") }
        XCTAssertTrue(poll(10, every: 0.25) { !chip.exists }, "the chip should clear once delivered")
        XCTAssertTrue(app.staticTexts["Message llm-opt as plotarmordev"].exists(within: 5),
                      "a delivered message clears the composer")
        let note = element(app, "guest-note")
        XCTAssertFalse(note.exists, "the send should not fail: \(note.exists ? note.label : "")")
        attach(app, "guest-attachment-sent")
        return calls.components(separatedBy: ";")
    }
}
