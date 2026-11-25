import UIKit
import XCTest

/// "Topics · A, revised" (owner pick 2026-11-23) as the owner's picks of 2026-11-24 left it: the
/// Topics screens from the `chatview` mock (herdr-app with topics and suggestions), kept as
/// attachments to compare with the desktop's. Each step also checks the controls the design adds:
/// the column toggle and ⌥⌘T fold on iPad, "‹ Inbox", "‹ Topics", About beside the heading, and
/// the couldn't-start note's Dismiss.
final class TopicsDesignShotsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
        let base = ["HERDR_STEADY_CARET": "1", "HERDR_MOCK_STILL": "1", "HERDR_MOCK_TOPICS": "1",
                    "HERDR_MOCK_TOPICS_SUGGEST": "1"]
        let app = XCUIApplication.launched(mock: "chatview", environment: base.merging(environment) { _, new in new })
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.exists(within: 12), "the home should list herdr-app")
        row.tap()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = (isPad ? "ipad-" : "iphone-") + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func topicTitle(_ title: String, in app: XCUIApplication) -> Bool {
        let header = app.staticTexts["topic-chat-title"].firstMatch
        return poll(10, every: 0.3) { header.exists && header.label == title }
    }

    /// The Inbox with its suggestion card, the topics list, a topic, and (iPad) the column
    /// folded and back.
    func testTopicsScreens() {
        let app = launch()
        let card = any(app, "chat-topic-suggestion-sg-scroll")
        XCTAssertTrue(card.exists(within: 12), "the Inbox shows the agent's suggestion")
        XCTAssertTrue(card.buttons["chat-topic-suggestion-dismiss"].exists, "Not now")
        XCTAssertTrue(card.buttons["chat-topic-suggestion-start"].exists, "Start")
        shot(app, "topics-a2-inbox")

        let segment = app.buttons["chat-switch-topics"]
        XCTAssertTrue(segment.exists(within: 12))
        segment.tap()
        let diokan = app.buttons["topic-row-t-diokan"].firstMatch
        XCTAssertTrue(diokan.exists(within: 8), "the topics load")
        XCTAssertTrue(app.buttons["topics-inbox-row"].exists, "the Inbox is the first row")
        XCTAssertTrue(app.buttons["topics-new"].exists, "New topic, a capsule")
        XCTAssertTrue(app.buttons["topics-about"].exists, "About, beside the heading")
        XCTAssertEqual(app.buttons["topics-column-toggle"].exists, isPad, "the column toggle is iPad's")
        shot(app, "topics-a2-list")

        diokan.tap()
        XCTAssertTrue(topicTitle("Diokan term sheet", in: app), "the topic opens")
        if isPad {
            XCTAssertTrue(app.buttons["topic-inbox-link"].exists, "‹ Inbox in the topic header")
        } else {
            XCTAssertTrue(app.buttons["topic-back"].exists, "‹ Topics")
            XCTAssertFalse(app.buttons["chat-switch-topics"].exists, "the topic is its own screen")
        }
        shot(app, "topics-a2-topic")

        if isPad {
            app.buttons["topics-column-toggle"].tap()
            XCTAssertTrue(diokan.gone(within: 5), "folded, the column is gone")
            let show = app.buttons["topics-column-show"]
            XCTAssertTrue(show.exists(within: 5), "Topics ⌥⌘T brings it back")
            XCTAssertTrue(topicTitle("Diokan term sheet", in: app), "the topic stays open")
            shot(app, "topics-a2-folded")
            show.tap()
            XCTAssertTrue(diokan.exists(within: 5), "the column is back")
            app.buttons["topic-inbox-link"].tap()
        } else {
            app.buttons["topic-back"].tap()
            XCTAssertTrue(app.buttons["topics-inbox-row"].exists(within: 6), "back to the list")
            app.buttons["topics-inbox-row"].tap()
        }
        let chat = app.buttons["chat-switch-chat"]
        XCTAssertTrue(poll(8, every: 0.3) { chat.exists && chat.isSelected }, "the Inbox is the Chat view")
    }

    /// Start, then back in the Inbox: "Continued in topic" with the title as a link.
    func testContinuedInTopicLink() {
        let app = launch()
        let card = any(app, "chat-topic-suggestion-sg-scroll")
        XCTAssertTrue(card.exists(within: 12))
        card.buttons["chat-topic-suggestion-start"].tap()
        XCTAssertTrue(topicTitle("Terminal scrollback", in: app), "Start opens the topic")
        if isPad {
            app.buttons["topic-inbox-link"].tap()
        } else {
            app.buttons["topic-back"].tap()
            let chat = app.buttons["chat-switch-chat"]
            XCTAssertTrue(chat.exists(within: 6))
            chat.tap()
        }
        let link = any(app, "chat-topic-continued-sg-scroll")
        XCTAssertTrue(link.exists(within: 10), "the Inbox keeps one line for it")
        XCTAssertTrue(link.label.contains("Continued in topic Terminal scrollback"), link.label)
        shot(app, "topics-a2-continued")
    }

    /// A start that could not happen (`seed_too_large`): one dim line inside the card with its
    /// Dismiss, above Not now and Start; Dismiss clears it and the card keeps Start.
    func testCouldNotStartNoteDismisses() {
        let app = launch(["HERDR_MOCK_TOPICS_SEED_TOO_LARGE": "1"])
        let card = any(app, "chat-topic-suggestion-sg-scroll")
        XCTAssertTrue(card.exists(within: 12))
        card.buttons["chat-topic-suggestion-start"].tap()
        let note = card.descendants(matching: .any)["chat-topic-suggestion-problem"].firstMatch
        XCTAssertTrue(note.exists(within: 10), "the note says why, inside the card")
        let dismiss = card.buttons["chat-topic-suggestion-problem-dismiss"]
        XCTAssertTrue(dismiss.exists, "the note has Dismiss")
        XCTAssertTrue(card.buttons["chat-topic-suggestion-dismiss"].exists, "the card keeps Not now")
        XCTAssertLessThan(note.frame.maxY, card.buttons["chat-topic-suggestion-start"].frame.minY,
                          "the note sits above the card's buttons")
        shot(app, "topics-a2-couldnt-start")
        dismiss.tap()
        XCTAssertTrue(note.gone(within: 5), "Dismiss clears the note")
        XCTAssertTrue(card.buttons["chat-topic-suggestion-start"].isEnabled, "the card keeps Start")
    }
}
