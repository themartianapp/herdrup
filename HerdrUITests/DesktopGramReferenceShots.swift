import XCTest

/// Saved request370540, through the real Gram sidebar, feed, context menu and composer.
/// The common reference launch/capture contract runs these on both iPads.
/// These are fixture references, not acceptance evidence against a live daemon.
final class DesktopGramReferenceShots: DesktopReferenceCaptureCase {
    private static let gramFixtureSHA256 = "3f0016bce323ab24077c96dfe7c1617c82f719e992d9a94a1154bbb41f8476c0"
    private static let gramEmptySHA256 = "ec27d30e0ffb939c6c580c00228fd1070294832d95b848915b237655c0298273"
    private static let gramLoadingSHA256 = "5413bea616d646ff4181e73aaa545c7ac782066a18959c8354e1cb7f35499018"

    func testGramMixedLatestReference() throws {
        let (app, device) = try launchGramReference()
        let owner = gramElement(app, "gram-bubble-gr-owner")
        XCTAssertTrue(owner.waitForHittable(timeout: 10))
        // The entry rule counts unread messages; "New messages" is the separate
        // arrival button shown only when a new message arrives while reading history.
        let unread = app.staticTexts["1 unread"]
        XCTAssertTrue(unread.waitForHittable(timeout: 10),
                      "the one initially unread message leaves the visible entry unread rule")
        let file = gramElement(app, "gram-bubble-gr-file")
            .buttons["gram-attachment-open"].firstMatch
        XCTAssertTrue(file.waitForHittable(timeout: 10))
        XCTAssertTrue(file.label.contains("reference-handoff.txt"))
        XCTAssertTrue(app.staticTexts["Great, ship it."].exists)
        capture(app, device: device, state: "gram-mixed-latest")
    }

    func testGramMixedImageReference() throws {
        let (app, device) = try launchGramReference()
        let card = gramElement(app, "gram-bubble-gr-image")
            .buttons["gram-attachment-open"].firstMatch
        revealOlderGramReference(card, in: app)
        let preview = gramElement(app, "gram-image-preview-gr-image")
        gramWait(preview, "label == %@", "preview")
        XCTAssertTrue(card.label.contains("reference-landscape.png"))
        capture(app, device: device, state: "gram-mixed-image")
    }

    func testGramMixedFoldedReference() throws {
        let (app, device) = try launchGramReference()
        let folded = gramElement(app, "gram-bubble-gr-long")
        revealOlderGramReference(folded, in: app)
        XCTAssertTrue(folded.buttons["Read more"].waitForHittable(timeout: 10),
                      "the eleven-line report stays folded at eight lines")
        XCTAssertFalse(folded.buttons["Show less"].exists)
        capture(app, device: device, state: "gram-mixed-folded")
    }

    func testGramMixedCodeReference() throws {
        let (app, device) = try launchGramReference()
        let code = gramElement(app, "gram-bubble-gr-code")
        revealOlderGramReference(code, in: app)
        XCTAssertTrue(code.buttons["gram-code-copy"].waitForHittable(timeout: 10),
                      "the real multiline code card includes Copy")
        capture(app, device: device, state: "gram-mixed-code")
    }

    func testGramSavedReference() throws {
        let (app, device) = try launchGramReference()
        // Saved is local, not a daemon method. Reach it by saving real inbox messages.
        for id in ["gr-owner", "gr-file"] {
            let bubble = gramElement(app, "gram-bubble-\(id)")
            XCTAssertTrue(bubble.waitForHittable(timeout: 10))
            bubble.press(forDuration: 1.2)
            let save = app.buttons["Save"].firstMatch
            XCTAssertTrue(save.waitForHittable(timeout: 5))
            save.tap()
            XCTAssertTrue(bubble.descendants(matching: .any)["gram-saved-badge"].exists(within: 5))
        }
        let saved = app.buttons["gram-saved-toggle"]
        XCTAssertTrue(saved.waitForHittable(timeout: 5))
        saved.tap()
        XCTAssertTrue(app.scrollViews["gram-saved-feed"].exists(within: 10))
        XCTAssertTrue(gramElement(app, "gram-saved-gr-owner").waitForHittable(timeout: 10))
        XCTAssertTrue(gramElement(app, "gram-saved-gr-file").waitForHittable(timeout: 10))
        capture(app, device: device, state: "gram-saved")
    }

    func testGramSearchResultsReference() throws {
        let (app, device) = try launchGramReference()
        searchGramReference(app, for: "handoff")
        XCTAssertTrue(gramElement(app, "gram-bubble-gr-file").waitForHittable(timeout: 10))
        XCTAssertTrue(gramElement(app, "gram-bubble-gr-owner").gone(within: 5))
        XCTAssertFalse(app.staticTexts["No matches"].exists)
        capture(app, device: device, state: "gram-search-results")
    }

    func testGramSearchEmptyReference() throws {
        let (app, device) = try launchGramReference()
        searchGramReference(app, for: "no-such-reference")
        XCTAssertTrue(app.staticTexts["No matches"].exists(within: 10))
        XCTAssertTrue(gramElement(app, "gram-bubble-gr-owner").gone(within: 5))
        capture(app, device: device, state: "gram-search-empty")
    }

