import UIKit
import XCTest

/// An omp agent's Topics (option D, jerryfane/herdr#475), against the `chatview` mock (owner,
/// herdr-app) and the `guestchat` mock (guest, llm-opt) with `HERDR_MOCK_TOPICS` (`TopicsMock`:
/// the pong advertises `agent_topics` and the agent serves three topics, one of them closed).
/// Without it the pong does not advertise topics and the page must look as before.
final class TopicsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// `HERDR_MOCK_STILL` and `HERDR_STEADY_CARET`, as `ChatViewTests`: nothing animates
    /// forever, so XCUITest's idle wait finishes.
    private func launch(_ mock: String, topics: Bool = true, _ environment: [String: String] = [:]) -> XCUIApplication {
        var base = ["HERDR_STEADY_CARET": "1", "HERDR_MOCK_STILL": "1"]
        if topics { base["HERDR_MOCK_TOPICS"] = "1" }
        return XCUIApplication.launched(mock: mock, environment: base.merging(environment) { _, new in new })
    }

    private func openHerdrApp(_ app: XCUIApplication) {
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.exists(within: 12), "the home should list herdr-app")
        row.tap()
    }

    private func openTopics(_ app: XCUIApplication) -> XCUIElement {
        let segment = app.buttons["chat-switch-topics"]
        XCTAssertTrue(segment.exists(within: 12), "an omp agent with topics should offer Topics")
        segment.tap()
        let view = app.otherElements["topics-view"].firstMatch
        XCTAssertTrue(view.exists(within: 8), "Topics should show the agent's topics")
        return view
    }

    /// A topic's chat is open with this title: its header title, an identified static text
    /// (the chat's own container is not reliably an `otherElements` match on iPhone).
    private func topicChatOpen(_ title: String, in app: XCUIApplication) -> Bool {
        let header = app.staticTexts["topic-chat-title"].firstMatch
        return poll(10, every: 0.3) { header.exists && header.label == title }
    }

    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["topic-row-\(id)"].firstMatch
    }

    // MARK: Gating

    /// No `agent_topics` in the pong: the page is today's `Chat | Terminal`, with no Topics
    /// segment and no topics call.
    func testNoTopicsWithoutTheCapability() {
        let app = launch("chatview", topics: false)
        openHerdrApp(app)
        XCTAssertTrue(app.buttons["chat-switch-chat"].exists(within: 10), "the Chat switch is there as before")
        XCTAssertTrue(app.buttons["chat-switch-terminal"].exists)
        XCTAssertFalse(app.buttons["chat-switch-topics"].exists, "no capability, no Topics")
        XCTAssertFalse(app.otherElements["topics-view"].exists)
    }

    /// A guest of a host without `agent_topics` gets no Topics tab.
    func testGuestHasNoTopicsTabWithoutTheCapability() {
        let app = launch("guestchat", topics: false)
        XCTAssertTrue(app.buttons["guest-tab-chat"].exists(within: 12))
        XCTAssertFalse(app.buttons["guest-tab-topics"].exists, "no capability, no Topics tab")
    }

    // MARK: Owner

    /// Topics lists the Inbox first, then the open topics by last activity, then the closed
    /// one; each row has its status. A topic opens its own chat, whose composer sends to that
    /// topic only, and the Inbox opens the agent's own Chat.
    func testTopicsListOpensATopicAndSendsToIt() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected)
        XCTAssertTrue(app.buttons["topics-inbox-row"].exists(within: 8), "the Inbox is pinned first")
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8), "the topics should load")
        XCTAssertTrue(row("t-board", in: app).exists)
        XCTAssertTrue(row("t-nippon", in: app).exists, "a closed topic is still listed")
        XCTAssertEqual(diokan.label, "Diokan term sheet", "the row is named by its title")
        XCTAssertTrue((diokan.value as? String ?? "").hasPrefix("Working"),
                      "a running topic says so: \(String(describing: diokan.value))")
        XCTAssertTrue((row("t-nippon", in: app).value as? String ?? "").hasPrefix("Closed"))
        XCTAssertLessThan(app.buttons["topics-inbox-row"].frame.minY, diokan.frame.minY, "the Inbox comes first")
        XCTAssertLessThan(diokan.frame.minY, row("t-board", in: app).frame.minY, "newest activity first")
        XCTAssertLessThan(row("t-board", in: app).frame.minY, row("t-nippon", in: app).frame.minY,
                          "closed topics come last")
        attach(app, "topics-list")

        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app), "a topic opens its chat")
        XCTAssertTrue(app.staticTexts["Draft the term sheet comparison for Diokan."]
            .firstMatch.exists(within: 10), "the topic's own conversation (agent.transcript with topic)")
        // The Inbox row's preview still names the Inbox's question on iPad (the list stays);
        // the Inbox's own chat would draw it as a question card.
        XCTAssertFalse(app.descendants(matching: .any)["chat-ask"].exists, "not the Inbox's conversation")
        if isPad {
            XCTAssertTrue(diokan.exists, "on iPad the topics column stays beside the chat")
        }
        attach(app, "topics-chat")

        let field = app.textViews["topic-composer-input"]
        XCTAssertTrue(field.exists(within: 8))
        field.tap()
        // The Topics view is drawn over the page's (hidden) composer with a negative bottom
        // padding: its own composer must still clear the keyboard, once, not twice.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists(within: 5), "focusing the topic composer brings up the keyboard")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(poll(5, every: 0.3) { field.isHittable }, "the composer stays reachable over the keyboard")
        _ = poll(3, every: 0.3) { field.frame.maxY <= keyboard.frame.minY + 1 }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "topics-composer-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        if isPad {
            XCTAssertLessThanOrEqual(field.frame.maxY, window.maxY,
                                     "the composer is on screen: \(field.frame) in \(window)")
            XCTAssertGreaterThanOrEqual(field.frame.minY, window.minY,
                                        "the composer is not shifted off the top: \(field.frame) in \(window)")
        } else {
            XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1,
                                     "the composer sits above the keyboard: \(field.frame) vs \(keyboard.frame)")
        }
        field.typeText("Add the second lender")
        app.buttons["topic-send-button"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Add the second lender"))
        XCTAssertTrue(sent.firstMatch.exists(within: 10), "the topic's chat shows the message sent to it")

        if !isPad {
            app.buttons["topic-back"].tap()
            XCTAssertTrue(app.buttons["topics-inbox-row"].exists(within: 6), "back to the list")
        }
        app.buttons["topics-inbox-row"].tap()
        XCTAssertTrue(app.otherElements["chat-view"].firstMatch.exists(within: 8), "the Inbox is the agent's own Chat")
        XCTAssertTrue(app.buttons["chat-switch-chat"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].exists(within: 8),
                      "the agent's own conversation, with its question")
    }

    /// New topic: a title and the first message start it, and it opens.
    func testNewTopicStartsAndOpens() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let new = app.buttons["topics-new"]
        XCTAssertTrue(new.exists(within: 8))
        new.tap()
        let title = app.textFields["topics-new-title"]
        XCTAssertTrue(title.exists(within: 6), "New topic asks for a title")
        let start = app.buttons["topics-new-start"]
        XCTAssertFalse(start.isEnabled, "nothing to start yet")
        title.tap()
        title.typeText("Solar plan")
        let message = app.descendants(matching: .any)["topics-new-message"].firstMatch
        message.tap()
        message.typeText("Compare the two arsenic remediation quotes.")
        XCTAssertTrue(start.isEnabled)
        attach(app, "topics-new")
        start.tap()

        XCTAssertTrue(topicChatOpen("Solar plan", in: app), "the new topic opens")
        XCTAssertTrue(app.staticTexts["Compare the two arsenic remediation quotes."].firstMatch.exists(within: 10),
                      "its first message is its conversation's first turn")
        if !isPad { app.buttons["topic-back"].tap() }
        XCTAssertTrue(row("t-new-1", in: app).exists(within: 8), "the list has the new topic")
    }

    /// About topics, the (i) beside the "Topics" heading (owner picks 2026-11-24, item 11), opens
    /// "About topics" (a sheet on iPhone, a popover on iPad); Done closes it.
    func testAboutTopicsOpensAndCloses() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let about = app.buttons["topics.about"]
        XCTAssertTrue(about.exists(within: 8), "the heading has About topics")
        XCTAssertLessThan(about.frame.midY, app.textFields["topics-search-field"].frame.minY,
                          "About sits in the bar, above the search field")
        XCTAssertEqual(about.label, "About topics")
        // 24 pt in the bar, 44 pt square to touch: a tap 2 pt inside the touch area's corner
        // (20 pt right of and below the glyph's centre) opens it. The 0.5 pt allows for a
        // fractional origin at 3x.
        XCTAssertGreaterThanOrEqual(about.frame.width, 23.5, "the glyph's 24 pt box")
        XCTAssertGreaterThanOrEqual(about.frame.height, 23.5, "the glyph's 24 pt box")
        about.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 20)).tap()
        let title = app.staticTexts["About topics"].firstMatch
        XCTAssertTrue(title.exists(within: 6), "About topics opens")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Nothing is deleted.")).firstMatch.exists,
            "the whole explanation is there")
        attach(app, "topics-about")
        app.buttons["topics-about-done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 6), "Done closes it")
        XCTAssertTrue(app.otherElements["topics-view"].firstMatch.exists, "back on the list")
    }

    /// Close and Reopen from a row's menu; Rename from it too.
    func testCloseReopenAndRenameFromTheRowMenu() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let board = row("t-board", in: app)
        XCTAssertTrue(board.exists(within: 8))

        board.press(forDuration: 1.0)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.exists(within: 6), "the row's menu should offer Close")
        close.tap()
        XCTAssertTrue(poll(15, every: 0.3) { (board.value as? String ?? "").hasPrefix("Closed") },
                      "the topic closes: \(String(describing: board.value))")

        board.press(forDuration: 1.0)
        let reopen = app.buttons["Reopen"]
        XCTAssertTrue(reopen.exists(within: 6), "a closed topic offers Reopen")
        reopen.tap()
        XCTAssertTrue(poll(15, every: 0.3) { (board.value as? String ?? "").hasPrefix("Idle") },
                      "the topic reopens: \(String(describing: board.value))")

        board.press(forDuration: 1.0)
        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.exists(within: 6))
        rename.tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.exists(within: 6))
        field.clearAndType("Board pack Q4")
        XCTAssertEqual(field.value as? String, "Board pack Q4", "the field holds only the new title")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(poll(8, every: 0.3) { board.label == "Board pack Q4" }, "renamed: \(board.label)")
    }

    /// `topics_unreachable` keeps the last list on screen, and with topics listed no problem
    /// line shows over them (owner, 2026-11-25: the red-dot line over a list that was there).
    func testUnreachableAgentKeepsTheLastList() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_UNREACHABLE": "1"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        app.buttons["terminal-refresh"].tap()
        // Kept: a negative check; the refresh's failed list must have had time to answer.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.descendants(matching: .any)["topics-problem"].exists,
                       "no problem line over a list that is there")
        XCTAssertTrue(diokan.exists, "the last list stays")
        XCTAssertTrue(row("t-board", in: app).exists)
        attach(app, "topics-kept-without-problem")
    }

    // MARK: Guest

    /// A guest sees and uses the shared agent's topics exactly like the owner (owner decision
    /// 2026-11-19): the Topics tab, the list (polled: guests have no event stream), a topic's
    /// chat and its composer.
    func testGuestSeesAndUsesTopics() {
        let app = launch("guestchat")
        let tab = app.buttons["guest-tab-topics"]
        XCTAssertTrue(tab.exists(within: 12), "a guest gets the Topics tab")
        tab.tap()
        XCTAssertTrue(app.otherElements["topics-view"].firstMatch.exists(within: 8))
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8), "the guest sees the topics")
        attach(app, "topics-guest")
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app), "the guest opens the topic's chat")
        let field = app.textViews["topic-composer-input"]
        XCTAssertTrue(field.exists(within: 8))
        field.tap()
        field.typeText("Guest question for Diokan")
        app.buttons["topic-send-button"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Guest question for Diokan"))
        XCTAssertTrue(sent.firstMatch.exists(within: 10), "the guest's message reaches the topic")
    }

    // MARK: Post-merge review of #745

    /// #758: the agent's first topics lists fail (`topics_unreachable`, as an agent that offers
    /// its topics a moment late); discovery keeps asking and Topics appears, for the owner.
    func testOwnerDiscoveryRetriesAfterAFailedFirstList() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_FAIL_FIRST": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3"])
        openHerdrApp(app)
        XCTAssertTrue(app.buttons["chat-switch-chat"].exists(within: 12), "the page opens as before")
        XCTAssertTrue(app.buttons["chat-switch-topics"].exists(within: 25),
                      "a later list succeeds and the page offers Topics")
        _ = openTopics(app)
        XCTAssertTrue(row("t-diokan", in: app).exists(within: 8))
    }

    /// #758, guest side: the same late agent, and the guest's Topics tab appears.
    func testGuestDiscoveryRetriesAfterAFailedFirstList() {
        let app = launch("guestchat", ["HERDR_MOCK_TOPICS_FAIL_FIRST": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3"])
        XCTAssertTrue(app.buttons["guest-tab-chat"].exists(within: 12))
        XCTAssertTrue(app.buttons["guest-tab-topics"].exists(within: 25),
                      "a later list succeeds and the guest gets the Topics tab")
    }

    /// #759: Settings says Topics; the guest picks Terminal while discovery is still pending.
    /// When the topics arrive the Topics tab appears, but the guest's pick stands. Without a
    /// pick, the same setting does open Topics.
    func testGuestExplicitTabSurvivesTopicsArriving() {
        let picked = launch("guestchat", ["HERDR_MOCK_TOPICS_FAIL_FIRST": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3",
                                          "HERDR_MOCK_CHAT_OPENS_IN": "topics"])
        let terminal = picked.buttons["guest-tab-terminal"]
        XCTAssertTrue(terminal.exists(within: 12))
        XCTAssertFalse(picked.buttons["guest-tab-topics"].exists, "discovery is still pending")
        terminal.tap()
        XCTAssertTrue(picked.buttons["guest-tab-topics"].exists(within: 25), "the topics arrive")
        XCTAssertTrue(terminal.isSelected, "the guest's own pick stands")
        XCTAssertFalse(picked.buttons["guest-tab-topics"].isSelected)
        picked.terminate()

        let unpicked = launch("guestchat", ["HERDR_MOCK_TOPICS_FAIL_FIRST": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3",
                                            "HERDR_MOCK_CHAT_OPENS_IN": "topics"])
        let topics = unpicked.buttons["guest-tab-topics"]
        XCTAssertTrue(topics.exists(within: 25))
        XCTAssertTrue(poll(5, every: 0.3) { topics.isSelected }, "with no pick, Settings' Topics opens Topics")
    }

    /// #760: the agent's own transcript is refused (`transcript_unsupported`), so there is no
    /// Chat, but it has topics: the page still offers Topics | Terminal.
    func testTopicsWithoutInboxChatStillGetAModeSwitch() {
        let refusals = Array(repeating: "transcript_unsupported", count: 80).joined(separator: ",")
        // Opens in Chat (the default), so the page asks for the transcript and learns it is refused.
        let app = launch("chatview", ["HERDR_MOCK_CHAT_STARTUP": refusals])
        openHerdrApp(app)
        let topics = app.buttons["chat-switch-topics"]
        XCTAssertTrue(topics.exists(within: 15), "Topics is offered without the Inbox's Chat")
        XCTAssertTrue(app.buttons["chat-switch-terminal"].exists)
        XCTAssertFalse(app.buttons["chat-switch-chat"].exists, "no Chat segment while the transcript is refused")
        topics.tap()
        XCTAssertTrue(app.otherElements["topics-view"].firstMatch.exists(within: 8))
        XCTAssertTrue(row("t-diokan", in: app).exists(within: 8))
        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(app.otherElements["topics-view"].firstMatch.gone(within: 6), "and back to the terminal")
    }

    /// P3: a send's note belongs to its topic. A queued receipt for Diokan that lands after the
    /// reader opened Q4 board pack shows under Diokan, not under Q4 board pack.
    func testALateSendNoteStaysWithItsTopic() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_SEND_DELAY": "4"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        let field = app.textViews["topic-composer-input"]
        XCTAssertTrue(field.exists(within: 8))
        field.tap()
        field.typeText("Late receipt check")
        app.buttons["topic-send-button"].tap()
        if !isPad { app.buttons["topic-back"].tap() }
        let board = row("t-board", in: app)
        XCTAssertTrue(board.exists(within: 6))
        board.tap()
        XCTAssertTrue(topicChatOpen("Q4 board pack", in: app))
        // The Diokan receipt (queued, after 4 s) lands while Q4 board pack is open.
        let note = app.staticTexts["topic-send-note"].firstMatch
        XCTAssertFalse(note.exists(within: 8), "Diokan's note must not show under Q4 board pack")
        if !isPad { app.buttons["topic-back"].tap() }
        XCTAssertTrue(diokan.exists(within: 6))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        XCTAssertTrue(note.exists(within: 6), "the note waits under Diokan")
        XCTAssertTrue(note.label.hasPrefix("Queued"), note.label)
    }

    // MARK: Post-merge review of #761

    /// #766: a server that lists topics (`agent_topics`) but does not page a topic's
    /// conversation (no `agent_transcript_topic`): opening a topic says so, with no composer.
    func testTopicWithoutTranscriptSupportShowsTheUnavailableState() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_NO_TRANSCRIPT_TOPIC": "1"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8), "the topics still list")
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        XCTAssertTrue(app.staticTexts["topic-chat-unavailable"].exists(within: 10),
                      "the topic says the server can't show its conversation")
        XCTAssertFalse(app.textViews["topic-composer-input"].exists, "no composer that could not show what it sent")
        XCTAssertFalse(app.buttons["topic-send-button"].exists)
        XCTAssertFalse(app.staticTexts["Draft the term sheet comparison for Diokan."].exists,
                       "and no conversation drawn from the Inbox instead")
        attach(app, "topics-transcript-unavailable")
    }

    // MARK: Post-merge review of #768

    /// #775: on a capable server a topic whose session is still starting answers its first
    /// transcript calls with `transcript_unsupported`. That is passing: the chat stays mounted,
    /// keeps polling (1 s, 2 s, …) and shows the conversation once the server answers, without
    /// leaving and reopening the topic, and never shows the permanent unavailable state.
    func testATransientTranscriptRefusalRecoversInPlace() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_TRANSCRIPT_STARTUP": "2"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        XCTAssertFalse(app.staticTexts["topic-chat-unavailable"].exists, "a passing refusal is not the permanent state")
        XCTAssertTrue(app.staticTexts["Draft the term sheet comparison for Diokan."].firstMatch.exists(within: 15),
                      "the conversation appears once the server answers")
        XCTAssertTrue(app.textViews["topic-composer-input"].exists, "and the composer is there")
        XCTAssertFalse(app.staticTexts["topic-chat-unavailable"].exists)
    }

    // MARK: The agent restarts (#777)

    /// #777: the agent's pane answers its first topics list with `agent_not_found`, as while
    /// the agent restarts. That is not "no topics for good": discovery asks again and the page
    /// offers Topics, without leaving it.
    func testTopicsAppearAfterTheAgentWasBrieflyGone() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_GONE_AT": "1", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3"])
        openHerdrApp(app)
        XCTAssertTrue(app.buttons["chat-switch-chat"].exists(within: 12), "the page opens as before")
        XCTAssertTrue(app.buttons["chat-switch-topics"].exists(within: 25),
                      "a later list answers and the page offers Topics")
        _ = openTopics(app)
        XCTAssertTrue(row("t-diokan", in: app).exists(within: 8))
    }

    /// #777: Topics were offered, then the list Topics asks for on opening finds the pane
    /// without its agent (`agent_not_found`, the agent restarting). The page keeps Topics and
    /// the last list, with no problem line over it, and the next list keeps both.
    func testTopicsStayAfterTheAgentIsBrieflyGoneWhileOffered() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_GONE_AT": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        // Kept: a negative check; the failed list on opening must have had time to answer.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.descendants(matching: .any)["topics-problem"].exists,
                       "no problem line over a list that is there")
        XCTAssertTrue(diokan.exists, "the last list stays")
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected, "and so does Topics")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(diokan.exists(within: 8))
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected)
    }

    // MARK: A topic behaves like the Inbox chat (2026-11-25)

    /// A working topic shows the Inbox's working dots in its chat, and the model line under
    /// it from the topic's page; an idle one shows no dots.
    func testATopicShowsTheWorkingDotsAndTheModel() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        let dots = app.descendants(matching: .any)["chat-working"].firstMatch
        XCTAssertTrue(dots.exists(within: 10), "a running topic shows the working dots, as the Inbox does")
        let model = app.descendants(matching: .any)["chat-model"].firstMatch
        XCTAssertTrue(model.exists(within: 10), "the topic's model line shows")
        XCTAssertTrue(model.label.contains("mock-topic-model"), model.label)
        attach(app, "topics-working-dots")

        if !isPad {
            app.buttons["topic-back"].tap()
        }
        let board = row("t-board", in: app)
        XCTAssertTrue(board.exists(within: 8))
        board.tap()
        XCTAssertTrue(topicChatOpen("Q4 board pack", in: app))
        XCTAssertTrue(app.staticTexts["Liquidity page drafted; waiting on the November actuals."]
            .firstMatch.exists(within: 10))
        XCTAssertFalse(dots.exists, "an idle topic shows no dots")
    }

    /// iPhone: a topic is full screen, without the page's switch, so its header has Terminal,
    /// which opens the agent's pane; Topics brings the topic back. iPad keeps the switch.
    func testPhoneTopicHeaderOpensTheTerminal() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        let terminal = app.buttons["topic-terminal"]
        if isPad {
            XCTAssertFalse(terminal.exists, "iPad keeps the page's switch beside the topic")
            XCTAssertTrue(app.buttons["chat-switch-terminal"].exists)
            return
        }
        XCTAssertTrue(terminal.exists(within: 5), "the topic's header offers the Terminal")
        XCTAssertTrue(terminal.isHittable)
        attach(app, "topics-phone-terminal-button")
        terminal.tap()
        let terminalSegment = app.buttons["chat-switch-terminal"]
        XCTAssertTrue(terminalSegment.exists(within: 8), "the page and its switch are back")
        XCTAssertTrue(poll(8, every: 0.3) { terminalSegment.isSelected }, "on the agent's terminal")
        app.buttons["chat-switch-topics"].tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app), "Topics brings the open topic back")
    }

    /// The agent is busy: every list times out. The session file's topics (`topic_sessions`
    /// on `agent.list`) fill the list at once, with no problem line, and open their chats.
    func testTopicsFillFromTheSessionFileWhileTheAgentIsBusy() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_SESSIONS": "1", "HERDR_MOCK_TOPICS_FAIL_FIRST": "1000",
                                      "HERDR_MOCK_TOPICS_FAIL_CODE": "topics_timeout"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8), "the session file's topics are listed")
        XCTAssertEqual(diokan.label, "Diokan term sheet")
        XCTAssertTrue(row("t-board", in: app).exists)
        XCTAssertTrue(row("t-nippon", in: app).exists)
        // Kept: a negative check; the timed-out lists must have had time to answer.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.descendants(matching: .any)["topics-problem"].exists,
                       "no problem line over the listed topics")
        attach(app, "topics-from-session-file")
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        XCTAssertTrue(app.staticTexts["Draft the term sheet comparison for Diokan."]
            .firstMatch.exists(within: 10), "the topic's conversation reads from its file")
    }

    /// herdr answers `topics_unsupported` while it does not find the agent in its pane for a
    /// moment. With topics in the session file that is not "no topics": Topics and its list stay.
    func testTopicsUnsupportedDoesNotHideTopicsTheSessionFileLists() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_SESSIONS": "1", "HERDR_MOCK_TOPICS_FAIL_FIRST": "1000",
                                      "HERDR_MOCK_TOPICS_FAIL_CODE": "topics_unsupported"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        app.buttons["terminal-refresh"].tap()
        // Kept: a negative check; the refused lists must have had time to answer.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected, "Topics stays")
        XCTAssertTrue(diokan.exists, "and so does its list")
    }

    /// The topic's composer has the Inbox's pull-to-expand editor: three lines offer the
    /// handle, and a tap opens a taller editor.
    func testTopicComposerOffersTheExpandHandle() {
        let app = launch("chatview")
        openHerdrApp(app)
        _ = openTopics(app)
        let board = row("t-board", in: app)
        XCTAssertTrue(board.exists(within: 8))
        board.tap()
        XCTAssertTrue(topicChatOpen("Q4 board pack", in: app))
        let field = app.textViews["topic-composer-input"]
        XCTAssertTrue(field.exists(within: 8))
        field.tap()
        field.typeText("one")
        field.waitForSettledFrame()
        let oneLine = field.frame
        field.typeText("\ntwo\nthree")
        _ = poll(5, every: 0.1) { field.frame.height > oneLine.height }
        field.waitForSettledFrame()
        let threeLines = field.frame
        XCTAssertGreaterThan(threeLines.height, oneLine.height)
        let handle = app.descendants(matching: .any)["composer-expand-handle"].firstMatch
        XCTAssertTrue(handle.exists(within: 3), "three lines offer the expand handle in a topic")
        handle.tap()
        _ = poll(5, every: 0.1) { field.frame.height > threeLines.height + 20 }
        XCTAssertGreaterThan(field.frame.height, threeLines.height + 20, "tapping the handle opens the editor")
        attach(app, "topics-composer-editor")
    }

    /// A message the Inbox handed the topic (`relay`) reads as the agent's text under "From
    /// Inbox", not as the owner's bubble, folded after about six lines until "Show all".
    func testAHandedOverMessageReadsFromTheInbox() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_RELAY": "1"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        diokan.tap()
        XCTAssertTrue(topicChatOpen("Diokan term sheet", in: app))
        let from = app.staticTexts["chat-relay-from"].firstMatch
        XCTAssertTrue(from.exists(within: 10), "the handed-over message names its sender")
        XCTAssertEqual(from.label, "From Inbox")
        let toggle = app.buttons["chat-relay-toggle"].firstMatch
        XCTAssertTrue(toggle.exists(within: 5), "a long one is folded")
        XCTAssertEqual(toggle.label, "Show all")
        let relay = app.descendants(matching: .any)["chat-relay"].firstMatch
        let folded = relay.frame.height
        attach(app, "topics-relay-folded")
        toggle.tap()
        XCTAssertTrue(poll(5, every: 0.2) { toggle.label == "Show less" })
        XCTAssertTrue(poll(5, every: 0.2) { relay.frame.height > folded + 20 }, "Show all unfolds it")
    }

    /// The topic's composer is the Inbox's: Saved Prompts in Send's slot while the draft is
    /// empty, the paperclip's sheet with files and photos, a chip that uploads at once, and on
    /// Send the file posted as a Gram and named in the message the topic gets.
    func testATopicTakesAttachmentsLikeTheInbox() {
        let app = launch("chatview", ["HERDR_MOCK_PICKED_FILE": "1"])
        openHerdrApp(app)
        _ = openTopics(app)
        let board = row("t-board", in: app)
        XCTAssertTrue(board.exists(within: 8))
        board.tap()
        XCTAssertTrue(topicChatOpen("Q4 board pack", in: app))
        XCTAssertTrue(app.descendants(matching: .any)["topic-saved-prompts"].exists(within: 5),
                      "an empty draft offers Saved Prompts where Send goes, as in the Inbox")
        let paperclip = app.buttons["topic-attach-button"]
        XCTAssertTrue(paperclip.exists(within: 8), "the topic's composer has the paperclip")
        XCTAssertTrue(poll(10, every: 0.25) { paperclip.isEnabled }, "attach opens once the topics have loaded")
        paperclip.tap()
        let file = app.buttons["composer-attach-file"]
        XCTAssertTrue(file.exists(within: 5), "the paperclip opens the Inbox's attach sheet")
        XCTAssertTrue(app.buttons["composer-attach-photos"].exists, "with the photo library as well as files")
        file.tap()
        let chip = app.descendants(matching: .any)["topic-attachment"].firstMatch
        XCTAssertTrue(chip.exists(within: 10), "the picked file stages a chip")
        XCTAssertTrue(app.staticTexts["picked-notes.txt"].firstMatch.exists)
        attach(app, "topics-attachment-chip")

        let field = app.textViews["topic-composer-input"]
        field.tap()
        field.typeText("Use these numbers")
        app.buttons["topic-send-button"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Use these numbers"))
        XCTAssertTrue(sent.firstMatch.exists(within: 15), "the message reaches the topic")
        XCTAssertTrue(poll(15, every: 0.25) { !chip.exists }, "the chip clears once the file is delivered")
        let note = app.staticTexts["topic-send-note"]
        XCTAssertFalse(note.exists, "the send does not fail: \(note.exists ? note.label : "")")
        // What the topic accepted, not the optimistic bubble: the caption and how to fetch
        // the Gram that was posted (the mock's post answers id gp1).
        let sends = probe("topic-send-calls", in: app)
        XCTAssertTrue(poll(10, every: 0.3) { sends.label.contains("herdr gram get-file gp1") },
                      "the topic got the file's download reference: \(sends.label)")
        XCTAssertTrue(sends.label.hasPrefix("Use these numbers"), "with the caption first: \(sends.label)")
        XCTAssertEqual(gramPosts(in: app), 1, "one Gram, to the agent")
        XCTAssertTrue(probe("topic-gram-posts", in: app).label.contains("file=picked-notes.txt@"))
        attach(app, "topics-attachment-sent")
    }

    // MARK: The topic's draft (#852, #853, #854)

    /// herdr refuses the message before it reaches the topic (`invalid_params`, its size
    /// gate): nothing was sent, so the caption and the chip stay, and Send again sends the
    /// message with the Gram already posted, not a second one (#852).
    func testARefusedAttachmentMessageKeepsTheDraftAndItsGram() {
        let app = launch("chatview", ["HERDR_MOCK_PICKED_FILE": "1", "HERDR_MOCK_TOPICS_SEND_REFUSE": "invalid_params"])
        let chip = openTopicWithAFile("t-board", "Q4 board pack", in: app)
        let field = app.textViews["topic-composer-input"]
        field.tap()
        field.typeText("Use these numbers")
        app.buttons["topic-send-button"].tap()
        XCTAssertTrue(app.staticTexts["topic-send-note"].exists(within: 15), "the refusal is said")
        XCTAssertTrue(poll(10, every: 0.25) { (field.value as? String ?? "").contains("Use these numbers") },
                      "the caption comes back for a retry")
        XCTAssertTrue(chip.exists, "and the file stays")
        XCTAssertEqual(probe("topic-send-calls", in: app).label, "none", "the topic got nothing")
        XCTAssertEqual(gramPosts(in: app), 1)

        app.buttons["topic-send-button"].tap()
        let sends = probe("topic-send-calls", in: app)
        XCTAssertTrue(poll(15, every: 0.3) { sends.label.contains("herdr gram get-file gp1") },
                      "the retry sends the message: \(sends.label)")
        XCTAssertTrue(sends.label.hasPrefix("Use these numbers"))
        XCTAssertTrue(poll(15, every: 0.25) { !chip.exists }, "the chip clears once it is delivered")
        XCTAssertEqual(gramPosts(in: app), 1, "the retry reuses the Gram it posted")
    }

    /// The topic's conversation cannot load, so a send could not be shown: Send posts no
    /// Gram and keeps the draft (#853), as the Inbox checks before it posts.
    func testATopicThatCannotShowTheSendPostsNoGram() {
        let app = launch("chatview", ["HERDR_MOCK_PICKED_FILE": "1", "HERDR_MOCK_TOPICS_TRANSCRIPT_STARTUP": "1000"])
        let chip = openTopicWithAFile("t-board", "Q4 board pack", in: app)
        let field = app.textViews["topic-composer-input"]
        field.tap()
        field.typeText("Use these numbers")
        app.buttons["topic-send-button"].tap()
        XCTAssertTrue(poll(20, every: 0.25) { (field.value as? String ?? "").contains("Use these numbers") },
                      "the caption comes back: the message was not sent")
        XCTAssertTrue(chip.exists, "and the file stays")
        XCTAssertEqual(probe("topic-gram-posts", in: app).label, "none", "no Gram for a message not sent")
        XCTAssertEqual(probe("topic-send-calls", in: app).label, "none")
    }

    /// The Terminal and back: the topic's draft, its text and its file, is still there (#854).
    func testTheTerminalKeepsTheTopicsDraft() {
        let app = launch("chatview", ["HERDR_MOCK_PICKED_FILE": "1"])
        _ = openTopicWithAFile("t-board", "Q4 board pack", in: app)
        let field = app.textViews["topic-composer-input"]
        field.tap()
        field.typeText("Keep me")
        if isPad {
            app.buttons["chat-switch-terminal"].tap()
        } else {
            app.buttons["topic-terminal"].tap()
        }
        let terminalSegment = app.buttons["chat-switch-terminal"]
        XCTAssertTrue(poll(8, every: 0.3) { terminalSegment.exists && terminalSegment.isSelected }, "on the terminal")
        app.buttons["chat-switch-topics"].tap()
        XCTAssertTrue(topicChatOpen("Q4 board pack", in: app), "Topics brings the topic back")
        XCTAssertTrue(app.descendants(matching: .any)["topic-attachment"].firstMatch.exists(within: 5),
                      "with its file")
        XCTAssertTrue((app.textViews["topic-composer-input"].value as? String ?? "").contains("Keep me"),
                      "and its text")
        XCTAssertEqual(gramPosts(in: app), 0, "nothing was sent")
    }

    /// Opens a topic and stages the attach sheet's file (`HERDR_MOCK_PICKED_FILE`); its chip.
    private func openTopicWithAFile(_ id: String, _ title: String, in app: XCUIApplication) -> XCUIElement {
        openHerdrApp(app)
        _ = openTopics(app)
        let topicRow = row(id, in: app)
        XCTAssertTrue(topicRow.exists(within: 8))
        topicRow.tap()
        XCTAssertTrue(topicChatOpen(title, in: app))
        let paperclip = app.buttons["topic-attach-button"]
        XCTAssertTrue(paperclip.exists(within: 8))
        XCTAssertTrue(poll(10, every: 0.25) { paperclip.isEnabled }, "attach opens once the topics have loaded")
        paperclip.tap()
        let file = app.buttons["composer-attach-file"]
        XCTAssertTrue(file.exists(within: 5))
        file.tap()
        let chip = app.descendants(matching: .any)["topic-attachment"].firstMatch
        XCTAssertTrue(chip.exists(within: 10), "the picked file stages a chip")
        return chip
    }

    /// TopicChat's DEBUG probes (`topic-send-calls`, `topic-gram-posts`): labels.
    private func probe(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// How many `gram.post` calls the mock answered, from `topic-gram-posts`.
    private func gramPosts(in app: XCUIApplication) -> Int {
        let label = probe("topic-gram-posts", in: app).label
        return label == "none" ? 0 : label.components(separatedBy: "\n").count
    }
}
