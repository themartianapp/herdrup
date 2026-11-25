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
        XCTAssertGreaterThanOrEqual(about.frame.width, 44, "a 44 pt target")
        XCTAssertGreaterThanOrEqual(about.frame.height, 44, "a 44 pt target")
        about.tap()
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

    /// `topics_unreachable` keeps the last list on screen and says the agent can't be reached.
    func testUnreachableAgentKeepsTheLastList() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_UNREACHABLE": "1"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        app.buttons["terminal-refresh"].tap()
        let problem = app.descendants(matching: .any)["topics-problem"].firstMatch
        XCTAssertTrue(problem.exists(within: 8), "the refresh's failure is shown")
        XCTAssertTrue(problem.label.contains("Agent not reachable"), problem.label)
        XCTAssertTrue(diokan.exists, "the last list stays")
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
    /// the last list with a passing problem, and the next list clears it.
    func testTopicsStayAfterTheAgentIsBrieflyGoneWhileOffered() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_GONE_AT": "2", "HERDR_MOCK_TOPICS_DISCOVERY_SECONDS": "3"])
        openHerdrApp(app)
        _ = openTopics(app)
        let diokan = row("t-diokan", in: app)
        XCTAssertTrue(diokan.exists(within: 8))
        let problem = app.descendants(matching: .any)["topics-problem"].firstMatch
        XCTAssertTrue(problem.exists(within: 8), "the failed list shows as a problem")
        XCTAssertTrue(problem.label.contains("This agent is gone."), problem.label)
        XCTAssertTrue(diokan.exists, "the last list stays")
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected, "and so does Topics")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(problem.gone(within: 8), "the agent is back: the next list clears the problem")
        XCTAssertTrue(diokan.exists)
        XCTAssertTrue(app.buttons["chat-switch-topics"].isSelected)
    }
}
