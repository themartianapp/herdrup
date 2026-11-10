import UIKit
import XCTest

final class ChatUXSmokeTests: XCTestCase {
    private func launch(failingRefresh: Bool = false, pendingQuestion: Bool = false, large: Bool = false,
                        copyFixture: Bool = false, plan: String = "", mermaid: Bool = false, svg: Bool = false,
                        longSession: Bool = false, subagents: Bool = false,
                        environment: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.launched(mock: "chatview", environment: [
            "HERDR_STEADY_CARET": "1", "HERDR_MOCK_STILL": "1", "HERDR_CHAT_UX_SMOKE": "1",
            "HERDR_CHAT_UX_FAIL_REFRESH": failingRefresh ? "1" : "0",
            "HERDR_CHAT_UX_PENDING_QUESTION": pendingQuestion ? "1" : "0",
            "HERDR_CHAT_UX_LARGE": large ? "1" : "0",
            "HERDR_CHAT_UX_COPY": copyFixture ? "1" : "0",
            "HERDR_CHAT_UX_PLAN": plan,
            "HERDR_CHAT_UX_MERMAID": mermaid ? "1" : "0",
            "HERDR_CHAT_UX_SVG": svg ? "1" : "0",
            "HERDR_CHAT_UX_LONG_SESSION": longSession ? "1" : "0",
            "HERDR_CHAT_UX_SUBAGENTS": subagents ? "1" : "0"
        ].merging(environment) { _, new in new })
        let agent = app.staticTexts["herdr-app"].firstMatch
        if !agent.exists {
            let idle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Idle")).firstMatch
            if idle.waitForExistence(timeout: 5) { idle.tap() }
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 12), app.debugDescription)
        agent.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        return app
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func dismissTextSizeMenu(_ app: XCUIApplication) {
        if app.menuEntry("terminal-font-increase", label: "Increase").exists {
            app.descendants(matching: .any)["chat-view"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
        }
    }

    /// The space between the model label, the transcript's last line, and the composer card.
    /// At the tail nothing scrolls under the composer, so no fade-sized spacer pads it.
    private func tailGap(_ app: XCUIApplication) -> CGFloat {
        let composer = app.descendants(matching: .any)["composer-card"].firstMatch
        XCTAssertTrue(composer.exists, app.debugDescription)
        return composer.frame.minY - app.staticTexts["chat-model"].frame.maxY
    }

    private func assertTailGap(_ app: XCUIApplication, _ moment: String) {
        var gap = tailGap(app)
        for _ in 0..<10 where gap > 32 {
            Thread.sleep(forTimeInterval: 0.3)
            gap = tailGap(app)
        }
        XCTAssertGreaterThanOrEqual(gap, 0, "\(moment): the model label must sit above the composer")
        XCTAssertLessThanOrEqual(gap, 32, "\(moment): at most about 20 pt between the model label and the composer")
    }

    func testChatSizeTablesMetadataAndRefresh() {
        let app = launch()
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        let model = app.staticTexts["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(model.label.contains("fixture-model"))
        XCTAssertEqual(model.label, "Model: fixture, fixture-model, effort high",
                       "the model line names omp's effort (fixture-model · high)")
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        XCTAssertTrue(app.staticTexts["Ship after review"].exists)
        // The pause icon marks a blocked item; the long "Blocked · <blocker>" line is gone.
        let blockedText = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Blocked ·", "Independent review")
        XCTAssertEqual(app.descendants(matching: .any).matching(blockedText).count, 0, app.debugDescription)
        record(app, "Native current model, expanded TODO and fixture recap")

        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        let initialHeight = model.frame.height
        for _ in 0..<4 {
            app.buttons["terminal-actions"].tap()
            app.menuEntry("terminal-font-increase", label: "Increase").tap()
            dismissTextSizeMenu(app)
        }
        XCTAssertGreaterThan(model.frame.height, initialHeight)
        record(app, "Chat-only larger text through existing size controls")

        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        app.buttons["Dismiss refresh result"].tap()
        let modelVisible = NSPredicate(format: "hittable == true")
        expectation(for: modelVisible, evaluatedWith: model)
        waitForExpectations(timeout: 5)
        assertTailGap(app, "Following the tail after a refresh")
        record(app, "Tail gap between the model label and the composer")
        record(app, "Manual chat refresh completes without clearing the conversation")

        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        guard let table = app.descendants(matching: .any).matching(identifier: "chat-markdown-table").allElementsBoundByIndex.last else {
            return XCTFail("The fixture table must be rendered: \(app.debugDescription)")
        }
        for _ in 0..<4 where !table.isHittable { chat.swipeDown() }
        XCTAssertTrue(table.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(table.frame.maxX, chat.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(table.frame.minX, chat.frame.minX - 1)
        let description = app.staticTexts["A deliberately long description that must wrap within its column"].firstMatch
        XCTAssertGreaterThan(description.frame.height, 30)
        record(app, "Three-column table wraps within the phone width")
    }

    func testPlanCardCollapsesToTheCurrentWork() {
        let app = launch(plan: "six")
        let toggle = app.buttons["chat-plan-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(toggle.label, "To-do, 2 of 6 done")
        let rows = ["one", "two", "three", "four", "five", "six"].map { app.staticTexts["Plan item \($0)"] }
        XCTAssertEqual(rows.map(\.exists), [false, false, true, true, true, false],
                       "collapsed shows the in-progress item and the next two: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Build"].exists)
        XCTAssertTrue(app.staticTexts["Ship"].exists)
        let more = app.buttons["chat-plan-more"]
        XCTAssertTrue(more.exists, app.debugDescription)
        XCTAssertEqual(more.label, "+3 more")
        record(app, "Collapsed TODO shows the current work and +3 more")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.map(\.exists), Array(repeating: true, count: 6))
        XCTAssertFalse(more.exists, "expanded, nothing is hidden")
        record(app, "Expanded TODO shows every item")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(more.exists)
        more.tap()
        XCTAssertTrue(rows[5].waitForExistence(timeout: 5), "+3 more expands too: \(app.debugDescription)")
        XCTAssertEqual(rows.map(\.exists), Array(repeating: true, count: 6))
    }

    /// Round 3 item 1: omp's `task` subagents show under the plan like the terminal's
    /// Subagents box: running ones as rows, finished ones folded; a row opens that
    /// subagent's own conversation, read-only.
    func testSubagentsCardShowsRunningRowsAndOpensASubagentTranscript() {
        let app = launch(subagents: true)
        let toggle = app.buttons["chat-subagents-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(toggle.label, "Subagents, 2 running")
        let rows = app.descendants(matching: .any).matching(identifier: "chat-subagent-row")
        XCTAssertEqual(rows.count, 2, "finished subagents start folded: \(app.debugDescription)")
        XCTAssertTrue(rows.element(boundBy: 0).label.hasPrefix("DaemonHeadReview, Review the daemon head, running"),
                      rows.element(boundBy: 0).label)
        XCTAssertTrue(rows.element(boundBy: 1).label.hasPrefix("AppHeadReview, Review the app head, running"),
                      rows.element(boundBy: 1).label)
        let finished = app.buttons["chat-subagents-finished"]
        XCTAssertTrue(finished.exists, app.debugDescription)
        XCTAssertEqual(finished.label, "1 finished")
        record(app, "Subagents card: two running, one finished folded")

        finished.tap()
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(rows.element(boundBy: 2).label, "MermaidRender, Render the diagram, completed, 5 min")
        finished.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)

        toggle.tap()
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        toggle.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)

        rows.element(boundBy: 1).tap()
        let conversation = app.staticTexts["AppHeadReview fixture conversation."]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-subagent-done"].exists)
        record(app, "A subagent's own conversation, read-only")
        app.buttons["chat-subagent-done"].tap()
        XCTAssertTrue(conversation.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toggle.exists)
    }

    func testFinishedPlanShowsOnlyItsHeader() {
        let app = launch(plan: "done")
        let toggle = app.buttons["chat-plan-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(toggle.label, "To-do, 3 of 3 done")
        XCTAssertEqual(toggle.value as? String, "All done")
        let rows = ["one", "two", "three"].map { app.staticTexts["Plan item \($0)"] }
        XCTAssertEqual(rows.map(\.exists), [false, false, false], "a finished plan collapses to its header")
        XCTAssertFalse(app.buttons["chat-plan-more"].exists)
        record(app, "Finished TODO collapses to its header")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.map(\.exists), [true, true, true])
    }

    /// Waits until the renderer has settled `tag`'s first block (`chat-mermaid` or `chat-svg`):
    /// its placeholder gone, an image or the code fallback in its place. A fresh launch builds
    /// the renderer's page (the 3.6 MB mermaid bundle in a new WebContent process) before the
    /// first draw, and the renderer itself allows that page 30 s and the first draw 20 s
    /// (`MermaidRenderer.pageTimeout`, `firstRenderTimeout`). A fixed 30 s wait gave up while
    /// the placeholder was still spinning on loaded hosted simulators (run 41441790156 job
    /// 125265193229 at 32 s, run 41354286757 job 124990913337 at 31 s); 7 to 20 s is usual.
    /// So wait for the renderer's own outcome, bounded by its own limits, then the caller
    /// asserts which outcome it was. Identifier queries keep each poll cheap for the app.
    private func waitForDiagramToSettle(_ app: XCUIApplication, _ tag: String) {
        let block = app.descendants(matching: .any).matching(identifier: tag).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 12), app.debugDescription)
        let placeholder = app.descendants(matching: .any).matching(identifier: "\(tag)-placeholder").firstMatch
        _ = placeholder.waitForNonExistence(timeout: 30 + 20 + 5)
    }