    func testGramComposerAttachmentReference() throws {
        let (app, device) = try launchGramReference(attachment: true)
        attachGramReferenceFile(app)
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForHittable(timeout: 5))
        field.tap()
        field.typeText("@vet")
        let mention = app.buttons["gram-mention-vetrina"]
        XCTAssertTrue(mention.waitForHittable(timeout: 5))
        mention.tap()
        field.typeText("Please review the attached notes.")
        finishGramComposerReference(app)
        XCTAssertTrue(app.buttons["gram-send-button"].isEnabled)
        XCTAssertTrue((field.value as? String ?? "").hasPrefix("@vetrina "))
        capture(app, device: device, state: "gram-composer-attachment")
    }

    func testGramComposerAmbiguousReference() throws {
        let (app, device) = try launchGramReference(attachment: true)
        attachGramReferenceFile(app)
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForHittable(timeout: 5))
        field.tap()
        // Finish the mention without choosing either identity. With the caret in the
        // body, the real picker closes and the persistent ambiguity reason is visible.
        field.typeText("@clientloop Please review the attachment.")
        finishGramComposerReference(app)
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.exists(within: 5))
        XCTAssertFalse(send.isEnabled)
        let hint = gramElement(app, "gram-composer-hint")
        XCTAssertTrue(hint.exists(within: 5))
        XCTAssertTrue(hint.label.contains("Several agents are called clientloop: pick one"))
        capture(app, device: device, state: "gram-composer-ambiguous")
    }

    func testGramEmptyReference() throws {
        let (app, device) = try launch("gram", served: "gram-empty", sha256: Self.gramEmptySHA256)
        openGramReference(app)
        XCTAssertTrue(app.staticTexts["No messages yet"].exists(within: 10))
        XCTAssertFalse(app.staticTexts["No matches"].exists)
        capture(app, device: device, state: "gram-empty")
    }

    func testGramLoadingReference() throws {
        let (app, device) = try launch("gram-loading", served: "gram-loading", sha256: Self.gramLoadingSHA256)
        openGramReference(app)
        XCTAssertTrue(app.activityIndicators.firstMatch.exists(within: 10))
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
        XCTAssertFalse(app.scrollViews["gram-feed"].exists)
        capture(app, device: device, state: "gram-loading")
    }

    private func launchGramReference(attachment: Bool = false) throws -> (XCUIApplication, String) {
        let (app, device) = try launch(
            "gram", served: "gram", sha256: Self.gramFixtureSHA256,
            environment: attachment ? ["HERDR_MOCK_PICKED_FILE": "1"] : [:]
        )
        openGramReference(app)
        XCTAssertTrue(app.scrollViews["gram-feed"].exists(within: 15))
        XCTAssertTrue(gramElement(app, "gram-bubble-gr-owner").waitForHittable(timeout: 10))
        return (app, device)
    }

    private func openGramReference(_ app: XCUIApplication) {
        let gram = app.buttons["Gram"].firstMatch
        XCTAssertTrue(gram.waitForHittable(timeout: 15))
        gram.tap()
        XCTAssertTrue(app.textViews["gram-composer-input"].exists(within: 10))
    }

    private func searchGramReference(_ app: XCUIApplication, for query: String) {
        // Production search filters the loaded owner inbox. No gram.search API exists.
        let field = app.textFields["gram-search-field"]
        XCTAssertTrue(field.waitForHittable(timeout: 5))
        field.tap()
        field.typeText(query)
        // Submit the sidebar's ordinary TextField without clearing its filter.
        // A focused caret blink is real UI motion, not a reason to relax PNG stability.
        field.typeText("\n")
        XCTAssertEqual(field.value as? String, query)
        XCTAssertTrue(app.keyboards.firstMatch.gone(within: 5))
    }

    private func finishGramComposerReference(_ app: XCUIApplication) {
        // Use the production dismissal action; keep the draft, mention routing and
        // attachment intact while removing the caret from the captured reference.
        let collapse = app.buttons["Collapse keyboard"]
        XCTAssertTrue(collapse.waitForHittable(timeout: 5))
        collapse.tap()
        XCTAssertTrue(app.keyboards.firstMatch.gone(within: 5))
    }

    private func attachGramReferenceFile(_ app: XCUIApplication) {
        let attach = app.buttons["gram-attach-button"]
        XCTAssertTrue(attach.waitForHittable(timeout: 5))
        attach.tap()
        let files = app.buttons["composer-attach-file"]
        XCTAssertTrue(files.waitForHittable(timeout: 5))
        files.tap()
        let chip = gramElement(app, "gram-attachment")
        XCTAssertTrue(chip.waitForHittable(timeout: 10))
        gramWait(chip, "value == %@", "Uploaded")
        XCTAssertTrue(chip.staticTexts["picked-notes.txt"].exists)
    }

    private func gramElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func gramWait(_ element: XCUIElement, _ format: String, _ expected: String) {
        let predicate = NSPredicate(format: format, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }

    private func revealOlderGramReference(_ element: XCUIElement, in app: XCUIApplication) {
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.exists(within: 10))
        // Small real drags keep a target from jumping straight across the viewport.
        // Keep the whole target clear of the floating header and composer, not merely hittable.
        func visible() -> Bool {
            guard element.exists else { return false }
            let header = gramElement(app, "gram-header-pill")
            let visibleTop = header.exists ? header.frame.maxY : feed.frame.minY
            let frame = element.frame
            // XCTest cannot compute an activation point for a bubble clipped above
            // the viewport. Reveal its complete frame before asking for hittability.
            guard !frame.isEmpty, frame.minY >= visibleTop,
                  frame.maxY <= feed.frame.maxY else { return false }
            return element.isHittable
        }
        for _ in 0..<18 where !visible() {
            let start = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.30))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)))
        }
        XCTAssertTrue(visible(), "the complete reference element must be in the captured viewport")
    }
}
