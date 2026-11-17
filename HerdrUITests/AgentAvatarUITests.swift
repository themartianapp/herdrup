import XCTest

/// herdrup#538: agent pictures. The demo roster (MockWireFixtures.agentList) gives
/// clientloop the Tri mascot and discovery a photo; everyone else wears the default: its
/// initial on its name's gradient (`AgentInitialTile`, accessibility label "Initial <letter>").
/// `HERDR_MOCK_AVATARS` makes the mock daemon advertise `agent_avatar` and keeps choices in
/// a store that survives relaunch, like the server's `agent-avatars/index.json`.
final class AgentAvatarUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func avatar(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-avatar-\(id)").firstMatch
    }

    /// The avatar `bubble` wears, as its `agent-avatar-` suffix ("none" when there is none).
    /// A sender's run of bubbles shares one avatar, drawn in the left gutter beside the
    /// run's LAST bubble, so the bubble's avatar is the first gutter avatar at or below the
    /// bubble's bottom. The Agents list and Gram's header stack sit elsewhere and can't stand
    /// in for it. Polls until it reads `expected` or `timeout` passes.
    private func avatar(worn bubble: XCUIElement, expecting expected: String, in app: XCUIApplication,
                        timeout: TimeInterval = 10) -> String {
        let avatars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "agent-avatar-"))
        let deadline = Date().addingTimeInterval(timeout)
        var seen = "none"
        repeat {
            let frame = bubble.frame
            let gutter = avatars.allElementsBoundByIndex
                .map { (id: $0.identifier, frame: $0.frame) }
                .filter { $0.frame.maxX <= frame.minX + 1 && $0.frame.maxY >= frame.maxY - 4 }
                .min { $0.frame.maxY < $1.frame.maxY }
            seen = gutter.map { String($0.id.dropFirst("agent-avatar-".count)) } ?? "none"
            if seen == expected { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return seen
    }

    /// The row shows `mascot`, whose accessibility label contains `named` (the mascot's
    /// display name by default): by an avatar with that identifier and label inside the row,
    /// or, where the row's button merges its children into one element, by the row's label.
    private func row(_ row: XCUIElement, shows mascot: String, named: String? = nil, in app: XCUIApplication,
                     timeout: TimeInterval = 10) -> Bool {
        let named = named ?? mascot.capitalized
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists, row.label.contains(named) { return true }
            if row.exists {
                let frame = row.frame
                let inside = app.descendants(matching: .any).matching(identifier: "agent-avatar-\(mascot)")
                    .allElementsBoundByIndex
                    .contains { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.label.contains(named) }
                if inside { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    func testAnAgentWithoutAChoiceShowsItsInitialTile() {
        let app = XCUIApplication.launched(mock: "list")
        let jarvis = app.descendants(matching: .any)["agent-row-w1:p1"]
        XCTAssertTrue(jarvis.exists(within: 10))
        XCTAssertTrue(row(jarvis, shows: "initial", named: "Initial J", in: app),
                      "an agent with no avatar shows its initial tile, got \(jarvis.label)")
        XCTAssertFalse(jarvis.label.contains("Herdy"), "Herdy is a mascot to pick, not the default")
        XCTAssertFalse(jarvis.label.contains("Bot"))
        // An older mock daemon (no agent_avatar) offers no Avatar… entry.
        jarvis.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename"].exists(within: 5))
        XCTAssertFalse(app.buttons["Avatar…"].exists, "the menu must hide Avatar… without server support")
    }

    func testChoosingBotChangesTheRowPersistsAndShowsInGram() {
        var app = XCUIApplication.launched(mock: "list", environment: ["HERDR_MOCK_AVATARS": "reset"])
        var vetrina = app.descendants(matching: .any)["agent-row-w1:p2"]
        XCTAssertTrue(vetrina.exists(within: 10))
        XCTAssertTrue(row(vetrina, shows: "initial", named: "Initial V", in: app), "vetrina starts on the default")

        // Long-press → Avatar… → Bot. The capability probe lands with the first load.
        var opened = false
        for _ in 0..<5 where !opened {
            vetrina.press(forDuration: 1.0)
            let item = app.buttons["Avatar…"]
            if item.exists(within: 3) {
                item.tap()
                opened = true
            } else {
                app.tap()   // dismiss the menu and retry once the probe has answered
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTAssertTrue(opened, "the owner's row menu should offer Avatar…")
        XCTAssertTrue(app.staticTexts["Guests you share this agent with will see this picture."].exists(within: 5))
        // The default option previews vetrina's own initial tile, and is the current choice.
        let useDefault = app.descendants(matching: .any)["agent-avatar-use-default"]
        XCTAssertTrue(useDefault.exists(within: 5), "the sheet should offer the default")
        XCTAssertTrue(useDefault.label.contains("Initial V"), "the default previews vetrina's initial, got \(useDefault.label)")
        XCTAssertTrue(useDefault.isSelected, "an agent with no choice is on the default")
        let bot = app.descendants(matching: .any)["agent-avatar-choice-bot"]
        XCTAssertTrue(bot.exists(within: 5))
        bot.tap()
        XCTAssertTrue(avatar(app, "bot").exists(within: 5), "the sheet's preview should show Bot")
        app.buttons["agent-avatar-done"].tap()
        XCTAssertTrue(row(vetrina, shows: "bot", in: app), "the row should show Bot, got \(vetrina.label)")

        // Relaunch: the mock daemon kept the choice, as the server does.
        app.terminate()
        app = XCUIApplication.launched(mock: "list", environment: ["HERDR_MOCK_AVATARS": "keep"])
        vetrina = app.descendants(matching: .any)["agent-row-w1:p2"]
        XCTAssertTrue(vetrina.exists(within: 10))
        XCTAssertTrue(row(vetrina, shows: "bot", in: app), "Bot should survive a relaunch, got \(vetrina.label)")
        attach(app, "agent-avatars-list")

        // Gram is name-keyed: vetrina's bubbles wear the same mascot.
        let gram = app.buttons["Gram"].firstMatch
        XCTAssertTrue(gram.exists(within: 10))
        gram.tap()
        // g1 is the owner's reply; g3 is vetrina's newest message (MockWireFixtures.gramList).
        let fromVetrina = app.descendants(matching: .any)["gram-bubble-g3"]
        XCTAssertTrue(fromVetrina.exists(within: 10))
        XCTAssertEqual(avatar(worn: fromVetrina, expecting: "bot", in: app), "bot",
                       "a Gram bubble from vetrina should show Bot")
        // hetzner-1's clientloop is not the local clientloop (Tri): the roster has no agent of
        // that name on that machine, so its bubble wears the default.
        let relayed = app.descendants(matching: .any)["gram-bubble-g2"]
        XCTAssertTrue(relayed.exists(within: 5))
        XCTAssertEqual(avatar(worn: relayed, expecting: "initial", in: app), "initial",
                       "a relayed sender with no roster entry shows its initial tile")
        attach(app, "agent-avatars-gram")
    }

    func testAGuestSeesTheOwnersMascotAndCannotEditIt() {
        let app = XCUIApplication.launched(mock: "guest")
        let shared = app.buttons["guest-agent-row"]
        XCTAssertTrue(shared.exists(within: 10))
        XCTAssertTrue(row(shared, shows: "pip", in: app), "the guest should see the owner's Pip, got \(shared.label)")

        shared.tap()
        // The guest pane's ⋯ (GuestPaneView), not the owner's `terminal-actions`.
        let actions = app.buttons["guest-actions"]
        XCTAssertTrue(actions.exists(within: 10), "the guest pane should offer ⋯")
        actions.tap()
        // The menu is open once one of its known entries shows; only then does the missing
        // Avatar… entry mean anything. Increase by its label too: on iOS 27 it loses its
        // identifier inside the Text size section (`menuEntry`).
        let entries = app.buttons.matching(NSPredicate(format: "identifier IN %@ OR label == %@",
                                                       ["guest-font-increase", "guest-notifications"], "Increase"))
        XCTAssertTrue(entries.firstMatch.exists(within: 5), "the guest ⋯ menu should open")
        XCTAssertFalse(app.buttons["agent-avatar-edit"].exists, "guests have no Avatar… entry")
        XCTAssertFalse(app.buttons["Avatar…"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["guest-forbidden-calls"].label, "",
                       "a guest never calls agent.avatar.set")
    }
}