    /// #523 item 1: a closed ```mermaid fence is drawn as a diagram (not its code), rasterised
    /// sharp for this screen; tapping it opens the zoomable viewer, "Show code" swaps in the
    /// source, search still finds words that are only in the diagram source, and after a
    /// relaunch the diagram comes back from the disk cache at the same size.
    func testMermaidReplyRendersADiagramThatOpensTheViewer() {
        let app = launch(mermaid: true, environment: ["HERDR_CHAT_UX_STATIC": "1"])
        waitForDiagramToSettle(app, "chat-mermaid")
        let image = app.buttons["chat-mermaid-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5),
                      "The diagram must finish rendering offscreen: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["chat-mermaid-error"].exists, "The fixture diagram is valid mermaid")
        XCTAssertGreaterThan(image.frame.width, 40, "\(image.frame)")
        XCTAssertGreaterThan(image.frame.height, 40, "\(image.frame)")
        XCTAssertTrue(image.label.hasPrefix("Mermaid diagram, graph TD"), image.label)
        // The image's DEBUG value: "drawn|blank <raster scale>x fresh|disk".
        let screenScale = Self.screenScale(app)
        let drawn = "drawn \(screenScale)x "
        XCTAssertTrue((image.value as? String ?? "").hasPrefix(drawn),
                      "The raster must hold a drawing at the screen's scale (\(drawn)): \(String(describing: image.value))")
        let shownSize = image.frame.size
        let code = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "D[Render offscreen]")).firstMatch
        XCTAssertFalse(code.exists, "The diagram source must not be drawn as code")
        record(app, "Mermaid reply drawn as a diagram")

