import UIKit
import XCTest

/// The one-time GitHub star bar (`GitHubStarPrompt`) on the owner's agents home, over the
/// `chatview` mock with `HERDR_MOCK_STAR_PROMPT` (every other mock run keeps it hidden): it
/// appears after the fifth owner prompt, × ("Not now") removes it, and a relaunch does not
/// bring it back.
final class GitHubStarPromptTests: XCTestCase {
    private let pad = UIDevice.current.userInterfaceIdiom == .pad

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

    /// iPhone: the pane covers the home, so go back to it. iPad: the roster is beside the pane.
    private func showHome(_ app: XCUIApplication) {
        guard !pad else { return }
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.staticTexts["herdr-app"].firstMatch.waitForExistence(timeout: 8))
    }

    private func bar(_ app: XCUIApplication) -> XCUIElement {
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

    func testBarAppearsAfterFivePromptsAndNotNowRetiresIt() {
        let app = launch("1")
        XCTAssertTrue(app.staticTexts["herdr-app"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertFalse(bar(app).exists, "a fresh install shows no bar")
        openHerdrApp(app)
        for n in 1...4 {
            sendPrompt("Star prompt check \(n)", in: app)
            XCTAssertFalse(bar(app).exists, "no bar after \(n) prompts")
        }
        sendPrompt("Star prompt check 5", in: app)
        showHome(app)
        XCTAssertTrue(bar(app).waitForExistence(timeout: 5), "the fifth prompt shows the bar on the agents home")
        let star = app.buttons["github-star-card-star"]
        let notNow = app.buttons["github-star-card-not-now"]
        XCTAssertTrue(star.isHittable, "Star should be tappable over the list")
        XCTAssertEqual(star.label, "Star on GitHub")
        XCTAssertEqual(notNow.label, "Not now")
        attach(app, "github-star-bar")

        notNow.tap()
        XCTAssertTrue(bar(app).waitForNonExistence(timeout: 5), "Not now removes the bar")
        app.terminate()

        let again = launch("keep")
        XCTAssertTrue(again.staticTexts["herdr-app"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertFalse(bar(again).exists, "the answer survives a relaunch")
        openHerdrApp(again)
        sendPrompt("Star prompt check 6", in: again)
        showHome(again)
        XCTAssertFalse(bar(again).exists, "another prompt does not bring it back")
        again.terminate()
    }
}
