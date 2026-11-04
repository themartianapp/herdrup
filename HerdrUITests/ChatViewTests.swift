import UIKit
import XCTest

/// The omp Chat view (#481 owner, #482 guest), against `ChatMockTransport` (the `chatview`
/// mock: herdr-app is an omp agent blocked on "Merge #305 and update the servers?",
/// keephair a Claude agent) and `GuestMockTransport` with the guest transcript
/// (`guestchat`). Runs on iPhone and iPad alike.
final class ChatViewTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// `HERDR_MOCK_STILL` keeps every agent off "working" and `HERDR_STEADY_CARET` stops the
    /// hidden terminal's caret: a working spinner, a pulse or a blinking caret never lets
    /// XCUITest's idle wait finish (a minute per action). `still: false` keeps the working
    /// agents (keephair is only listed outside the Idle group while it works).
    private func launch(_ mock: String, _ environment: [String: String] = [:], still: Bool = true) -> XCUIApplication {
        var quiet = ["HERDR_STEADY_CARET": "1"]
        if still { quiet["HERDR_MOCK_STILL"] = "1" }
        return XCUIApplication.launched(mock: mock, environment: quiet.merging(environment) { _, new in new })
    }

    private func openAgent(_ name: String, in app: XCUIApplication) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 12), "the home should list \(name)")
        row.tap()
    }

    private func turns(_ chat: XCUIElement) -> Int {
        Int((chat.value as? String ?? "").replacingOccurrences(of: "turns=", with: "")) ?? -1
    }

    /// The last on-screen button identified `id` (the chat is a plain stack: older turns'
    /// rows exist above the viewport too).
    private func visibleButton(_ id: String, in app: XCUIApplication) -> XCUIElement? {
        var found: XCUIElement?
        _ = poll(8, every: 0.3) {
            let all = app.buttons.matching(identifier: id).allElementsBoundByIndex
            found = all.last(where: { $0.isHittable })
            return found != nil
        }
        return found
    }

    // MARK: - Owner

    /// An omp agent opens in Chat by default; the switch flips to the terminal and back.
    func testOmpAgentOpensInChatAndSwitches() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)

        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "an omp agent should open in Chat")
        XCTAssertTrue(app.buttons["chat-switch-chat"].isSelected, "Chat should be the selected segment")
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].waitForExistence(timeout: 8),
                      "the pending question should show as a card")
        attach(app, "chat-owner")

        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 6), "Terminal should hide the chat")
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
        attach(app, "chat-owner-terminal")

        app.buttons["chat-switch-chat"].tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 6), "Chat should come back")
    }

    /// A Claude agent has no Chat: no switch, the terminal as before.
    func testClaudeAgentHasNoSwitch() {
        let app = launch("chatview", still: false)
        openAgent("keephair", in: app)
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10), "a Claude agent opens its terminal")
        XCTAssertFalse(app.buttons["chat-switch-chat"].exists, "only omp agents get the switch")
        XCTAssertFalse(app.descendants(matching: .any)["chat-view"].firstMatch.exists)
    }

    /// #604: a just-started omp agent answers `transcript_unsupported` until omp's integration
    /// reports a session, then `transcript_unavailable` until its first turn. Chat must come
    /// back without restarting the app, once the transcript can be read. How long Chat stays
    /// hidden meanwhile depends on retry timing, so it is not asserted; before the fix it never
    /// came back (this test failed at that assertion).
    func testChatAppearsOnceAStartingOmpAgentHasATranscript() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_STARTUP":
            "transcript_unsupported,transcript_unsupported,transcript_unavailable"])
        openAgent("herdr-app", in: app)
        let chatSwitch = app.buttons["chat-switch-chat"]
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10), "the pane opens")
        XCTAssertTrue(chatSwitch.waitForExistence(timeout: 30),
                      "Chat should come back once the agent's transcript can be read")
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "an omp agent opens in Chat")
        XCTAssertTrue(poll(15, every: 0.5) { self.turns(chat) > 0 },
                      "the conversation loads; turns=\(turns(chat))")
        attach(app, "chat-after-startup")
    }

    /// Settings shows the default (Chat); with Terminal chosen, omp agents open in the
    /// terminal, the switch still offering Chat.
    func testSettingsDefaultDecidesWhereOmpOpens() {
        let app = launch("chatview")
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        // Preferences › "omp agents open in" is an inline menu picker on the root list
        // (proposal B, #572): the iPhone root and the iPad sidebar alike.
        let picker = app.buttons["settings-omp-opens-in"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "Settings should offer the omp default")
        var scrolls = 0
        while !app.frame.contains(picker.frame), scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertEqual(picker.value as? String, "Chat", "Chat should be the default")
        // The menu's items exist before its open animation settles; a tap in that window
        // lands on the dismissing backdrop and closes the menu without choosing (seen on
        // CI for #587, #597, #612). Tap the item once it is hittable, and open the menu
        // again if the first choice did not take. Ask for hittability only once the item has
        // a frame: on a zero-size item still animating in, `isHittable` records a failure
        // ("Activation point invalid") instead of answering false (#627 run 41841861442).
        for _ in 0..<2 where picker.value as? String != "Terminal" {
            picker.tap()
            let terminalChoice = app.buttons["Terminal"].firstMatch
            XCTAssertTrue(poll(5, every: 0.2) {
                terminalChoice.exists && !terminalChoice.frame.isEmpty && terminalChoice.isHittable
            }, "the menu should offer Terminal")
            terminalChoice.tap()
            _ = poll(3, every: 0.3) { picker.value as? String == "Terminal" }
        }
        XCTAssertEqual(picker.value as? String, "Terminal", "the picker should now read Terminal")
        attach(app, "chat-settings")

        let terminalFirst = launch("chatview", ["HERDR_MOCK_CHAT_OPENS_IN": "terminal"])
        openAgent("herdr-app", in: terminalFirst)
        let terminal = terminalFirst.buttons["chat-switch-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "an omp agent still offers the switch")
        XCTAssertTrue(terminal.isSelected, "with Terminal the default, the page opens in the terminal")
        XCTAssertFalse(terminalFirst.descendants(matching: .any)["chat-view"].firstMatch.exists)
    }

    /// Scrolling to the top loads older turns.
    func testScrollingUpLoadsOlderTurns() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let first = turns(chat)
        var loaded = false
        for _ in 0..<12 where !loaded {
            chat.swipeDown(velocity: .fast)
            loaded = poll(2, every: 0.3) { self.turns(chat) > first }
        }
        XCTAssertTrue(loaded, "scrolling to the top should load an older page (had \(first) turns)")
    }

    /// The thought line and the steps line expand.
    func testThoughtAndStepsExpand() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.swipeDown(velocity: .slow)

        guard let thought = visibleButton("chat-thought", in: app) else {
            return XCTFail("a work group on screen should show its thought")
        }
        thought.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-thought-open"].waitForExistence(timeout: 4),
                      "tapping the thought should show it whole")

        guard let steps = visibleButton("chat-steps", in: app) else {
            return XCTFail("a work group on screen should summarise its steps")
        }
        steps.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-steplist"].waitForExistence(timeout: 4),
                      "tapping the steps line should list them")
        attach(app, "chat-expanded")
    }

    /// Tapping an option answers the question; the card then shows the choice.
    func testAnsweringTheQuestion() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let option = app.buttons["chat-ask-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the owner should get answer buttons")
        option.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-chosen"].waitForExistence(timeout: 8),
                      "the card should show the answer")
        XCTAssertFalse(app.buttons["chat-ask-option-0"].exists, "an answered question offers no buttons")
    }

    /// A server that cannot answer through the UI sends the owner to the terminal.
    func testRefusedAnswerOffersTheTerminal() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ANSWER": "ask_ui_not_found"])
        openAgent("herdr-app", in: app)
        let option = app.buttons["chat-ask-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        let terminal = app.buttons["chat-ask-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "a refusal should offer Answer in Terminal")
        terminal.tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected, "Answer in Terminal should switch to it")
    }

    /// A message sent with a trailing space (an iOS keyboard suggestion adds one) is
    /// recorded trimmed by the agent; it must settle into ONE bubble, the transcript's, with
    /// no pending placeholder left beside it.
    func testSendWithTrailingSpaceReconcilesIntoOneBubble() throws {
        // Answered at launch: a blocked agent's reply goes to its menu as keys, not as a
        // prompt. Not `still`: an idle herdr-app would sit in the collapsed Idle section.
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ANSWERED": "Yes, merge and deploy"], still: false)
        openAgent("herdr-app", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 10))
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Ship the fix ")
        let send = try XCTUnwrap(visibleButton("terminal-send-button", in: app), "the reply should be sendable")
        send.tap()

        // The composer clears on the tap itself (Send gives way to Saved Prompts), whatever
        // the send motion is still drawing.
        XCTAssertTrue(send.waitForNonExistence(timeout: 5), "the composer should clear when Send is tapped")

        // The placeholder (with its receipt) shows first; the transcript's copy replaces it.
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ship the fix"))
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 10), "the chat should show the sent message")
        XCTAssertTrue(sent.firstMatch.waitForHittable(timeout: 5),
                      "the chat should follow the sent message to the bottom, on screen")
        // The bubble's identifier also reaches its receipt text, so wait on the bubble itself.
        let placeholder = app.descendants(matching: .any).matching(identifier: "chat-outgoing-message").firstMatch
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 15),
                      "the local placeholder should be matched and removed: \(placeholder.exists ? placeholder.label : "")")
        for label in ["Sending…", "Accepted by agent", "Confirmation pending", "Not seen in chat · check Terminal"] {
            XCTAssertFalse(app.staticTexts[label].exists, "no \"\(label)\" placeholder may be left")
        }
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 5), "the transcript should show the sent message")
        XCTAssertEqual(sent.count, 1, "the message should show once, not twice")
    }

    // MARK: - Guest

    /// A shared omp agent on a host serving guests its transcript: the Chat tab, first;
    /// no note cards; and the guest answers omp's question with the owner's buttons
    /// (`agent.answer` on the shared agent), with no "waiting for the owner" footer.
    func testGuestChatTabAnswersTheQuestion() {
        let app = launch("guestchat")
        let tab = app.buttons["guest-tab-chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12), "the guest should get a Chat tab")
        XCTAssertTrue(tab.isSelected, "Chat should be the guest's first tab")
        XCTAssertTrue(app.buttons["guest-tab-terminal"].exists)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        let option = app.buttons["chat-ask-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 8), "a guest answers with the owner's buttons")
        XCTAssertFalse(app.descendants(matching: .any)["chat-ask-waiting"].exists,
                       "an answerable question does not wait for the owner")
        XCTAssertFalse(app.descendants(matching: .any)["chat-note"].exists, "guests see no note cards")
        attach(app, "chat-guest")

        app.buttons["guest-tab-terminal"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 6))
        tab.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 6))

        app.buttons["chat-ask-option-0"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-chosen"].waitForExistence(timeout: 8),
                      "the answered question shows the choice")
        let hostCalls = app.descendants(matching: .any)["guest-host-calls"]
        XCTAssertTrue(poll(6, every: 0.3) { hostCalls.label.contains("agent.answer:Yes, post them") },
                      "the answer reaches the host as agent.answer: \(hostCalls.label)")
        let refused = app.descendants(matching: .any)["guest-forbidden-calls"].label
        XCTAssertFalse(refused.contains("agent.transcript"), "the transcript is on the guest allowlist: \(refused)")
        XCTAssertFalse(refused.contains("agent.answer"), "a guest's answer is allowed: \(refused)")
    }

    /// A host older than guest answers withholds `answerable` from the guest: the question
    /// shows read-only, waiting for the owner, as before.
    func testGuestChatWaitsForTheOwnerOnAnOlderHost() {
        let app = launch("guestchat", ["HERDR_MOCK_GUEST_OWNER_ANSWERS": "1"])
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-waiting"].waitForExistence(timeout: 8),
                      "the guest sees the question waiting for the owner")
        XCTAssertFalse(app.buttons["chat-ask-option-0"].exists, "this host keeps answers for the owner")
        attach(app, "chat-guest-owner-answers")
    }

    /// A paused share (its agent not in the pane's foreground) still has its conversation in
    /// omp's session file: the Chat tab, the guest's first, loads it instead of spinning.
    func testGuestChatLoadsWhilePaused() {
        let app = launch("guestpaused", ["HERDR_MOCK_GUEST_CHAT": "1"])
        let tab = app.buttons["guest-tab-chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12), "a paused omp share keeps its Chat tab")
        XCTAssertTrue(tab.isSelected, "Chat should be the guest's first tab")
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 },
                      "a paused agent's chat should load its turns (turns=\(turns(chat)))")
        XCTAssertFalse(app.descendants(matching: .any)["chat-loading"].exists, "no endless spinner")
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].waitForExistence(timeout: 8),
                      "the conversation's question shows")
        XCTAssertFalse(app.descendants(matching: .any)["chat-ask-waiting"].exists,
                       "an answerable question does not wait for the owner")
        attach(app, "chat-guest-paused")
    }

    /// A host that predates guest transcripts: no Chat tab, the terminal as before.
    func testGuestHasNoChatTabOnAnOlderHost() {
        let app = launch("guestpane")
        XCTAssertTrue(app.otherElements["guest-terminal"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["guest-tab-chat"].exists, "no capability, no Chat tab")
        XCTAssertFalse(app.descendants(matching: .any)["chat-view"].firstMatch.exists)
    }

    // MARK: - Screenshots

    /// The mockups' four screens (iPhone/iPad × own/shared), for the visual comparison.
    /// Not still, so the iPad sidebar shows keephair working as in the mockup; the guest's
    /// host also offers Gram (its tab and unread badge are in the mockup).
    func testScreenshotOwnChat() {
        let app = launch("chatview", still: false)
        openAgent("herdr-app", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].waitForExistence(timeout: 10))
        sleep(2)
        attach(app, "shot-own")
    }

    func testScreenshotSharedChat() {
        let app = launch("guestchat", ["HERDR_MOCK_GUEST_FEATURES": "gram"], still: false)
        XCTAssertTrue(app.buttons["chat-ask-option-0"].waitForExistence(timeout: 15))
        sleep(2)
        attach(app, "shot-guest")
    }
}