        image.tap()
        let viewer = app.descendants(matching: .any)["chat-mermaid-viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(viewer.frame.height, 100, "\(viewer.frame)")
        record(app, "Mermaid viewer full screen")
        app.buttons["chat-mermaid-viewer-done"].tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10))

        // The chat follows its tail, so the block's header can sit under the top bar: bring
        // it into view the way a reader would.
        let toggle = app.buttons["chat-mermaid-toggle"]
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        for _ in 0..<4 where !toggle.isHittable {
            chat.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(toggle.isHittable, "\(toggle.frame)")
        toggle.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["chat-mermaid-image"].exists)
        toggle.tap()
        XCTAssertTrue(app.buttons["chat-mermaid-image"].waitForExistence(timeout: 5))

        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Render offscreen")
        expectation(for: NSPredicate(format: "label == %@", "1/1"), evaluatedWith: app.staticTexts["terminal-find-count"])
        waitForExpectations(timeout: 5)

        // A relaunch draws nothing: the diagram comes back from the disk cache, at the size
        // it was shown at and still at the screen's scale.
        app.terminate()
        let relaunched = launch(mermaid: true, environment: ["HERDR_CHAT_UX_STATIC": "1"])
        let cachedImage = relaunched.buttons["chat-mermaid-image"].firstMatch
        XCTAssertTrue(cachedImage.waitForExistence(timeout: 30), relaunched.debugDescription)
        XCTAssertEqual(cachedImage.value as? String, drawn + "disk")
        XCTAssertEqual(cachedImage.frame.width, shownSize.width, accuracy: 0.5)
        XCTAssertEqual(cachedImage.frame.height, shownSize.height, accuracy: 0.5)
        record(relaunched, "Mermaid diagram from the disk cache after relaunch")
    }

    /// The owner's ```svg block (round 4) is drawn as an image in the app's colours, opens full
    /// screen, and shows its code on request; a broken SVG stays a code block.
    func testSVGReplyRendersAnImageAndABrokenOneStaysCode() {
        // Presentation only, so the fixture is held (`HERDR_CHAT_UX_STATIC`, as the Mermaid
        // test). Its second transcript poll lands about 33 s after the chat opens and appends
        // two replies; the chat follows its tail, so the reply moves up under a tap already
        // aimed. On run 42755948429 (job 129630244571) it landed 0.2 s before the "Show code"
        // tap: the tap hit the image, the viewer opened, and the source never showed. The
        // viewer's web view exposes the SVG's own text ("Clinic system (cloud)" in that run's
        // hierarchy), so the same misdirected tap can also pass the source wait and fail the
        // image check after it instead (bare "XCTAssertFalse failed", iPad run 41354286757).
        let app = launch(svg: true, environment: ["HERDR_CHAT_UX_STATIC": "1"])
        waitForDiagramToSettle(app, "chat-svg")
        let image = app.buttons["chat-svg-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5),
                      "The SVG must finish rendering offscreen: \(app.debugDescription)")
        XCTAssertGreaterThan(image.frame.width, 100, "\(image.frame)")
        // 900 × 360 drawn to the column: the aspect is the SVG's own.
        XCTAssertEqual(image.frame.width / image.frame.height, 2.5, accuracy: 0.05, "\(image.frame)")
        XCTAssertTrue((image.value as? String ?? "").hasPrefix("drawn "), String(describing: image.value))
        XCTAssertEqual(app.buttons.matching(identifier: "chat-svg-image").count, 1,
                       "Only the well-formed SVG is drawn")
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Clinic system (cloud)")).firstMatch
        XCTAssertFalse(source.exists, "The SVG's source must not be drawn as code")

        let broken = app.staticTexts["chat-svg-error"]
        XCTAssertTrue(broken.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<rect width=\"4\">")).firstMatch.exists,
                      "A malformed SVG falls back to its code")

        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        for _ in 0..<4 where !image.isHittable {
            chat.swipeDown(velocity: .slow)
        }
        record(app, "SVG reply drawn as an image")
        image.tap()
        let viewer = app.descendants(matching: .any)["chat-svg-viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), app.debugDescription)
        record(app, "SVG viewer full screen")
        app.buttons["chat-svg-viewer-done"].tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10))

        let toggle = app.buttons["chat-svg-toggle"].firstMatch
        for _ in 0..<4 where !toggle.isHittable {
            chat.swipeDown(velocity: .slow)
        }
        toggle.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5), "Show code reveals the SVG's source")
        XCTAssertFalse(app.buttons["chat-svg-image"].exists)
    }

    /// An expanded thought reads as an aside (round 4): its text, list items and inline code in
    /// the secondary ink, a step smaller than the reply. Measured on the screen's pixels: the
    /// brightest pixel of a thought line is the secondary ink, a reply line's is the primary.
    func testExpandedThoughtIsDimmerAndSmallerThanTheReply() {
        // Presentation only, so the fixture is held (`HERDR_CHAT_UX_STATIC`): its second
        // transcript poll lands about 33 s after the chat opens and appends two replies, and
        // while the chat follows its tail that moves every line up between a frame read and
        // the screenshot (iPad run 41642629325 job 126092602640: chat open at 17.6 s, the
        // line read as bare background, 0.068, at 50.6 s).
        let app = launch(environment: ["HERDR_CHAT_UX_STATIC": "1"])
        let header = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                      "chat-thought", "Check the table")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        // The reply line, measured while the chat sits at its tail (it is on screen there),
        // before the thought opens above it and pushes it down under the composer.
        let reply = app.staticTexts["A complete fixture response."].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<4 where !reply.isHittable {
            chat.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(reply.isHittable, "\(reply.frame)")
        let replyInk = Self.brightest(reply.frame, in: XCUIScreen.main.screenshot().image, app: app)
        let replyHeight = reply.frame.height
        XCTAssertGreaterThan(replyInk, 0.85, "A reply line is drawn in the primary ink")

        for _ in 0..<4 where !header.isHittable {
            chat.swipeDown(velocity: .slow)
        }
        header.tap()
        let open = app.descendants(matching: .any)["chat-thought-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)

        let lead = app.staticTexts["Check the table"].firstMatch
        let paragraph = app.staticTexts["Use wrapped cells and literal code."].firstMatch
        let item = app.staticTexts["Preserve Unicode: café"].firstMatch
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Find literal")).firstMatch
        for element in [lead, paragraph, item, code] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        }
        // The chat's top edge fades content out under the bar (26 pt), the composer card
        // covers its bottom, and the jump-to-latest button floats just above the composer.
        // The top is the chat's own, or the Chat/Terminal switch's bottom if lower; the bottom
        // is the composer card's top, or the top of a floating button while it shows: the
        // jump button (its white arrow over a line read as 0.948 white on CI, #631 run
        // 42035642472) and the up arrow (it sat over "Use wrapped cells and literal code."
        // when it was centred in the column, 0.948 on runs 42364233460 and 42369140769).
        let mode = app.buttons["Terminal"].firstMatch
        let top = max(chat.frame.minY, mode.exists ? mode.frame.maxY : 0)
        let composer = app.descendants(matching: .any)["composer-card"].firstMatch
        let floating = [app.buttons["chat-jump-latest"].firstMatch, app.buttons["chat-jump-previous-mine"].firstMatch]
        func bottom() -> CGFloat {
            let card = composer.exists ? composer.frame.minY : chat.frame.maxY
            return floating.filter(\.exists).reduce(card) { min($0, $1.frame.minY - 8) }
        }
        record(app, "Expanded thought box")

        // Bring each line into the clear band on its own with one exact drag (no fling), then
        // measure it. The whole box (about 575 pt) does not always fit between the top fade and
        // the composer on an iPhone, so requiring all four lines on screen at once failed with
        // the last lines under the composer (y 771 and 788 on CI for #630 and an earlier run).
        // Each line is then read from a fresh screenshot and frame until the reading lands in
        // the secondary-ink band, for up to 5 s: one early screenshot could catch the box still
        // opening or the drag still settling and read the bare background (0.068 on CI for
        // #593, #594, #602, #613 and #614). A line that stays white, or stays too dim to read,
        // still fails with its last reading.
        for (name, element) in [("bold lead", lead), ("text", paragraph), ("list item", item), ("inline code", code)] {
            let target = (top + 40 + bottom()) / 2
            let offset = target - element.frame.midY
            if element.frame.minY < top + 40 || element.frame.maxY > bottom() {
                // A short touch, then a hold at the end: the drag moves the chat exactly
                // `offset` with no fling after it. A 0.2 s press first let the long-press menu
                // of the reply under the finger begin (run 42632930170 job 129213557250: the
                // reply drew lifted, the chat never moved, the lead stayed at y 135.3), and
                // letting go mid-drag flung the chat ~150 pt past the target (run 42364233460).
                let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)),
                            withVelocity: .default, thenHoldForDuration: 0.3)
            }
            XCTAssertTrue(poll(3, every: 0.2) {
                element.isHittable && element.frame.minY >= top + 40 && element.frame.maxY <= bottom()
            }, "The thought's \(name) must be on screen, clear of the top fade, the jump button and the composer: \(element.frame), clear band \(top + 40)…\(bottom())")
            var value = 0.0
            _ = poll(5, every: 0.25) {
                value = Self.brightest(element.frame, in: XCUIScreen.main.screenshot().image, app: app)
                return value > 0.5 && value < 0.75
            }
            XCTAssertLessThan(value, 0.75, "A thought's \(name) must be in the secondary ink, not white (\(value))")
            XCTAssertGreaterThan(value, 0.5, "A thought's \(name) must stay readable (\(value))")
        }
        XCTAssertLessThan(item.frame.height, replyHeight,
                          "A thought line is a type step smaller than a reply line")
    }

    /// The brightest pixel inside `frame` (points), as the mean of its RGB in 0…1.
    private static func brightest(_ frame: CGRect, in shot: UIImage, app: XCUIApplication) -> Double {
        guard let image = shot.cgImage else { return 0 }
        let scale = CGFloat(image.width) / max(app.frame.width, 1)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return 0 }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return 0 }
        var best = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            best = max(best, Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]))
        }
        return Double(best) / (3 * 255)
    }

    /// Pixels per point of this device's screen, from a screenshot of it.
    private static func screenScale(_ app: XCUIApplication) -> Int {
        let shot = XCUIScreen.main.screenshot().image
        let pixels = max(shot.size.width * shot.scale, shot.size.height * shot.scale)
        let points = max(app.frame.width, app.frame.height)
        return Int((pixels / max(points, 1)).rounded())
    }

    func testSearchRevealsThoughtAndKeepsActiveChat() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(".*[x]")
        let result = app.staticTexts["chat-search-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(result.label.contains(".*[x]"))
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.exists)
        XCTAssertTrue(app.otherElements["chat-thought-open"].exists || app.descendants(matching: .any)["chat-thought-open"].exists)
        record(app, "Literal punctuation search reveals rendered thought without switching to Terminal")
        app.buttons["terminal-find"].tap()
        XCTAssertFalse(app.staticTexts["chat-search-result"].exists)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        chat.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["chat-jump-latest"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["chat-jump-latest"].tap()
        XCTAssertTrue(app.staticTexts["chat-model"].waitForExistence(timeout: 5), app.debugDescription)
        record(app, "Tail position immediately after jumping")
        let modelVisible = NSPredicate(format: "hittable == true")
        expectation(for: modelVisible, evaluatedWith: app.staticTexts["chat-model"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["chat-jump-latest"].exists, "The control must disappear at the measured tail")
        assertTailGap(app, "After the animated jump")
        record(app, "Centered clear-glass jump returns to latest without a composer fade")

        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Incoming café update after refresh."].isHittable)
        XCTAssertTrue(app.staticTexts["chat-model"].isHittable, "New content must retain the tail while following")

        app.textViews["terminal-reply-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        expectation(for: modelVisible, evaluatedWith: app.staticTexts["chat-model"])
        waitForExpectations(timeout: 5)
        record(app, "Following latest keeps the final line above the keyboard and composer")

        chat.swipeDown(velocity: .fast)
        XCTAssertFalse(app.staticTexts["chat-model"].isHittable, "The drag must move into history before refreshing")
        let incoming = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Incoming update ")).firstMatch
        let previousUpdate = incoming.label
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertNotEqual(incoming.label, previousUpdate, "The refresh must deliver changed reply content before checking reader position")
        XCTAssertFalse(app.staticTexts["chat-model"].isHittable, "An incoming reply must not pull the reader out of history")
        XCTAssertTrue(app.buttons["chat-jump-latest"].isHittable)
        record(app, "Incoming content preserves manual history position")
    }

    func testUnicodeSearchNavigationSurvivesRefresh() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("café")
        let count = app.staticTexts["terminal-find-count"]
        expectation(for: NSPredicate(format: "label == %@", "1/2"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        app.buttons["terminal-find-next"].tap()
        XCTAssertEqual(count.label, "2/2")
        app.buttons["terminal-find-next"].tap()
        XCTAssertEqual(count.label, "1/2")
        app.buttons["terminal-find-previous"].tap()
        XCTAssertEqual(count.label, "2/2")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(count.label, "2/3", "The new reply must add one match without moving the selected table match")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "2/3", "A no-change refresh must not duplicate the incoming reply")
        record(app, "Unicode search counts an incoming reply and preserves selection through a no-change refresh")
        app.buttons["terminal-find"].tap()
        XCTAssertFalse(app.staticTexts["chat-search-result"].exists)
    }

    /// Waits for the search counter to read `label`, failing with the last label read.
    ///
    /// NOT `expectation(for:evaluatedWith:)`. On a loaded runner one accessibility snapshot of
    /// the chat takes seconds; that expectation follows every failed check with an element
    /// debug description (three more snapshots) and drops the read still in flight at its
    /// deadline, so the counter was judged once or twice per window while it already matched:
    /// - run 41432810441 (job 125235298176, iPhone, testSearchPaging…): after Load older
    ///   (event at t = 31.45 s) the screen recording shows "21/23" from 34.5 s to the end (the
    ///   mock answers every transcript request after the first in 3 s, `ChatUXSmoke.reply`); the
    ///   failed check at 33.02 s was followed by an 8.6 s debug description, whose own query
    ///   already returned "21/23", and the second check (41.99 s) was in flight at the deadline.
    /// - run 41402649405 (job 125137622424, iPad, testSearchPaging…): one check in 10 s
    ///   (41.55 s); the debug description it triggered, still running at the deadline, lists
    ///   "21/23".
    /// - run 41402663682 (job 125137668689, iPad, testOneLetterSearch…): after Previous (event
    ///   at 46.05 s) the recording shows "1/500+" from 46.5 s; the only check started at
    ///   47.72 s and had not returned when the 5 s ran out.
    /// The shared `poll` reads the label every 0.3 s and judges one more read after the deadline.
    /// The lookup is an `identifier ==` predicate on static texts, not a string subscript, which
    /// fetches label, value, placeholder and identifier for every element walked and so adds to
    /// the per-query cost that caused these misses.
    private func waitForSearchCount(_ app: XCUIApplication, _ label: String, timeout: TimeInterval,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts.matching(NSPredicate(format: "identifier == %@", "terminal-find-count")).firstMatch
        var last = "(absent)"
        let met = poll(timeout, every: 0.3) {
            guard counter.exists else { return false }
            last = counter.label
            return last == label
        }
        if !met { XCTFail("the search counter should read \(label), last read \(last)", file: file, line: line) }
    }

    /// The newest page is five turns (three synthetic prompts and the mockup's two); each
    /// Load older adds a twenty-turn page, the second reaching the start of the session.
    func testSearchPagingPreservesSelectedMatchAndLoadedScope() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Synthetic question")
        let count = app.staticTexts["terminal-find-count"]
        waitForSearchCount(app, "1/3", timeout: 5)
        XCTAssertTrue(app.staticTexts["Searching loaded history"].isHittable)
        app.buttons["Load older"].tap()
        waitForSearchCount(app, "21/23", timeout: 10)
        app.buttons["Load older"].tap()
        waitForSearchCount(app, "38/40", timeout: 10)
        XCTAssertFalse(app.buttons["Load older"].exists)
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "38/40", "Refresh must retain paged history and the same selected prompt")
        record(app, "Loaded-history search expands to all forty prompts and preserves selection across refresh")
    }

    /// The DEBUG `chat-row-renders` probe: how many chat row bodies have run (its label;
    /// polled every 250 ms, so read it after a pause).
    private func rowRenders(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["chat-row-renders"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the row render probe should be on screen")
        return Int(probe.label) ?? -1
    }

    /// TestFlight build 221 lagged on every keystroke in a long agent session: the page
    /// that holds the composer redrew the chat with each character, and the chat redrew
    /// every one of its ~650 rows. On a page shaped like that session (`HERDR_CHAT_UX_LONG_SESSION`)
    /// typing must draw no transcript row at all, with the Subagents card (and its ticking
    /// elapsed times) on screen too.
    func testTypingInTheComposerDoesNotReRenderTheTranscript() {
        let app = launch(longSession: true, subagents: true)
        XCTAssertTrue(app.staticTexts["A complete fixture response."].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-subagents-toggle"].waitForExistence(timeout: 5), app.debugDescription)
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The keyboard is up and the chat has settled over it.
        Thread.sleep(forTimeInterval: 2)
        let before = rowRenders(app)
        XCTAssertGreaterThan(before, 0, "the chat's rows were drawn")
        let typed = "typing thirty chars into chat."
        XCTAssertEqual(typed.count, 30)
        field.typeText(typed)
        Thread.sleep(forTimeInterval: 1.5)
        let spent = rowRenders(app) - before
        XCTAssertEqual(spent, 0, "typing 30 characters re-rendered \(spent) transcript rows")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Scrolls the chat until `element` sits well inside the transcript: clear of the header,
    /// and of the composer and the fade above it, so its pixels are the colours drawn. It
    /// drags toward the element, whichever side it is on; `steps` bounds how far it goes.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication, _ what: String, steps: Int = 8,
                               file: StaticString = #filePath, line: UInt = #line) {
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        let composer = app.descendants(matching: .any)["composer-card"].firstMatch
        for _ in 0..<steps {
            let top = chat.frame.minY + 48
            let bottom = (composer.exists ? composer.frame.minY : chat.frame.maxY) - 48
            let frame = element.frame
            if frame.minY >= top, frame.maxY <= bottom { return }
            let middle = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            let step = min(180, max(60, frame.minY < top ? top - frame.minY : frame.maxY - bottom))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: frame.minY < top ? step : -step)))
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTFail("\(what) never came into view: \(element.frame)", file: file, line: line)
    }

    /// #550: the chat in omp's theme (dark-tokyo-night). Headings and each step's tool name
    /// are in the accent; code in a known language is highlighted on the theme's code ground,
    /// a language the highlighter does not know stays plain, and typing over all of it draws
    /// no transcript row (#536).
    func testChatDrawsTheThemesAccentAndSyntaxColours() throws {
        let accent: UInt32 = 0xBB9AF7, codeText: UInt32 = 0xA9B1D6, codeBackground: UInt32 = 0x16161E
        let string: UInt32 = 0x9ECE6A, comment: UInt32 = 0x51597D, function: UInt32 = 0x7AA2F7
        let number: UInt32 = 0xFF9E64, type: UInt32 = 0x0DB9D7
        let app = launch(longSession: true, environment: ["HERDR_CHAT_UX_COLOURS": "1"])
        let heading = app.staticTexts["Why the list jumps"]
        XCTAssertTrue(heading.waitForExistence(timeout: 12), app.debugDescription)
        bringIntoView(heading, in: app, "the heading")

        // The steps line just above the reply opens to rows that each name their tool.
        let toggles = app.buttons.matching(identifier: "chat-steps").allElementsBoundByIndex
        let toggle = try XCTUnwrap(toggles.filter { $0.frame.maxY <= heading.frame.minY }.max { $0.frame.minY < $1.frame.minY },
                                   app.debugDescription)
        toggle.tap()
        let read = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'chat-step' AND label == %@", "read, Reading the sort in AgentList.swift")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 5), app.debugDescription)
        for label in ["search, Searching for scrollPosition", "edit, Anchoring the list on the visible row",
                      "bash, Running the scroll tests"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == 'chat-step' AND label == %@", label)).firstMatch.exists,
                          "the step should read \(label): \(app.debugDescription)")
        }
        bringIntoView(read, in: app, "the read step")
        var pixels = try XCTUnwrap(ScreenPixels(app.screenshot()))
        XCTAssertGreaterThan(pixels.count(accent, in: read.frame), 15, "the step's tool name should be in the accent")

        bringIntoView(heading, in: app, "the heading")
        let swift = app.staticTexts.matching(NSPredicate(format: "identifier == 'gram-code-text' AND label CONTAINS 'resort'")).firstMatch
        XCTAssertTrue(swift.waitForExistence(timeout: 5), app.debugDescription)
        bringIntoView(swift, in: app, "the Swift block")
        let window = app.windows.firstMatch.frame
        // Highlighting runs off the main thread: give it a moment to land.
        for _ in 0..<10 {
            pixels = try XCTUnwrap(ScreenPixels(app.screenshot()))
            if pixels.count(string, in: swift.frame.intersection(window)) > 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        record(app, "chat-colours")
        XCTAssertGreaterThan(pixels.count(accent, in: heading.frame), 30, "the heading should be in the accent")
        let paragraph = app.staticTexts["The re-sort moves the row under your finger."]
        XCTAssertTrue(paragraph.exists, app.debugDescription)
        XCTAssertEqual(pixels.count(accent, in: paragraph.frame), 0, "body text stays the text colour")
        let swiftFrame = swift.frame.intersection(window)
        for (colour, kind) in [(accent, "keywords"), (string, "strings"), (comment, "comments"), (function, "functions"),
                               (number, "numbers"), (type, "types"), (codeText, "plain code")] {
            XCTAssertGreaterThan(pixels.count(colour, in: swiftFrame), 8, "the Swift block should colour its \(kind)")
        }
        XCTAssertGreaterThan(pixels.count(codeBackground, in: swiftFrame), 500, "code sits on the theme's code ground")

        let bash = app.staticTexts.matching(NSPredicate(format: "identifier == 'gram-code-text' AND label CONTAINS 'git status'")).firstMatch
        let plain = app.staticTexts.matching(NSPredicate(format: "identifier == 'gram-code-text' AND label CONTAINS 'plain notes'")).firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 5), app.debugDescription)
        bringIntoView(plain, in: app, "the plain block")
        bringIntoView(bash, in: app, "the bash block")
        for _ in 0..<10 {
            pixels = try XCTUnwrap(ScreenPixels(app.screenshot()))
            if pixels.count(string, in: bash.frame.intersection(window)) > 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        record(app, "chat-colours-code")
        let bashFrame = bash.frame.intersection(window)
        for (colour, kind) in [(comment, "comment"), (function, "commands"), (string, "string")] {
            XCTAssertGreaterThan(pixels.count(colour, in: bashFrame), 8, "the bash block should colour its \(kind)")
        }
        let plainFrame = plain.frame.intersection(window)
        XCTAssertGreaterThan(pixels.count(codeText, in: plainFrame), 8, "an unknown language is drawn in the code text colour")
        for colour in [accent, string, number, function] {
            XCTAssertEqual(pixels.count(colour, in: plainFrame), 0,
                           String(format: "an unknown language stays plain, but #%06X shows", colour))
        }

        // Typing over highlighted code draws no transcript row.
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        let before = rowRenders(app)
        field.typeText("colours stay put while typing")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(rowRenders(app) - before, 0, "typing re-rendered transcript rows")
    }

    /// herdrup#523 item 8: a one-letter search on a long chat froze the app until it was
    /// killed. On the large fixture it must cap the count, draw only a window of results,
    /// step through matches, and narrow to an exact count as the term grows.
    func testOneLetterSearchOnLargeChatCapsAndStaysResponsive() {
        let app = launch(large: true)
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("e")
        let capped = { (index: Int) in "Match \(index) of 500 or more matches" }
        waitForSearchCount(app, capped(1), timeout: 10)
        XCTAssertEqual(app.state, .runningForeground)
        let results = app.staticTexts.matching(identifier: "chat-search-result")
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertLessThanOrEqual(results.count, 23, "Only the selected match's neighbourhood is drawn, not every match")

        app.buttons["terminal-find-next"].tap()
        waitForSearchCount(app, capped(2), timeout: 5)
        app.buttons["terminal-find-previous"].tap()
        waitForSearchCount(app, capped(1), timeout: 5)
        app.buttons["terminal-find-previous"].tap()
        waitForSearchCount(app, capped(500), timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        record(app, "One-letter search on a long chat caps at 500+ and wraps to the last match")

        for letter in "xample" { field.typeText(String(letter)) }
        waitForSearchCount(app, "1/480", timeout: 10)
        app.buttons["terminal-find-next"].tap()
        waitForSearchCount(app, "2/480", timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testQuestionSheetFitsAndExpandsContext() {
        let app = launch(pendingQuestion: true)
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("Merge #305")
        XCTAssertTrue(app.staticTexts["chat-search-result"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["terminal-find"].tap()
        guard let open = app.buttons.matching(identifier: "chat-question-open").allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail(app.debugDescription)
        }
        open.tap()
        let context = app.buttons["Show context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5), app.debugDescription)
        record(app, "Question-first content-sized sheet")
        context.tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        record(app, "Question sheet expands context without losing question state")
        context.tap()
        guard let option = app.buttons.matching(identifier: "chat-ask-option-0").allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("The pending question must remain answerable after toggling context: \(app.debugDescription)")
        }
        option.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-chosen"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Done"].exists, "Answering must not dismiss the question sheet")
        record(app, "Question answer persists in the open content-sized sheet")
        app.buttons["Done"].tap()
        record(app, "Agent surface immediately after closing the question sheet")
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-note-done"].waitForNonExistence(timeout: 5), "Done must close only the question sheet")
    }

    func testRefreshFailureKeepsLoadedConversation() {
        let app = launch(failingRefresh: true)
        XCTAssertTrue(app.staticTexts["Review the table"].waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["terminal-refresh"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Refresh failed:")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        record(app, "Refresh failure remains visible without removing loaded chat")
    }

    /// What the chat's Copy last wrote, from the DEBUG `chat-copy-probe` (JSON in its label).
    /// Never `UIPasteboard`: a pasteboard read raises the system paste prompt, which nothing
    /// answers in CI (see TerminalSelectionTests' lesson 2).
    private func copiedText(_ app: XCUIApplication) -> String? {
        let label = app.descendants(matching: .any)["chat-copy-probe"].firstMatch.label
        let json = (try? JSONSerialization.jsonObject(with: Data(label.utf8))) as? [String: Any]
        return json?["copied"] as? String
    }

    private func waitForCopied(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 5,
                               file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while copiedText(app) != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(copiedText(app), expected, "the clipboard write", file: file, line: line)
    }

    /// Long-presses `element` (a right click on a Mac opens the same menu) and waits for its
    /// menu's `entry`.
    private func openMenu(_ app: XCUIApplication, on element: XCUIElement, entry: String,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        element.press(forDuration: 1.2)
        let button = app.buttons[entry].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the message menu offers \(entry): \(app.debugDescription)",
                      file: file, line: line)
        return button
    }

    /// Item 5 of #523: a reply's and a prompt's text can be copied and selected. The reply's
    /// menu copies it without markdown syntax, or as markdown; Select Text opens the message
    /// in a selectable text view; a fenced code block has its own Copy.
    func testMessagesCopyAndSelectText() {
        // Presentation only, so the fixture is held (`HERDR_CHAT_UX_STATIC`): each transcript
        // poll (about every 33 s) appends replies, and a chat following its tail moves the
        // pressed message up under the finger. On iPad run 41402663682 (job 125137668689) the
        // third poll landed 1.8 s before the long press on the prompt bubble; the press hit the
        // thought header below it and expanded the thought, so no menu opened.
        let app = launch(copyFixture: true, environment: ["HERDR_CHAT_UX_STATIC": "1"])
        let paragraph = app.staticTexts["Copy this reply, then paste it."].firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 12), app.debugDescription)
        bringIntoView(paragraph, in: app, "the reply")
        XCTAssertNil(copiedText(app), "precondition: nothing copied yet")

        let codeCopy = app.buttons["gram-code-copy"].firstMatch
        XCTAssertTrue(codeCopy.exists, "a chat code block has the Gram code block's Copy: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["swift"].exists, "a multi-line code block names its language")
        codeCopy.tap()
        expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: codeCopy)
        waitForExpectations(timeout: 5)
        record(app, "Chat code block with language header and Copy")

        let copy = openMenu(app, on: paragraph, entry: "Copy")
        XCTAssertTrue(app.buttons["Copy as Markdown"].exists, "a reply offers Copy as Markdown")
        XCTAssertTrue(app.buttons["Select Text"].exists, "a reply offers Select Text")
        record(app, "Reply message menu")
        copy.tap()
        waitForCopied(app, "Copy this reply, then paste it.\n\nlet copied = true\nprint(copied)")
        XCTAssertTrue(app.buttons["Copy as Markdown"].waitForNonExistence(timeout: 5), "the menu closes after Copy")

        openMenu(app, on: paragraph, entry: "Copy as Markdown").tap()
        waitForCopied(app, "Copy **this** reply, then *paste* it.\n\n```swift\nlet copied = true\nprint(copied)\n```")
        XCTAssertTrue(app.buttons["Select Text"].waitForNonExistence(timeout: 5), "the menu closes after Copy as Markdown")

        openMenu(app, on: paragraph, entry: "Select Text").tap()
        let textView = app.textViews["chat-select-text"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5), app.debugDescription)
        let selectable = textView.value as? String ?? ""
        XCTAssertTrue(selectable.contains("Copy this reply, then paste it."), "the sheet shows the reply: \(selectable)")
        XCTAssertTrue(selectable.contains("let copied = true\nprint(copied)"), "the sheet shows the code: \(selectable)")
        XCTAssertFalse(selectable.contains("**"), "the sheet shows the reply as read, not its markdown: \(selectable)")
        record(app, "Select Text sheet with the reply")
        app.buttons["chat-select-text-done"].tap()
        XCTAssertTrue(textView.waitForNonExistence(timeout: 5), "Done closes the Select Text sheet")

        // A swipe-down-only loop failed here on CI (#595, #627, #632 run 42137284739): after the
        // Select Text sheet closed, the prompt sat ~2,200 pt BELOW the visible chat, and each
        // swipe down moved it further away. Scroll toward it instead.
        let bubble = app.staticTexts["Check typography and wrapped tables."].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), app.debugDescription)
        bringIntoView(bubble, in: app, "the prompt bubble", steps: 24)
        let bubbleCopy = openMenu(app, on: bubble, entry: "Copy")
        XCTAssertFalse(app.buttons["Copy as Markdown"].exists, "a prompt is copied as typed, with no markdown variant")
        XCTAssertTrue(app.buttons["Select Text"].exists, "a prompt offers Select Text")
        bubbleCopy.tap()
        waitForCopied(app, "Check typography and wrapped tables.")

        // The chat's text-size control grows the code block's code too, as it does the
        // rest of the reply (GramCodeBlock's `textScale`; Gram itself keeps 1).
        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "let copied = true")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), app.debugDescription)
        let codeHeight = code.frame.height
        for _ in 0..<4 {
            app.buttons["terminal-actions"].tap()
            app.menuEntry("terminal-font-increase", label: "Increase").tap()
            dismissTextSizeMenu(app)
        }
        let deadline = Date().addingTimeInterval(5)
        while code.frame.height <= codeHeight + 4, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(code.frame.height, codeHeight + 4,
                             "four text-size steps grow the chat code block's code (was \(codeHeight) pt)")
        record(app, "Chat code block follows the chat text size")
        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
    }

    // MARK: Chat column width (#523 items 2 and 12)

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Polls `read` until `done` holds or `timeout` passes; returns the last reading.
    @discardableResult
    private func settle(within timeout: TimeInterval = 5, _ read: () -> CGFloat, until done: (CGFloat) -> Bool) -> CGFloat {
        var value = read()
        let deadline = Date().addingTimeInterval(timeout)
        while !done(value), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            value = read()
        }
        return value
    }

    /// A real touch drag on the column's right-edge handle: press just inside the edge (still
    /// on the handle's band, and clear of a window edge when the column is Full) at the
    /// handle's mid-height, which is the chat's, then drag `dx` points sideways.
    private func dragRightEdge(_ app: XCUIApplication, by dx: CGFloat) {
        let column = element(app, "chat-column").frame
        let handle = element(app, "chat-width-handle-right").frame
        let origin = app.frame.origin
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: column.maxX - 6 - origin.x, dy: handle.midY - origin.y))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    /// The Chat-mode composer card sits under the column at its width (less the card's 12 pt
    /// inset on each side), centred on it.
    private func assertComposerMatchesColumn(_ app: XCUIApplication, _ moment: String) {
        let column = element(app, "chat-column").frame
        let card = element(app, "composer-card")
        XCTAssertTrue(card.exists, app.debugDescription)
        XCTAssertEqual(card.frame.width, column.width - 24, accuracy: 2, "\(moment): the composer takes the column's width")
        XCTAssertEqual(card.frame.midX, column.midX, accuracy: 2, "\(moment): the composer is centred under the column")
    }

    /// iPhone keeps today's layout: no handles, a full-width column and composer. iPad shows
    /// both handles, named for VoiceOver.
    func testChatWidthHandlesOnlyOnRegularWidth() {
        let app = launch()
        let chat = element(app, "chat-width-area")
        let column = element(app, "chat-column")
        XCTAssertTrue(column.waitForExistence(timeout: 10), app.debugDescription)
        let left = element(app, "chat-width-handle-left")
        let right = element(app, "chat-width-handle-right")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(right.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(left.exists, app.debugDescription)
            XCTAssertEqual(right.label, "Chat width")
            XCTAssertTrue((right.value as? String)?.hasSuffix("points") == true
                          || (right.value as? String)?.contains("points,") == true,
                          "the handle reads its width: \(String(describing: right.value))")
            if column.frame.width <= chat.frame.width - 44 {
                XCTAssertEqual(left.frame.midX, column.frame.minX, accuracy: 1, "the left handle sits on the column's edge")
                XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the right handle sits on the column's edge")
            } else {
                // Full (a portrait iPad's chat is narrower than Readable): the bands stay
                // inside the chat, clear of the sidebar and the window edge.
                XCTAssertGreaterThanOrEqual(left.frame.minX, chat.frame.minX - 0.5, "the left handle stays inside the chat")
                XCTAssertLessThanOrEqual(right.frame.maxX, chat.frame.maxX + 0.5, "the right handle stays inside the chat")
            }
            assertComposerMatchesColumn(app, "iPad Chat")
            record(app, "iPad chat column with its edge handles")
        } else {
            XCTAssertFalse(left.exists, "no width handles on iPhone")
            XCTAssertFalse(right.exists, "no width handles on iPhone")
            XCTAssertEqual(column.frame.width, chat.frame.width, accuracy: 1, "the phone's column spans the chat")
            let card = element(app, "composer-card")
            XCTAssertTrue(card.exists, app.debugDescription)
            XCTAssertEqual(card.frame.width, chat.frame.width - 24, accuracy: 2, "the phone's composer keeps the full width")
            record(app, "iPhone chat keeps the full-width column and composer")
        }
    }

    /// Dragging the right edge resizes the column around its centre and the composer follows;
    /// near 720 it snaps to Readable; the width survives a relaunch; a double tap resets to Wide.
    func testDraggingTheChatEdgeResizesTheColumn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the chat width is resizable on regular width only")
        // Landscape gives the detail column room for Wide (1000) and a drag down to Readable.
        XCUIDevice.shared.orientation = .landscapeLeft
        rotated = true
        let hold = ["HERDR_COLUMN_WIDTH_READOUT_HOLD": "8"]
        let app = launch(environment: hold)
        let chat = element(app, "chat-width-area")
        let column = element(app, "chat-column")
        let right = element(app, "chat-width-handle-right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), app.debugDescription)
        var available = settle(within: 8, { chat.frame.width }, until: { $0 > 1000 })
        // An earlier class may leave the app in a smaller window (iPadOS restores its size):
        // minimising the sidebar gives the chat the window's width.
        if available < 780 {
            let minimise = app.buttons.matching(NSPredicate(format: "label == %@", "Minimise sidebar")).firstMatch
            XCTAssertTrue(minimise.waitForExistence(timeout: 5), "chat only \(available) pt wide: \(app.debugDescription)")
            minimise.tap()
            minimisedSidebar = true
            available = settle(within: 8, { chat.frame.width }, until: { $0 >= 780 })
        }
        XCTAssertGreaterThanOrEqual(available, 780, "the chat needs room to drag down to Readable: \(app.debugDescription)")
        let wide = min(1000, available)
        let initial = settle({ column.frame.width }, until: { abs($0 - wide) < 0.5 })
        XCTAssertEqual(initial, wide, accuracy: 0.5, "the column starts Wide (or Full when narrower)")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1, "the column is centred")
        if initial <= available - 44 {
            XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the handle sits on the column's edge")
        }
        assertComposerMatchesColumn(app, "Wide")
        let initialMinX = column.frame.minX
        record(app, "Chat column at Wide (\(Int(initial)) pt of \(Int(available)))")

        // Inwards: both edges move in by the drag, so the column narrows by twice it and stays
        // centred. The target stays clear of Readable's snap zone.
        let shrink: CGFloat = abs(initial - 120 - 720) <= 16 ? 200 : 120
        // The width is the column's frame, not a row input: rows reflow in layout, but a drag's
        // many ticks must not re-run their bodies. One full pass of the drawn rows (at most
        // the ~40-row window) is the bound; per-tick invalidation would be many times that.
        Thread.sleep(forTimeInterval: 1)
        let rendersBeforeDrag = rowRenders(app)
        dragRightEdge(app, by: -shrink / 2)
        let narrowed = settle({ column.frame.width }, until: { abs($0 - (initial - shrink)) <= 4 })
        XCTAssertEqual(narrowed, initial - shrink, accuracy: 4, "each point of drag narrows the column by two")
        Thread.sleep(forTimeInterval: 0.6)
        let dragRenders = rowRenders(app) - rendersBeforeDrag
        XCTAssertLessThanOrEqual(dragRenders, 40, "a width drag re-rendered \(dragRenders) transcript rows")
        XCTAssertEqual(column.frame.minX - initialMinX, shrink / 2, accuracy: 2, "the left edge moves in with the right")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1, "the column stays centred")

        // Aim at 714: within 12 pt of Readable, so it lands on exactly 720.
        dragRightEdge(app, by: -(narrowed - 714) / 2)
        let readable = settle({ column.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(readable, 720, accuracy: 0.5, "a width near 720 snaps to Readable")
        let readout = app.staticTexts["chat-width-readout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(readout.label, "720 pt · Readable")
        XCTAssertEqual(right.value as? String, "720 points, Readable")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(app, "Readable")
        record(app, "Chat column snapped to Readable with its readout")

        // Remembered: a relaunch that keeps the stored width shows Readable again.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        let again = launch(environment: hold.merging(["HERDR_MOCK_COLUMN_WIDTH": "keep"]) { _, new in new })
        let againChat = element(again, "chat-width-area")
        let againColumn = element(again, "chat-column")
        let againRight = element(again, "chat-width-handle-right")
        XCTAssertTrue(againRight.waitForExistence(timeout: 10), again.debugDescription)
        let kept = settle({ againColumn.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(kept, 720, accuracy: 0.5, "the chosen width survives a relaunch")
        assertComposerMatchesColumn(again, "After relaunch")
        record(again, "Readable remembered across a relaunch")

        // A double tap on a handle resets to Wide (Full when the chat is narrower).
        againRight.doubleTap()
        let againWide = min(1000, againChat.frame.width)
        let reset = settle({ againColumn.frame.width }, until: { abs($0 - againWide) < 0.5 })
        XCTAssertEqual(reset, againWide, accuracy: 0.5, "a double tap resets to Wide")
        XCTAssertEqual(againColumn.frame.midX, againChat.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(again, "After reset")
        if againChat.frame.width > 1000.5 {
            XCTAssertEqual(againRight.value as? String, "1000 points, Wide")
        }
        record(again, "Double tap resets the chat column to Wide")
    }

    /// Chat and Gram share one column width (#541): a width chosen in Chat is the width Gram
    /// shows, and a reset in Gram is Chat's too.
    func testChatAndGramShareTheColumnWidth() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the column width is resizable on regular width only")
        XCUIDevice.shared.orientation = .landscapeLeft
        rotated = true
        let app = launch()
        let chat = element(app, "chat-width-area")
        let column = element(app, "chat-column")
        let right = element(app, "chat-width-handle-right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), app.debugDescription)
        let available = settle(within: 8, { chat.frame.width }, until: { $0 > 1000 })
        let wide = min(1000, available)
        let initial = settle({ column.frame.width }, until: { abs($0 - wide) < 0.5 })
        XCTAssertEqual(initial, wide, accuracy: 0.5, "the column starts Wide (or Full when narrower)")

        // Narrower by 100 pt (or onto Readable, if that is within reach of the snap).
        dragRightEdge(app, by: -50)
        let chosen = settle({ column.frame.width }, until: { $0 < initial - 50 })
        XCTAssertLessThan(chosen, initial - 50, "the drag narrows the chat column")
        record(app, "Chat column set to \(Int(chosen)) pt")

        let gramTab = app.buttons["Gram"].firstMatch
        XCTAssertTrue(gramTab.waitForExistence(timeout: 5), app.debugDescription)
        gramTab.tap()
        let gramColumn = element(app, "gram-column")
        // Gram's own width (its feed's scroll view runs on under the floating sidebar).
        let gramFeed = element(app, "gram-width-area")
        XCTAssertTrue(gramColumn.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(gramFeed.waitForExistence(timeout: 5), app.debugDescription)
        let expected = min(chosen, gramFeed.frame.width)
        let shown = settle({ gramColumn.frame.width }, until: { abs($0 - expected) < 0.5 })
        XCTAssertEqual(shown, expected, accuracy: 0.5, "Gram shows the width chosen in Chat")
        XCTAssertEqual(gramColumn.frame.midX, gramFeed.frame.midX, accuracy: 1, "Gram's column is centred")
        record(app, "Gram at the width chosen in Chat (\(Int(shown)) pt)")

        // The other way: a reset in Gram is Chat's width too.
        let gramRight = element(app, "gram-width-handle-right")
        XCTAssertTrue(gramRight.waitForExistence(timeout: 5), app.debugDescription)
        gramRight.doubleTap()
        let gramWide = min(1000, gramFeed.frame.width)
        let reset = settle({ gramColumn.frame.width }, until: { abs($0 - gramWide) < 0.5 })
        XCTAssertEqual(reset, gramWide, accuracy: 0.5, "a double tap in Gram resets to Wide")
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(right.waitForExistence(timeout: 5), app.debugDescription)
        let chatWide = min(1000, chat.frame.width)
        let back = settle({ column.frame.width }, until: { abs($0 - chatWide) < 0.5 })
        XCTAssertEqual(back, chatWide, accuracy: 0.5, "the reset in Gram is Chat's width too")
        record(app, "Chat back at Wide after the reset in Gram")
    }

    /// Set by the width test: puts the iPad back as the other tests expect it, pass or fail.
    private var rotated = false
    private var minimisedSidebar = false

    override func tearDown() {
        if minimisedSidebar {
            let app = XCUIApplication()
            let expand = app.buttons.matching(NSPredicate(format: "label == %@", "Expand sidebar")).firstMatch
            if app.state == .runningForeground, expand.exists { expand.tap() }
            minimisedSidebar = false
        }
        if rotated {
            XCUIDevice.shared.orientation = .portrait
            rotated = false
        }
        super.tearDown()
    }
}
