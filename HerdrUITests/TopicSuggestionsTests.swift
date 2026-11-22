import UIKit
import XCTest

/// The Topics switch, topic suggestions and Organise (proposal 3, owner pick 2026-11-22), against
/// the `chatview` (owner, herdr-app) and `guestchat` (guest, llm-opt) mocks with
/// `HERDR_MOCK_TOPICS`, `HERDR_MOCK_TOPICS_SUGGEST` (the Inbox opens with one open suggestion;
/// Organise proposes three topics) and `HERDR_MOCK_TOPICS_SWITCH` (herdr-app lists
/// `topics_enabled: false`). The agent picks the messages; nothing here selects one.
final class TopicSuggestionsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// `still: false` keeps working agents working: keephair (Claude) is listed outside the
    /// collapsed Idle group only while it works, as in `ChatViewTests.testClaudeAgentHasNoSwitch`.
    private func launch(_ mock: String, _ environment: [String: String] = [:], still: Bool = true) -> XCUIApplication {
        var base = ["HERDR_STEADY_CARET": "1", "HERDR_MOCK_TOPICS": "1",
                    "HERDR_MOCK_TOPICS_SUGGEST": "1", "HERDR_MOCK_TOPICS_SWITCH": "1"]
        if still { base["HERDR_MOCK_STILL"] = "1" }
        return XCUIApplication.launched(mock: mock, environment: base.merging(environment) { _, new in new })
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openHerdrApp(_ app: XCUIApplication) {
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.exists(within: 12), "the home should list herdr-app")
        row.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The suggestion's card, scrolled into view (it closes the newest turn).
    private func suggestionCard(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let card = any(app, "chat-topic-suggestion-\(id)")
        XCTAssertTrue(card.exists(within: 12), "the Inbox shows the agent's suggestion")
        return card
    }

    // MARK: Switch

    /// Long-press herdr-app: Turn on topics, next to Restart agent. It confirms first (it
    /// restarts the agent), then calls `agent.topics.set_enabled`; the list then offers Turn off.
    func testSwitchConfirmsThenTurnsTopicsOn() {
        let app = launch("chatview")
        let row = any(app, "agent-row-w9:p1")
        XCTAssertTrue(row.exists(within: 12))
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Restart agent"].exists(within: 5))
        let turnOn = app.buttons["Turn on topics"]
        XCTAssertTrue(turnOn.exists, "an omp agent with the capability offers the switch")
        XCTAssertFalse(app.buttons["Turn off topics"].exists)
        turnOn.tap()

        XCTAssertTrue(app.staticTexts["Turn on topics for herdr-app?"].exists(within: 5), "it confirms first")
        XCTAssertTrue(app.staticTexts["herdr restarts it on the omp build with topics. Its conversation and name stay."]
            .exists)
        shot(app, "topics-switch-confirm")
        app.buttons["Restart with topics"].tap()

        let status = any(app, "topics-switch-status")
        XCTAssertTrue(status.exists(within: 10), "the switch shows its progress and result")
        XCTAssertTrue(poll(10, every: 0.3) { status.label.contains("Topics are on for herdr-app.") },
                      "the result: \(status.label)")
        shot(app, "topics-switch-done")

        XCTAssertTrue(poll(10, every: 0.5) {
            row.press(forDuration: 1.0)
            let off = app.buttons["Turn off topics"].exists(within: 3)
            if !off { app.tap() }
            return off
        }, "the call went through: the agent now lists topics on")
    }

    /// Only omp agents get the switch: keephair is Claude. It must be working to be listed
    /// outside the collapsed Idle group, so this launch is not still.
    func testSwitchIsOnlyForOmpAgents() {
        let app = launch("chatview", still: false)
        let row = any(app, "agent-row-w9:p2")
        XCTAssertTrue(row.exists(within: 12))
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Restart agent"].exists(within: 5))
        XCTAssertFalse(app.buttons["Turn on topics"].exists, "not an omp agent")
        XCTAssertFalse(app.buttons["Turn off topics"].exists)
    }

    // MARK: Suggestion in the Inbox

    /// The Inbox marks where the subject began and asks at the suggestion: title, reason, how
    /// many messages come along, Start and Not now. Start opens the topic; back in the Inbox
    /// the card is one line, "Continued in topic <title>", which opens it again.
    func testStartOpensTheTopicAndLeavesANoteInTheInbox() {
        let app = launch("chatview")
        openHerdrApp(app)
        let card = suggestionCard("sg-scroll", in: app)
        XCTAssertTrue(any(app, "chat-topic-suggestion-title").label.contains("Terminal scrollback"))
        XCTAssertTrue(any(app, "chat-topic-suggestion-count").label.contains("12 earlier messages come along"),
                      "the agent picked the messages; the card says how many")
        XCTAssertFalse(app.buttons["Choose messages"].exists, "no message selection")
        XCTAssertTrue(any(app, "chat-topic-suggestion-mark-sg-scroll").exists,
                      "a line marks where the subject began")
        shot(app, "topic-suggestion-open")

        card.buttons["chat-topic-suggestion-start"].tap()
        let title = app.staticTexts["topic-chat-title"].firstMatch
        XCTAssertTrue(poll(10, every: 0.3) { title.exists && title.label == "Terminal scrollback" },
                      "Start opens the new topic")
        shot(app, "topic-suggestion-started")

        app.buttons["chat-switch-chat"].tap()
        let note = any(app, "chat-topic-continued-sg-scroll")
        XCTAssertTrue(note.exists(within: 10), "the Inbox keeps one line for it")
        XCTAssertTrue(note.label.contains("Continued in topic"), note.label)
        XCTAssertTrue(note.label.contains("Terminal scrollback"), note.label)
        XCTAssertFalse(any(app, "chat-topic-suggestion-sg-scroll").exists, "the card is gone")
        XCTAssertFalse(any(app, "chat-topic-suggestion-mark-sg-scroll").exists, "and its marker")
        shot(app, "topic-suggestion-continued")

        note.tap()
        XCTAssertTrue(poll(10, every: 0.3) { title.exists && title.label == "Terminal scrollback" },
                      "the line opens the topic")
    }

    /// Not now: the card becomes one faint line and nothing else changes.
    func testNotNowLeavesADismissedLine() {
        let app = launch("chatview")
        openHerdrApp(app)
        let card = suggestionCard("sg-scroll", in: app)
        card.buttons["chat-topic-suggestion-dismiss"].tap()
        let line = any(app, "chat-topic-suggestion-dismissed-sg-scroll")
        XCTAssertTrue(line.exists(within: 10), "a dismissed suggestion is one quiet line")
        XCTAssertTrue(line.label.contains("Terminal scrollback"), line.label)
        XCTAssertFalse(any(app, "chat-topic-suggestion-sg-scroll").exists, "no card any more")
        XCTAssertFalse(any(app, "chat-topic-suggestion-mark-sg-scroll").exists)
        XCTAssertFalse(app.staticTexts["topic-chat-title"].exists, "no topic opened")
        shot(app, "topic-suggestion-dismissed")
    }

    /// The fork lists an open suggestion (and sends `agent.topics.changed`) at once, but its
    /// transcript entry lands only after the Inbox's turn ends: the card shows from the list.
    func testSuggestionShowsFromTheListBeforeTheTranscriptHasIt() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_SUGGEST_LIST_ONLY": "1"])
        openHerdrApp(app)
        let card = suggestionCard("sg-scroll", in: app)
        XCTAssertTrue(any(app, "chat-topic-suggestion-count").label.contains("12 earlier messages come along"))
        XCTAssertTrue(any(app, "chat-topic-suggestion-mark-sg-scroll").exists, "the marker comes from the list too")
        card.buttons["chat-topic-suggestion-start"].tap()
        let title = app.staticTexts["topic-chat-title"].firstMatch
        XCTAssertTrue(poll(10, every: 0.3) { title.exists && title.label == "Terminal scrollback" })
        let status = app.descendants(matching: .any)["topic-status-t-sug-1"].firstMatch
        XCTAssertTrue(status.exists(within: 5), "the new topic shows its status")
        XCTAssertTrue(status.label.contains("Starting"), "a seeding topic is starting: \(status.label)")

        // Back in the Inbox the transcript still has no entry: the line is the app's own.
        app.buttons["chat-switch-chat"].tap()
        let note = any(app, "chat-topic-continued-sg-scroll")
        XCTAssertTrue(note.exists(within: 10), "Continued in topic shows at once, before the transcript has it")
        XCTAssertTrue(note.label.contains("Terminal scrollback"), note.label)
        XCTAssertFalse(any(app, "chat-topic-suggestion-sg-scroll").exists, "no card any more")
    }

    /// Not now on a suggestion only the list has: the compact line shows at once.
    func testNotNowOnAListOnlySuggestionShowsTheLineAtOnce() {
        let app = launch("chatview", ["HERDR_MOCK_TOPICS_SUGGEST_LIST_ONLY": "1"])
        openHerdrApp(app)
        suggestionCard("sg-scroll", in: app).buttons["chat-topic-suggestion-dismiss"].tap()
        let line = any(app, "chat-topic-suggestion-dismissed-sg-scroll")
        XCTAssertTrue(line.exists(within: 10), "the Not now line shows before the transcript entry arrives")
        XCTAssertTrue(line.label.contains("Terminal scrollback"), line.label)
        XCTAssertFalse(any(app, "chat-topic-suggestion-sg-scroll").exists)
        XCTAssertFalse(any(app, "chat-topic-suggestion-mark-sg-scroll").exists)
    }

    // MARK: Organise

    /// Organise in the Topics bar: the proposals appear in the list, ticked, above the topics.
    /// Untick one, Create 2 topics: the two become topics, and the list has no proposals left.
    func testOrganiseProposesTickedTopicsAndCreatesThem() {
        let app = launch("chatview")
        openHerdrApp(app)
        // The Inbox's own open suggestion is set aside first, so the list holds Organise's only.
        suggestionCard("sg-scroll", in: app).buttons["chat-topic-suggestion-dismiss"].tap()
        XCTAssertTrue(any(app, "chat-topic-suggestion-dismissed-sg-scroll").exists(within: 10))

        let segment = app.buttons["chat-switch-topics"]
        XCTAssertTrue(segment.exists(within: 12))
        segment.tap()
        let organise = app.buttons["topics-organise"]
        XCTAssertTrue(organise.exists(within: 10), "Organise is a word in the Topics bar")
        organise.tap()

        let servers = app.buttons["topics-proposal-sg-org-servers"]
        let ci = app.buttons["topics-proposal-sg-org-ci"]
        let checks = app.buttons["topics-proposal-sg-org-checks"]
        XCTAssertTrue(servers.exists(within: 15), "the proposals appear in the list")
        XCTAssertTrue(ci.exists && checks.exists)
        for proposal in [servers, ci, checks] {
            XCTAssertTrue((proposal.value as? String ?? "").hasPrefix("Ticked"), "ticked: \(String(describing: proposal.value))")
        }
        XCTAssertLessThan(servers.frame.minY, app.buttons["topic-row-t-diokan"].frame.minY, "above the topics")
        let create = app.buttons["topics-proposals-create"]
        XCTAssertEqual(create.label, "Create 3 topics")
        XCTAssertTrue(app.buttons["topics-proposals-dismiss"].exists, "with Not now")
        shot(app, "topics-organise-proposals")

        checks.tap()
        XCTAssertTrue(poll(5, every: 0.2) { (checks.value as? String ?? "").hasPrefix("Not ticked") })
        XCTAssertEqual(create.label, "Create 2 topics")
        create.tap()

        XCTAssertTrue(servers.waitForNonExistence(timeout: 10), "the proposals are settled")
        XCTAssertFalse(checks.exists, "the unticked one is dismissed")
        XCTAssertFalse(app.buttons["topics-proposals-create"].exists)
        let created = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "topic-row-t-sug-"))
        XCTAssertTrue(poll(10, every: 0.3) { created.count == 2 }, "two topics were created, got \(created.count)")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Server updates")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Fork CI")).firstMatch.exists)
        shot(app, "topics-organise-created")
    }

    // MARK: Guest

    /// A guest sees the suggestion and may act on it, but has no Topics switch.
    func testGuestSeesTheSuggestionButNotTheSwitch() {
        let app = launch("guestchat")
        XCTAssertTrue(app.buttons["guest-tab-chat"].exists(within: 12))
        let card = suggestionCard("sg-bench", in: app)
        XCTAssertTrue(card.buttons["chat-topic-suggestion-start"].exists, "guests may start it")
        XCTAssertTrue(card.buttons["chat-topic-suggestion-dismiss"].exists, "and set it aside")
        XCTAssertTrue(any(app, "chat-topic-suggestion-count").label.contains("12 earlier messages come along"))
        XCTAssertFalse(app.buttons["Turn on topics"].exists, "the switch is the owner's")
        XCTAssertFalse(app.buttons["Turn off topics"].exists)
        shot(app, "topic-suggestion-guest")

        card.buttons["chat-topic-suggestion-start"].tap()
        let title = app.staticTexts["topic-chat-title"].firstMatch
        XCTAssertTrue(poll(10, every: 0.3) { title.exists && title.label == "TensorFold bench" },
                      "a guest's Start opens the topic too")
        XCTAssertFalse(app.buttons["Turn on topics"].exists)
    }
}
