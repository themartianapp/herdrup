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

    // MARK: Up arrow to my previous message (owner decision 2026-11-06)

    /// `HERDR_MOCK_CHAT_ORIGINS=some`: on the newest page only the newest prompt is the owner's
    /// (the CI question and questions 38 and 40 are someone else's, 39 a guest's). The up arrow
    /// skips them, loads the older page and lands on question 37, the owner's previous message.
    func testUpArrowJumpsToMyPreviousMessageAcrossAnOlderPage() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ORIGINS": "some"])
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let first = turns(chat)
        let up = app.buttons["chat-jump-previous-mine"]
        XCTAssertTrue(up.waitForExistence(timeout: 8), "an owner turn is above (or older pages remain)")

        let target = app.staticTexts["Synthetic question 37: is check 37 green?"].firstMatch
        let skipped = ["Synthetic question 40: is check 40 green?", "Synthetic question 39: is check 39 green?",
                       "Synthetic question 38: is check 38 green?", "Is the herdr fork's CI running again?"]
        func onScreen(_ element: XCUIElement) -> Bool {
            element.exists && !element.frame.isEmpty && chat.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.minY + 1))
        }
        // The newest prompt may be above the screen (a tap lands on it first), then question 37.
        var landed = false
        for _ in 0..<2 where !landed {
            up.tap()
            landed = poll(8, every: 0.3) { onScreen(target) }
        }
        XCTAssertTrue(landed, "the up arrow should reach question 37, past the other and guest turns")
        XCTAssertGreaterThan(turns(chat), first, "question 37 is on an older page, which the tap loaded")
        XCTAssertLessThan(target.frame.minY - chat.frame.minY, chat.frame.height / 3,
                          "the jump puts the owner's message at the top of the chat")
        for text in skipped {
            let element = app.staticTexts[text].firstMatch
            XCTAssertFalse(element.exists && onScreen(element) && abs(element.frame.minY - target.frame.minY) < 1,
                           "never a jump to \(text)")
        }
        attach(app, "chat-previous-mine")
        XCTAssertTrue(app.buttons["chat-jump-latest"].waitForExistence(timeout: 4), "the down arrow comes back")
    }

    /// Review 18e5a606c8b8d005 F1: on the iPad the corner up arrow lies in the column's right
    /// resize band (a 44 pt full-height drag target) whenever the column fills the chat, as the
    /// default Wide does here. A tap on the arrow's centre must jump, not start a resize.
    func testUpArrowOverTheIPadColumnEdgeStillJumps() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the column resizer exists on regular width only")
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ORIGINS": "some"])
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let up = app.buttons["chat-jump-previous-mine"]
        XCTAssertTrue(up.waitForExistence(timeout: 8))
        let handle = app.descendants(matching: .any)["chat-width-handle-right"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // The case under test: the arrow's centre is inside the handle's band.
        XCTAssertTrue(handle.frame.contains(CGPoint(x: up.frame.midX, y: up.frame.midY)),
                      "precondition: the arrow (\(up.frame)) sits in the resize band (\(handle.frame))")

        let target = app.staticTexts["Synthetic question 37: is check 37 green?"].firstMatch
        let column = app.descendants(matching: .any)["chat-column"].firstMatch
        let width = column.exists ? column.frame.width : 0
        var landed = false
        // As on the iPhone: the first tap may stop at the newest prompt above the screen.
        for _ in 0..<2 where !landed {
            up.tap()
            landed = poll(8, every: 0.3) { target.exists && chat.frame.intersects(target.frame) }
        }
        attach(app, "chat-previous-mine-ipad")
        XCTAssertTrue(landed, "a tap on the arrow should jump to question 37, not grab the column edge")
        if column.exists { XCTAssertEqual(column.frame.width, width, accuracy: 0.5, "the tap must not resize the column") }
    }

    /// Review 18e58482c5fdb8ca F1: after the up arrow reached question 38, search moved the
    /// chat down to the CI question. Once search closes, the next tap goes to the owner's
    /// message just above what is on screen (question 40 or 39, both loaded), not on from
    /// question 38 to 37, which the old code fetched an older page for.
    func testUpArrowAfterSearchStartsFromWhatIsOnScreen() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let up = app.buttons["chat-jump-previous-mine"]
        XCTAssertTrue(up.waitForExistence(timeout: 8))
        func atTop(_ text: String) -> Bool {
            let element = app.staticTexts[text].firstMatch
            return element.exists && !element.frame.isEmpty
                && element.frame.minY >= chat.frame.minY - 1 && element.frame.minY - chat.frame.minY < chat.frame.height / 3
        }
        let q38 = "Synthetic question 38: is check 38 green?"
        var reached = false
        for _ in 0..<6 where !reached {
            up.tap()
            reached = poll(3, every: 0.3) { atTop(q38) }
        }
        XCTAssertTrue(reached, "the up arrow should step up to question 38 on the newest page")
        let loaded = turns(chat)

        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("CI running again")
        expectation(for: NSPredicate(format: "label == %@", "1/1"), evaluatedWith: app.staticTexts["terminal-find-count"])
        waitForExpectations(timeout: 5)
        app.buttons["terminal-find"].tap()
        XCTAssertTrue(poll(5, every: 0.3) { !atTop(q38) }, "search moved the chat away from question 38")

        XCTAssertTrue(up.waitForExistence(timeout: 5))
        up.tap()
        let landed = poll(6, every: 0.3) {
            atTop("Synthetic question 40: is check 40 green?") || atTop("Synthetic question 39: is check 39 green?")
        }
        attach(app, "chat-previous-mine-after-search")
        XCTAssertTrue(landed, "the tap should land on the owner's message just above the screen")
        XCTAssertEqual(turns(chat), loaded, "no older page: question 37 was never the target")
    }

    /// Review 18e58fbbc4ef6e41 F2: the up arrow is waiting on an older page (held back 8 s) to
    /// reach question 37 when search opens. When the page lands, the chat stays where search left
    /// it: the old code went on to question 37. The term matches nothing: a match would pull the
    /// chat back to itself when the page lands and hide the stray jump (it did, CI 42297542162).
    func testSearchOpenedWhileTheUpArrowLoadsStopsTheJump() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ORIGINS": "some", "HERDR_MOCK_CHAT_OLDER_DELAY": "8"])
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let loaded = turns(chat)
        let up = app.buttons["chat-jump-previous-mine"]
        XCTAssertTrue(up.waitForExistence(timeout: 8))
        // The newest prompt may be above the screen (a tap lands on it first); the next tap then
        // fetches the older page. Find opens only once that fetch is under way (review 18e590a31540072c).
        var loading = false
        for _ in 0..<2 where !loading {
            up.tap()
            loading = poll(4, every: 0.2) { up.exists && (up.value as? String) == "Loading earlier messages" }
        }
        XCTAssertTrue(loading, "the up arrow should be fetching the held-back older page")

        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zebra quartz")
        // Past the typing pause, so the search has run (and found nothing to move to).
        Thread.sleep(forTimeInterval: 1.5)
        let q37 = app.staticTexts["Synthetic question 37: is check 37 green?"].firstMatch
        XCTAssertFalse(q37.exists && chat.frame.intersects(q37.frame), "question 37 is still on the held-back page")

        XCTAssertTrue(poll(15, every: 0.3) { self.turns(chat) > loaded }, "the held-back older page lands")
        // The old code's jump glides for about 0.3 s after the page lands.
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "chat-previous-mine-search-took-over")
        let shown = q37.exists && !q37.frame.isEmpty && chat.frame.intersects(q37.frame)
        XCTAssertFalse(shown, "search took over: the up arrow must not scroll to question 37")
        XCTAssertTrue(field.exists, "search is still open")
    }

    /// `HERDR_MOCK_CHAT_ORIGINS=none`: every prompt but the newest is someone else's. The up arrow
    /// pages through the whole history, finds nothing to stop at, and hides.
    func testUpArrowHidesWhenNoEarlierMessageIsMine() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ORIGINS": "none"])
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let up = app.buttons["chat-jump-previous-mine"]
        XCTAssertTrue(up.waitForExistence(timeout: 8), "older pages remain, so the arrow shows")
        var hidden = false
        for _ in 0..<3 where !hidden {
            if up.exists { up.tap() }
            hidden = poll(10, every: 0.3) { !up.exists }
        }
        XCTAssertTrue(hidden, "with no earlier owner message and no history left, the up arrow hides")
        XCTAssertEqual(turns(chat), 42, "the whole history was searched (40 filler turns, the CI turn, the newest)")
        attach(app, "chat-previous-mine-none")
    }

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

    /// Leaving Chat while it still scrolls tears its scroll observer down mid-scroll. The
    /// observer used to report "scrolling ended" during that teardown, writing Chat's state
    /// inside SwiftUI's graph update: an exclusivity abort (TestFlight crash, 1.2.1 (238),
    /// `ScrollActivityObserver.Coordinator.stop` from `dismantleUIView`). Flick, switch to the
    /// terminal at once, several times; the app must stay up and Chat must come back.
    func testLeavingChatWhileItStillScrollsDoesNotCrash() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "an omp agent should open in Chat")
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        for round in 0..<4 {
            if round.isMultiple(of: 2) { chat.swipeDown(velocity: .fast) } else { chat.swipeUp(velocity: .fast) }
            app.buttons["chat-switch-terminal"].tap()
            XCTAssertEqual(app.state, .runningForeground, "leaving Chat mid-scroll must not crash (round \(round))")
            XCTAssertTrue(chat.waitForNonExistence(timeout: 6), "Terminal should hide the chat")
            app.buttons["chat-switch-chat"].tap()
            XCTAssertTrue(chat.waitForExistence(timeout: 6), "Chat should come back (round \(round))")
        }
        XCTAssertEqual(app.state, .runningForeground)
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

    // MARK: Form asks (omp ≥ 18.18.3, proposal B: the stepper)

    /// `HERDR_MOCK_CHAT_FORM`: herdr-app's question is omp's HTML form (the enyo-ui ask plus
    /// a checkbox field), on a server with `ask_form`.
    private func launchForm(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = launch("chatview", environment.merging(["HERDR_MOCK_CHAT_FORM": "1"]) { given, _ in given })
        openAgent("herdr-app", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form"].waitForExistence(timeout: 10),
                      "the form ask should show as the stepper")
        return app
    }

    private func formStep(_ app: XCUIApplication) -> String {
        app.staticTexts["chat-ask-form-step"].firstMatch.label
    }

    private func waitForStep(_ label: String, in app: XCUIApplication, _ message: String = "") {
        XCTAssertTrue(poll(5, every: 0.2) { self.formStep(app) == label },
                      "expected step \(label), got \(formStep(app)). \(message)")
    }

    /// Step through, change one field, answer another with Other, review (two "Changed"
    /// marks), submit: the card turns into the answered summary carrying both changes, which
    /// the mock server computed from the `agent.answer_form` values it received.
    func testFormStepperChangesAFieldUsesOtherReviewsAndSubmits() {
        let app = launchForm()
        waitForStep("1 OF 6", in: app)
        XCTAssertFalse(app.buttons["chat-ask-form-back"].isEnabled, "the first step has nothing to go back to")
        XCTAssertTrue(app.buttons["chat-ask-form-option-0"].isSelected, "omp's recommendation is preselected")
        XCTAssertTrue(app.buttons["chat-ask-form-option-0"].label.contains("Recommended"),
                      "the agent's default is marked: \(app.buttons["chat-ask-form-option-0"].label)")
        attach(app, "form-open")

        // Steps 1–3: keep the recommendation (a tap on a radio answers it and moves on).
        for step in 1...3 {
            app.buttons["chat-ask-form-option-0"].tap()
            waitForStep("\(step + 1) OF 6", in: app)
        }
        // Step 4: change it.
        app.buttons["chat-ask-form-option-1"].tap()
        waitForStep("5 OF 6", in: app)
        app.buttons["chat-ask-form-back"].tap()
        waitForStep("4 OF 6", in: app, "Back returns to the changed step")
        XCTAssertTrue(app.buttons["chat-ask-form-option-1"].isSelected, "the change is kept")
        attach(app, "form-mid1")
        app.buttons["chat-ask-form-option-1"].tap()
        waitForStep("5 OF 6", in: app)

        // Step 5: Other opens a text field with the keyboard.
        app.buttons["chat-ask-form-other"].tap()
        let other = app.textViews["chat-ask-form-other-field"].exists
            ? app.textViews["chat-ask-form-other-field"] : app.textFields["chat-ask-form-other-field"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "Other opens its text field")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "and the keyboard")
        XCTAssertFalse(app.buttons["chat-ask-form-next"].isEnabled, "an empty Other cannot move on")
        other.typeText("Both: a dashboard row and email to demo@lenscale.ai")
        XCTAssertTrue(app.buttons["chat-ask-form-next"].isEnabled)
        attach(app, "form-mid2")
        other.typeText("\n")
        waitForStep("6 OF 6", in: app, "Return moves on like Next")

        // Step 6: the checkbox group keeps its two recommendations; Next goes to the review.
        XCTAssertTrue(app.buttons["chat-ask-form-option-0"].isSelected)
        XCTAssertTrue(app.buttons["chat-ask-form-option-1"].isSelected)
        XCTAssertFalse(app.buttons["chat-ask-form-option-2"].isSelected)
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("REVIEW", in: app)
        // A review taller than the chat opens at its top, not with its first answers under the header.
        XCTAssertTrue(app.buttons["chat-ask-form-review-0"].waitForHittable(timeout: 3),
                      "the review should open with its first answer on screen")
        let changed = (0..<6).filter { app.buttons["chat-ask-form-review-\($0)"].label.contains("Changed") }
        XCTAssertEqual(changed, [3, 4], "the review marks exactly the two changed answers")
        XCTAssertTrue(app.buttons["chat-ask-form-review-4"].label
            .contains("Both: a dashboard row and email to demo@lenscale.ai"))
        attach(app, "form-review")

        // Tap an answer to change it, then come straight back to the review. The last row
        // sits just above Submit, on screen; the first can be under the navigation bar.
        let lastRow = app.buttons["chat-ask-form-review-5"]
        XCTAssertTrue(lastRow.waitForHittable(timeout: 5))
        lastRow.tap()
        waitForStep("6 OF 6", in: app)
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("REVIEW", in: app, "an answer edited from the review returns to it")

        app.buttons["chat-ask-form-submit"].tap()
        let answered = app.descendants(matching: .any)["chat-ask-form-answered"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10), "Submit shows the answered summary")
        XCTAssertTrue(answered.label.contains("You answered 6 of 6"), answered.label)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form-answer-3"].label
            .contains("I'll pick first; the build waits"), "the changed field reached the server")
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form-answer-4"].label
            .contains("Both: a dashboard row and email to demo@lenscale.ai"), "Other's text reached the server")
        XCTAssertFalse(app.buttons["chat-ask-form-submit"].exists, "an answered form offers no stepper")
        sleep(1)
        attach(app, "form-done")
    }

    /// The selections and the step survive the chat being torn down (the Terminal and back).
    func testFormSelectionsSurviveLeavingTheChat() {
        let app = launchForm()
        app.buttons["chat-ask-form-option-1"].tap()
        waitForStep("2 OF 6", in: app)
        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
        sleep(1)
        app.buttons["chat-switch-chat"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form"].waitForExistence(timeout: 8))
        waitForStep("2 OF 6", in: app, "the step is kept")
        app.buttons["chat-ask-form-back"].tap()
        waitForStep("1 OF 6", in: app)
        XCTAssertTrue(app.buttons["chat-ask-form-option-1"].isSelected, "the change is kept")
    }

    /// An optional radio omp checked nothing of may be left unanswered: Other opened there
    /// and left empty is no answer, so Next still moves on (review of #650, F3).
    func testEmptyOtherOnAnOptionalRadioCanBeLeftUnanswered() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_OPTIONAL": "1"])
        app.buttons["chat-ask-form-review-all"].tap()
        waitForStep("REVIEW", in: app)
        // The review opens at its top; its last row may be below the screen (a drag ends the
        // reveal, so the chat stays where it is put).
        let card = app.descendants(matching: .any)["chat-ask-form"]
        let toneRow = app.buttons["chat-ask-form-review-6"]
        XCTAssertTrue(toneRow.waitForExistence(timeout: 5), "the review lists the optional radio")
        for _ in 0..<4 where !toneRow.isHittable { card.swipeUp(velocity: .slow) }
        XCTAssertTrue(toneRow.isHittable, "the optional radio's review row should come on screen")
        XCTAssertTrue(toneRow.label.contains("No answer"), toneRow.label)
        toneRow.tap()
        waitForStep("7 OF 7", in: app)
        app.buttons["chat-ask-form-other"].tap()
        let other = app.textViews["chat-ask-form-other-field"].exists
            ? app.textViews["chat-ask-form-other-field"] : app.textFields["chat-ask-form-other-field"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "Other opens its text field")
        other.typeText("x")
        other.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(app.buttons["chat-ask-form-next"].isEnabled, "an emptied Other leaves the field unanswered")
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("REVIEW", in: app, "Next moves on from the emptied Other")
        XCTAssertTrue(app.buttons["chat-ask-form-review-6"].label.contains("No answer"),
                      app.buttons["chat-ask-form-review-6"].label)
        let submit = app.buttons["chat-ask-form-submit"]
        for _ in 0..<4 where !submit.isHittable { card.swipeUp(velocity: .slow) }
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form-answered"].waitForExistence(timeout: 10),
                      "the form submits with the field left out")
    }

    /// herdr cannot drive the terminal form any more (someone is answering it there): the
    /// card offers the Terminal.
    func testFormMovedInTheTerminalOffersTheTerminal() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_ANSWER": "ask_form_moved"])
        app.buttons["chat-ask-form-review-all"].tap()
        waitForStep("REVIEW", in: app)
        app.buttons["chat-ask-form-submit"].tap()
        let terminal = app.buttons["chat-ask-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "ask_form_moved offers Answer in Terminal")
        terminal.tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
    }

    /// herdr refuses a value: the card goes to that field's step and says why.
    func testFormInvalidShowsTheErrorOnItsStep() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_ANSWER": "ask_form_invalid"])
        app.buttons["chat-ask-form-review-all"].tap()
        app.buttons["chat-ask-form-submit"].tap()
        let error = app.staticTexts["chat-ask-form-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 8), "the refused field shows herdr's reason")
        XCTAssertEqual(formStep(app), "5 OF 6", "on the refused field's step")
    }

    /// A server without `ask_form`: the steps read-only, and Answer in Terminal.
    func testFormOnAServerWithoutTheCapabilityIsReadOnly() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_CAPABILITY": "0"])
        let terminal = app.buttons["chat-ask-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "an older server answers in the Terminal")
        XCTAssertFalse(app.buttons["chat-ask-form-option-0"].isEnabled, "the options are read-only")
        XCTAssertFalse(app.buttons["chat-ask-form-submit"].exists)
        attach(app, "form-no-capability")
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("2 OF 6", in: app, "the steps can still be read")
        terminal.tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected, "Answer in Terminal switches to it")
    }

    /// A read-only form (here a server without `ask_form`) steps through every field: the
    /// textarea last with omp's prefilled value, Answer in Terminal on each step, and no
    /// review or Submit.
    func testReadOnlyFormStepsToItsTextareaAndTheTerminal() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_TEXTAREA": "1", "HERDR_MOCK_CHAT_FORM_CAPABILITY": "0"])
        let terminal = app.buttons["chat-ask-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "a read-only form answers in the Terminal")
        XCTAssertEqual(formStep(app), "1 OF 7")
        XCTAssertFalse(app.buttons["chat-ask-form-option-0"].isEnabled, "the options are read-only")
        for step in 2...7 {
            app.buttons["chat-ask-form-next"].tap()
            waitForStep("\(step) OF 7", in: app, "the read-only form steps through every field")
            XCTAssertTrue(terminal.exists, "Answer in Terminal on step \(step)")
            XCTAssertFalse(app.buttons["chat-ask-form-review-all"].exists, "no review on a read-only form")
            XCTAssertFalse(app.buttons["chat-ask-form-submit"].exists, "no Submit on a read-only form")
        }
        XCTAssertEqual(app.staticTexts["chat-ask-form-title"].firstMatch.label, "Anything else for the build")
        let value = app.staticTexts["chat-ask-form-text"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5), "the textarea shows read-only")
        XCTAssertTrue(value.label.contains("Keep the 1 Nov palette.") && value.label.contains("No stock photos"),
                      "the textarea shows omp's prefilled value: \(value.label)")
        XCTAssertFalse(app.buttons["chat-ask-form-next"].isEnabled, "the last field has no Next")
        sleep(1)
        attach(app, "form-textarea")
        terminal.tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected, "Answer in Terminal switches to it")
    }

    /// herdr (#394) types a textarea answer only while it fits omp's editor: a longer one is
    /// refused on its step, which then offers the Terminal.
    func testTextareaTooLongForTheAppOffersTheTerminal() {
        let app = launchForm(["HERDR_MOCK_CHAT_FORM_TEXTAREA": "1"])
        app.buttons["chat-ask-form-review-all"].tap()
        waitForStep("REVIEW", in: app)
        let notesRow = app.buttons["chat-ask-form-review-6"]
        XCTAssertTrue(notesRow.waitForExistence(timeout: 5), "the review lists the textarea")
        XCTAssertTrue(notesRow.label.contains("Keep the 1 Nov palette."), "the review shows the prefill: \(notesRow.label)")
        notesRow.tap()
        waitForStep("7 OF 7", in: app)
        let text = app.textViews["chat-ask-form-text"].exists ? app.textViews["chat-ask-form-text"]
            : app.textFields["chat-ask-form-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "an answerable textarea is editable")
        XCTAssertTrue((text.value as? String ?? "").contains("No stock photos"), "the editor holds the prefill")
        text.tap()
        text.typeText("\nNo new fonts either.")
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("REVIEW", in: app, "the edited textarea returns to the review")
        app.buttons["chat-ask-form-submit"].tap()
        let error = app.staticTexts["chat-ask-form-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 8), "the refused textarea shows herdr's reason")
        XCTAssertTrue(error.label.contains("answer in the terminal"), error.label)
        XCTAssertEqual(formStep(app), "7 OF 7", "the refusal opens the textarea's step")
        XCTAssertTrue(app.buttons["chat-ask-terminal"].waitForExistence(timeout: 5),
                      "a value only the Terminal can enter offers it")
        sleep(1)
        attach(app, "form-textarea-too-long")
    }

    /// A form that timed out reads as one compact line.
    func testTimedOutFormIsACompactLine() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_FORM": "1", "HERDR_MOCK_CHAT_FORM_STATUS": "timed_out"], still: false)
        openAgent("herdr-app", in: app)
        let ended = app.staticTexts["chat-ask-form-ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: 10))
        XCTAssertEqual(ended.label, "Timed out · recommendations used")
        XCTAssertFalse(app.buttons["chat-ask-form-option-0"].exists)
        attach(app, "form-timed-out")
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

    /// A guest whose host keeps answers for the owner: the form read-only, waiting for them.
    func testGuestFormWaitsForTheOwner() {
        let app = launch("guestchat", ["HERDR_MOCK_CHAT_FORM": "1", "HERDR_MOCK_GUEST_OWNER_ANSWERS": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-form"].waitForExistence(timeout: 12))
        let waiting = app.descendants(matching: .any)["chat-ask-waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 8), "the guest sees the form waiting for the owner")
        XCTAssertTrue(waiting.label.contains("WAITING FOR JERRY TO ANSWER"), waiting.label)
        XCTAssertFalse(app.buttons["chat-ask-form-option-0"].isEnabled, "the guest cannot answer")
        XCTAssertFalse(app.buttons["chat-ask-form-submit"].exists)
        XCTAssertFalse(app.buttons["chat-ask-terminal"].exists, "a guest has no Terminal to answer in")
        attach(app, "form-guest")
        // The guest reads every field, the waiting line under each.
        app.buttons["chat-ask-form-next"].tap()
        waitForStep("2 OF 6", in: app, "a guest steps through the form")
        XCTAssertTrue(waiting.exists, "the waiting line stays on every step")
        app.buttons["chat-ask-form-back"].tap()
        waitForStep("1 OF 6", in: app)
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
