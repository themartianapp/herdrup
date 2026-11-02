import XCTest

/// The one-time GitHub star card (`GitHubStarPrompt`), over the `chatview` mock with
/// `HERDR_MOCK_STAR_PROMPT` (every other mock run keeps the card hidden): it appears after
/// the fifth owner prompt, "Not now" removes it, and a relaunch does not bring it back.
final class GitHubStarPromptTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Answered at launch so herdr-app takes a reply as a prompt, not as menu keys; not
    /// `HERDR_MOCK_STILL`, so herdr-app stays out of the collapsed Idle section.
    private func launch(_ flag: String) -> XCUIApplication {
        XCUIApplication.launched(mock: "chatview", environment: [
            "HERDR_STEADY_CARET": "1",
            "HERDR_MOCK_CHAT_ANSWERED": "Yes, merge and deploy",
            "HERDR_MOCK_STAR_PROMPT": flag,
        ])
    }

    private func openHerdrApp(_ app: XCUIApplication) {
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 12), "the home should list herdr-app")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 10))
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["github-star-card"].firstMatch
    }

    /// Types and sends one prompt, then waits for the chat to show it.
    private func sendPrompt(_ text: String, in app: XCUIApplication) {
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(text)
        var send: XCUIElement?
        XCTAssertTrue(poll(8, every: 0.3) {
            send = app.buttons.matching(identifier: "terminal-send-button").allElementsBoundByIndex
                .last(where: { $0.isHittable && $0.isEnabled })
            return send != nil
        }, "the reply should be sendable")
        send?.tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the chat should show \"\(text)\"")
    }

    func testCardAppearsAtFivePromptsAndNotNowRetiresIt() {
        let app = launch("1")
        openHerdrApp(app)
        XCTAssertFalse(card(app).exists, "a fresh install shows no card")
        for n in 1...4 {
            sendPrompt("Star prompt check \(n)", in: app)
            XCTAssertFalse(card(app).exists, "no card after \(n) prompts")
        }
        sendPrompt("Star prompt check 5", in: app)
        XCTAssertTrue(card(app).waitForExistence(timeout: 5), "the fifth prompt shows the card")
        XCTAssertTrue(app.buttons["github-star-card-star"].exists)
        attach(app, "github-star-card")

        app.buttons["github-star-card-not-now"].tap()
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 5), "Not now removes the card")
        sendPrompt("Star prompt check 6", in: app)
        XCTAssertFalse(card(app).exists, "another prompt does not bring it back")
        app.terminate()

        let again = launch("keep")
        openHerdrApp(again)
        sendPrompt("Star prompt check 7", in: again)
        XCTAssertFalse(card(again).exists, "the answer survives a relaunch")
        again.terminate()
    }
}
