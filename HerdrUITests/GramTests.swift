import XCTest

/// Exercise Gram through its real tab/sidebar host. A standalone GramView deliberately
/// omits the regular-width header: Read all, search and the conversations belong to the
/// host's sidebar there.
///
/// Strings come from the mock `gram.list` (MockWireFixtures.gramList), the design's sample
/// conversation, newest first: g1 your "Great, ship it." to vetrina; g2 clientloop (relayed
/// from hetzner-1) with a one-line code fence and a zip; g3 a vetrina image; g4 vetrina's
/// 11-line "Deployed." report that folds at 8 lines; g5 a queue post grabbed by ci-watch; g6
/// trend-scout's "Digest ready" (relayed); g10 a LOCAL clientloop's "Lint is clean on my branch."
/// (two agents share the name clientloop); g7–g9 yesterday's vetrina thread. g2–g4 are unread.
final class GramTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// iPad and Mac draw Gram in the split view: the sidebar holds search, the conversations
    /// and Read all. iPhone keeps them on the page (search button, the "Gram ›" pill's sheet).
    private var hasSidebar: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    private func launchGram(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication.launched(mock: "list", environment: environment)
        let tab = app.buttons["Gram"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        return app
    }

    /// The search field: in the sidebar on iPad/Mac (always there, no toggle on the page),
    /// behind the page's search button on iPhone.
    private func openSearchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["gram-search-field"]
        if hasSidebar {
            XCTAssertTrue(field.waitForExistence(timeout: 5), "the sidebar should hold the Gram search")
            XCTAssertFalse(app.buttons["gram-search"].exists,
                           "with the sidebar's field the page shows no search toggle of its own")
        } else {
            let toggle = app.buttons["gram-search"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the header should offer search")
            XCTAssertTrue(toggle.isHittable, "the newest message must not cover the search control")
            toggle.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "the search button should reveal the search field")
        }
        return field
    }

    /// Waits until Read all reports nothing unread. iPad/Mac: the sidebar button renders only
    /// while something is unread, so gone means zero. iPhone: the sheet's button stays and
    /// carries the count as its value ("3 unread"), which empties only at zero; disabled alone
    /// would also match the pass still in flight, or a pass that marked nothing.
    private func waitUntilNothingUnread(_ readAll: XCUIElement, timeout: TimeInterval) -> Bool {
        let zero = hasSidebar
            ? NSPredicate(format: "exists == false")
            : NSPredicate(format: "exists == true AND NOT (value CONTAINS %@)", "unread")
        return waitForPredicate(zero, object: readAll, timeout: timeout)
    }

    func testGramPageRenders() {
        let app = launchGram()

        // Give the mock gram.list a moment to load + lay out the rows.
        Thread.sleep(forTimeInterval: 2.0)

        // A canned agent->owner message's sender label should appear: the bare agent name,
        // its machine ("· hetzner-1") a separate span.
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "an agent->owner message should render its sender")
        // Like Messages, the feed opens at the NEWEST message (g1, the owner's reply), not
        // part-way up: a lazy feed once opened mid-history on iPhone.
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "the newest message should be laid out")
        XCTAssertTrue(newest.isHittable, "the feed should open showing the newest message")

        attach(app, "gram-page")
    }

    /// The search field filters the loaded inbox, and a filter that matches nothing says so
    /// instead of leaving a blank scroll that reads as an empty inbox.
    ///
    /// "Digest" appears in exactly one message (g6, from trend-scout), and "clientloop" is the
    /// sender label of a DIFFERENT message (g2), near the bottom of the feed so it is on screen
    /// before filtering — so one label surviving while the other disappears is a receipt that
    /// rows were filtered, not merely re-laid-out.
    func testGramSearchFiltersTheInbox() {
        let app = launchGram()

        // The sender that should disappear is present before any filter: the pre-state the
        // filter acts on. Without this the later disappearance would prove nothing.
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10),
                      "the newest agent->owner message should render before filtering")

        let field = openSearchField(app)
        field.tap()
        field.typeText("Digest")

        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 3),
                      "the matching message should survive the filter")
        XCTAssertTrue(app.staticTexts["clientloop"].waitForNonExistence(timeout: 5),
                      "a message matching nothing in the search should be filtered out")

        // A filter that matches nothing: the "No matches" state, NOT a blank list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5),
                      "a filter matching no message should say so")

        // Clearing the field restores the full list, back at the newest message: the deletes
        // pass through "z", which matches a short list (the hetzner-1 senders and the zip), and the feed must not be left
        // scrolled to that short list's top, where the restored rows near the bottom are not
        // even laid out. Checked ON SCREEN (hittable), not merely present: the newest bubble
        // (g1, "Great, ship it.") and its neighbour's sender, clientloop. With the iPhone
        // keyboard up the feed is short, so clientloop's label is checked for existence and the
        // newest bubble for being on screen.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "clearing the search should bring the filtered-out messages back")
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        let onScreen = NSPredicate(format: "hittable == true")
        XCTAssertTrue(waitForPredicate(onScreen, object: newest, timeout: 5),
                       "clearing the search should return the feed to the newest message, on screen")

        // CLOSING must also clear. A hidden field that is still filtering would leave the
        // list silently short with nothing on screen to explain it - the failure mode a
        // dismissible search box invites. Re-filter first so the close has work to undo.
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        if hasSidebar {
            // The sidebar field stays; its Clear button is the way back.
            app.buttons["Clear search"].firstMatch.tap()
        } else {
            app.buttons["gram-search"].tap()
            XCTAssertFalse(field.exists, "closing should dismiss the field")
        }
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "clearing or closing search should restore the unfiltered list")
    }

    /// Owner rule: search fields have no mic (the composer keeps dictation). Neither the Gram
    /// search nor anything beside it offers dictation.
    func testGramSearchFieldHasNoMic() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = openSearchField(app)

        XCTAssertFalse(app.buttons["gram-search-mic"].exists, "the Gram search has no mic")
        XCTAssertFalse(app.buttons["agent-search-mic"].exists, "no search field has a mic")
        // The composer's own Dictate stays (it is far below); none may sit on the field's row.
        let row = field.frame.insetBy(dx: -60, dy: -8)
        let dictate = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@",
                                                       "Dictate", "Dictate"))
        for mic in dictate.allElementsBoundByIndex where mic.exists {
            XCTAssertFalse(mic.frame.intersects(row), "a Dictate button sits beside the search field")
        }
    }

    /// Read all marks the unread messages read: the count it reports reaches zero. On iPad/Mac
    /// it is the capsule button in the sidebar bar, present only while something is unread; on
    /// iPhone it is in the sheet the header's "Gram ›" pill opens, and its value is the unread
    /// count ("3 unread", empty at zero).
    ///
    /// Fourteen newer messages (`HERDR_MOCK_GRAM_NEWER`) keep the unread ones above the fold,
    /// so their rows do not mark themselves read on screen first and Read all has them to
    /// clear. The mock keeps what `gram.mark_read` marked, as the daemon does, so the count
    /// stays at zero once cleared.
    func testGramReadAllClearsTheUnreadCount() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_NEWER": "1"])
        let readAll = tapReadAll(app)
        XCTAssertTrue(waitUntilNothingUnread(readAll, timeout: 4),
                      "tapping Read all should drive the unread count to zero")
    }

    /// A poll in flight across Read all must not bring the count back: its answer was
    /// computed before the marks landed. `HERDR_MOCK_GRAM_HOLD_POLL` holds a head list
    /// until a second after the first `gram.mark_read`; Refresh, in the same sheet just
    /// above Read all, starts one right before the tap. iPhone only: the sheet holds both.
    func testAPollInFlightDuringReadAllDoesNotBringTheCountBack() throws {
        try XCTSkipIf(hasSidebar, "Refresh and Read all share the iPhone pill's sheet")
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_NEWER": "1", "HERDR_MOCK_GRAM_HOLD_POLL": "1"])
        let refresh = app.buttons["Refresh"].firstMatch
        let readAll = tapReadAll(app, after: refresh)
        XCTAssertTrue(waitUntilNothingUnread(readAll, timeout: 4),
                      "tapping Read all should drive the unread count to zero")
        // The held list lands a second after the first mark: past it, the count is still zero.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertTrue(waitUntilNothingUnread(readAll, timeout: 0),
                          "a poll requested before Read all brought the count back: \(readAll.exists ? (readAll.value as? String ?? "") : "Read all is back")")
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Waits for the mock inbox, opens Read all (iPhone: in the pill's sheet), checks it has
    /// a count to clear, taps `first` if given (a button beside it), then taps Read all once.
    private func tapReadAll(_ app: XCUIApplication, after first: XCUIElement? = nil) -> XCUIElement {
        XCTAssertTrue(app.descendants(matching: .any)["gram-bubble-gn14"].waitForExistence(timeout: 10),
                      "the Gram page should load the mock inbox")
        let readAll = app.buttons["Read all"].firstMatch
        if !hasSidebar {
            let pill = app.buttons["gram-header-pill"]
            XCTAssertTrue(pill.waitForExistence(timeout: 5), "the header should show the Gram pill")
            XCTAssertEqual(pill.label, "Gram")
            pill.tap()
        }
        // The count is there to clear: iPhone's value names it, iPad's button shows only then.
        let pending = hasSidebar
            ? NSPredicate(format: "exists == true")
            : NSPredicate(format: "exists == true AND value CONTAINS %@", "unread")
        XCTAssertTrue(waitForPredicate(pending, object: readAll, timeout: 5),
                      "Read all should offer unread messages to clear; says \(readAll.exists ? (readAll.value as? String ?? "") : "nothing")")
        if let first {
            XCTAssertTrue(first.isHittable, "\(first) should sit beside Read all")
            first.tap()
        }
        readAll.tap()
        return readAll
    }

    /// iPhone: with Saved showing, the header pill says so ("Saved ›", spoken "Saved"); back
    /// on the inbox it reads "Gram" again. iPad/Mac show Saved as the sidebar's selected row.
    func testGramHeaderPillNamesSavedOnIPhone() throws {
        try XCTSkipIf(hasSidebar, "iPad/Mac name the Saved section in the sidebar")
        let app = launchGram()
        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the header should show the Gram pill")
        XCTAssertEqual(pill.label, "Gram")

        let savedToggle = app.buttons["gram-saved-toggle"]
        XCTAssertTrue(savedToggle.waitForExistence(timeout: 5))
        savedToggle.tap()
        XCTAssertTrue(app.staticTexts["No saved messages yet"].waitForExistence(timeout: 5),
                      "the bookmark toggle should show the (empty) Saved list")
        XCTAssertEqual(pill.label, "Saved", "the pill should name the Saved list")
        XCTAssertTrue(pill.staticTexts["Saved"].exists, "the pill should read \"Saved ›\"")

        savedToggle.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5))
        XCTAssertEqual(pill.label, "Gram", "back on the inbox the pill reads Gram again")
    }

    /// Paging: the first page (`HERDR_MOCK_GRAM_PAGED`, MockTransport.gramPagedList) has more
    /// behind it. Opening lands on the newest message; reaching the top fetches exactly ONE
    /// older page (24 rows, go1 newest to go24 oldest, more than a screen), and the message that
    /// was on top before (g9, "Picked up the deploy ticket.") stays on screen rather than being
    /// pushed down by the rows inserted above it. The mock has a third page behind go24, so a
    /// chained fetch would show as a count past 36. (A first page that fits the screen, as it
    /// may on a large iPad, shows the top on open, so its fetch then is the reader's too.)
    func testGramScrollingToTheTopLoadsOneOlderPage() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])

        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 5),
                      "the feed opens at the newest message")
        func label(_ prefix: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        // The loaded-message count rides on the feed's message stack (`gram-feed-messages`).
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5), "the feed should report its message count")
        if !hasSidebar {
            // The phone's first page overfills the screen: opening fetches nothing.
            XCTAssertTrue(waitForCount(messages, 12, timeout: 2), "opening should not load an older page; feed says \(messages.value ?? "nil")")
        }

        // Scroll up only until the page lands, so the swipes themselves cannot reach the top
        // of the NEW page and ask for the next one.
        var paged = waitForCount(messages, 36, timeout: 2)
        for _ in 0..<8 where !paged {
            feed.swipeDown(velocity: .slow)
            paged = waitForCount(messages, 36, timeout: 3)
        }
        XCTAssertTrue(paged, "reaching the top should load the older page (12 + 24 messages); feed says \(messages.value ?? "nil")")

        let previousTop = label("Picked up the deploy ticket.")
        XCTAssertTrue(previousTop.waitForExistence(timeout: 3) && previousTop.isHittable,
                      "the message that was on top should stay on screen after the older page lands")

        // Let a chained fetch, if any, land: the count must stay at exactly one page.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "36 messages", "exactly one older page should load")

        // The page's oldest message is at its top (reaching it may fetch the next page: the
        // reader is at the top again).
        let olderOldest = label("Older page: release planning starts here.")
        for _ in 0..<10 where !olderOldest.isHittable { feed.swipeDown(velocity: .slow) }
        XCTAssertTrue(olderOldest.isHittable, "the older page's oldest message should appear")
    }

    /// The feed draws only the newest window of the loaded messages (paging keeps adding to
    /// what is loaded). Reaching the top reveals the older LOADED ones first, without asking
    /// the daemon for another page. A 6-message window over the 12-message first page. iPhone
    /// only: an iPad screen fits the 6 rows, so the sentinel is on screen at once and reveals
    /// them before anything can be observed (the same code path, correctly).
    func testOlderLoadedMessagesAreRevealedWithoutFetching() throws {
        try XCTSkipIf(hasSidebar, "the window fits the iPad screen: revealed at once")
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1", "HERDR_GRAM_RENDER_WINDOW": "6"])
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 5),
                      "the feed opens at the newest message")
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5))
        XCTAssertEqual(messages.value as? String, "12 messages", "one page is loaded")
        let oldest = app.descendants(matching: .any)["gram-bubble-g9"]
        XCTAssertFalse(oldest.exists, "the oldest loaded message is outside the drawn window")

        for _ in 0..<8 where !oldest.exists { feed.swipeDown(velocity: .slow); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(oldest.waitForExistence(timeout: 3), "reaching the top should draw the older loaded messages")
        // The revealed rows push the sentinel off screen again: no fetch. Wait past the anchor
        // restore (up to ~0.7 s) and the mock's round trip, so a page fetched after the reveal
        // would have landed.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "12 messages", "revealing loaded rows fetches no page")
    }

    /// iPhone: Gram is a persistent tab, so leaving it and coming back keeps the feed's layout
    /// exactly as it was. Leaving clears what the feed knows is on screen; coming back must
    /// re-learn it without the reader scrolling, or the initial scroll never finishes and the
    /// top sentinel never fetches (nor do rows mark read or new messages follow). After the
    /// round trip, reaching the top loads exactly one older page, as on first open.
    func testGramStillPagesAfterATabRoundTrip() throws {
        try XCTSkipIf(hasSidebar, "iPad/Mac show Gram in the split view, not a tab")
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])

        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5), "the feed should report its message count")
        XCTAssertTrue(waitForCount(messages, 12, timeout: 5), "the first page only; feed says \(messages.value ?? "nil")")
        let newest = app.staticTexts["Great, ship it."]
        XCTAssertTrue(newest.waitForExistence(timeout: 5) && newest.isHittable,
                      "the feed opens at the newest message")

        let tabs = app.tabBars.firstMatch
        let agentsTab = tabs.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 5))
        agentsTab.tap()
        XCTAssertTrue(newest.waitForNonExistence(timeout: 5) || !newest.isHittable,
                      "the Agents tab should cover Gram")
        let gramTab = tabs.buttons["Gram"]
        XCTAssertTrue(gramTab.waitForExistence(timeout: 5))
        gramTab.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 5) && newest.isHittable,
                      "back on Gram, the feed is still at the newest message")
        XCTAssertTrue(waitForCount(messages, 12, timeout: 2), "coming back loads nothing; feed says \(messages.value ?? "nil")")

        var paged = waitForCount(messages, 36, timeout: 2)
        for _ in 0..<8 where !paged {
            feed.swipeDown(velocity: .slow)
            paged = waitForCount(messages, 36, timeout: 3)
        }
        XCTAssertTrue(paged, "after a tab round trip, reaching the top should still load the older page; feed says \(messages.value ?? "nil")")
        let previousTop = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Picked up the deploy ticket.")).firstMatch
        XCTAssertTrue(previousTop.waitForExistence(timeout: 3) && previousTop.isHittable,
                      "the message that was on top should stay on screen after the older page lands")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "36 messages", "exactly one older page should load")
    }

    /// Tapping the selected Gram tab again goes to the NEWEST message, at the bottom of this
    /// oldest-first feed, as the feed's own "follow newest" does; not to the OLDEST at the top
    /// (the system's scroll-to-top on a tab re-tap did that on iPhone). Read up into the older
    /// page first, so the newest is well off screen. iPad's section bar does the same.
    func testTappingTheSelectedGramTabGoesToTheNewestMessage() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        func onScreen(_ element: XCUIElement) -> Bool {
            element.exists && element.isHittable
                && element.frame.minY >= feed.frame.minY && element.frame.maxY <= feed.frame.maxY
        }
        let newest = app.staticTexts["Great, ship it."]
        XCTAssertTrue(newest.waitForExistence(timeout: 5) && poll(5, every: 0.25) { onScreen(newest) },
                      "the feed opens at the newest message")

        // Up to the older page's oldest message (reaching the top fetched that page).
        let olderOldest = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Older page: release planning starts here.")).firstMatch
        for _ in 0..<16 where !onScreen(olderOldest) { feed.swipeDown(velocity: .slow) }
        XCTAssertTrue(onScreen(olderOldest), "the older page's oldest message should be on screen")
        // Let a fetch from reaching that top land, so it cannot move the feed after the tap.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(onScreen(newest), "the newest message is off screen at the top")

        // The tab bar's Gram on iPhone, not the first "Gram" button: on iOS 27 that is the
        // page's "Gram ›" pill, which opens its sheet instead.
        (hasSidebar ? app.buttons["Gram"].firstMatch : app.tabBars.firstMatch.buttons["Gram"]).tap()
        XCTAssertTrue(poll(5, every: 0.25) { onScreen(newest) },
                      "tapping the selected Gram tab should go to the newest message")
        // Past any late scroll (the system's to the top would land after ours).
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(onScreen(newest), "the feed should stay at the newest message")
        XCTAssertFalse(olderOldest.isHittable, "the feed should not be at the oldest messages")
    }

    // MARK: - Render budget

    /// The DEBUG `gram-row-renders` probe: how many `GramRow` bodies have run (its label;
    /// polled every 250 ms, so read it after a pause).
    private func rowRenders(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["gram-row-renders"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG row-render probe should be present")
        return Int(probe.label) ?? -1
    }

    /// Scrolling a feed of pictures re-renders only the rows that change. Twelve image messages
    /// (`HERDR_MOCK_GRAM_IMAGES`), each under a three-line text, 36 rows in all. A picture
    /// coming on or off screen re-renders its own row (and its preview landing, once); with
    /// the on-screen set held by the PAGE, every such change re-rendered every row. Six
    /// swipes carry a dozen pictures across the edges: about 30-60 row renders now, and well
    /// over 800 (two dozen crossings x 34 rows, plus a page render per prefetch) before.
    func testScrollingPicturesStaysWithinARowRenderBudget() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_IMAGES": "12"])
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        let newest = app.descendants(matching: .any)["gram-bubble-gt12"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10) && newest.isHittable, "the feed opens at the newest message")
        // Let the opening settle: the landing, the pictures on screen fetching and decoding.
        Thread.sleep(forTimeInterval: 3)
        let before = rowRenders(app)
        for _ in 0..<3 { feed.swipeDown(); Thread.sleep(forTimeInterval: 0.6) }
        for _ in 0..<3 { feed.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        Thread.sleep(forTimeInterval: 2)
        let spent = rowRenders(app) - before
        XCTAssertGreaterThan(spent, 0, "pictures crossing the screen re-render their own rows")
        XCTAssertLessThan(spent, 150, "scrolling should re-render only the rows that change; spent \(spent)")
    }

    /// Typing in the composer re-renders the page on every keystroke; the rows, whose inputs
    /// do not change, must not re-render with it. Before rows were `Equatable`, each of the
    /// ten keystrokes re-rendered all ten rows (about 100).
    func testTypingInTheComposerDoesNotReRenderTheRows() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // The keyboard is up and the feed has settled under it.
        Thread.sleep(forTimeInterval: 2)
        let before = rowRenders(app)
        field.typeText("abcdefghij")
        Thread.sleep(forTimeInterval: 1.5)
        let spent = rowRenders(app) - before
        XCTAssertLessThanOrEqual(spent, 5, "typing should not re-render the feed's rows; spent \(spent)")
    }

    // MARK: - Saved paging

    /// Saved reads like the inbox: oldest at the top, opening at the NEWEST saved message,
    /// drawing only the newest window, and revealing older saved ones when the reader reaches
    /// the top, keeping their place. 30 saved (`HERDR_MOCK_GRAM_SAVED`, gs1 oldest) under a
    /// 20-message window: gs11...gs30 drawn at first.
    func testSavedOpensAtTheNewestAndRevealsOlderOnesAtTheTop() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_SAVED": "30", "HERDR_GRAM_RENDER_WINDOW": "20"])
        let toggle = app.buttons["gram-saved-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let feed = app.scrollViews["gram-saved-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5), "the Saved feed should show")
        let newest = app.descendants(matching: .any)["gram-saved-gs30"]
        let onScreen = NSPredicate(format: "hittable == true")
        XCTAssertTrue(waitForPredicate(onScreen, object: newest, timeout: 5),
                       "Saved should open at the newest saved message, on screen")
        let drawn = app.otherElements["gram-saved-messages"]
        XCTAssertTrue(drawn.waitForExistence(timeout: 5))
        XCTAssertEqual(drawn.value as? String, "20 of 30 saved", "only the newest window is drawn")
        XCTAssertFalse(app.descendants(matching: .any)["gram-saved-gs10"].exists,
                       "a saved message older than the window is not drawn until the reader scrolls up")
        XCTAssertFalse(app.descendants(matching: .any)["gram-saved-gs1"].exists, "the oldest is not drawn")

        func waitForDrawn(_ value: String, timeout: TimeInterval) -> Bool {
            let shown = NSPredicate(format: "value == %@", value)
            return waitForPredicate(shown, object: drawn, timeout: timeout)
        }
        var revealed = false
        for _ in 0..<12 where !revealed {
            feed.swipeDown(velocity: .slow)
            revealed = waitForDrawn("30 of 30 saved", timeout: 1.5)
        }
        XCTAssertTrue(revealed, "reaching the top should draw the older saved messages; says \(drawn.value ?? "nil")")
        let previousTop = app.descendants(matching: .any)["gram-saved-gs11"]
        XCTAssertTrue(previousTop.waitForExistence(timeout: 3) && previousTop.isHittable,
                      "the saved message that was on top should stay on screen after the reveal")
        let oldest = app.descendants(matching: .any)["gram-saved-gs1"]
        for _ in 0..<10 where !oldest.isHittable { feed.swipeDown(velocity: .slow) }
        XCTAssertTrue(oldest.isHittable, "scrolling up reaches the oldest saved message")
    }

    // MARK: - Search paging

    /// The DEBUG `gram-list-pages` probe: how many older pages (`before_id`) the paged mock
    /// answered (its label; polled every 250 ms).
    private func listPages(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["gram-list-pages"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG list-pages probe should be present")
        return Int(probe.label) ?? -1
    }

    /// A search covers the loaded messages and fetches nothing by itself: "Digest" matches g6
    /// on the first page, so no older page is requested (the removed whole-store walk asked
    /// for every page), even though older history is available.
    func testSearchMatchingRecentMessagesFetchesNoOlderPage() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 10), "the feed opens")
        // iPad/Mac: the first page fits, so opening loads one older page. Let that land first.
        Thread.sleep(forTimeInterval: 3)
        let before = listPages(app)
        let field = openSearchField(app)
        field.tap()
        field.typeText("Digest")
        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 5), "the match shows")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(listPages(app), before, "a search must not fetch older pages the reader did not ask for")
    }

    /// Reaching the top of a search's results searches older pages until a NEW match lands,
    /// keeping the reader's place. "vetrina" matches 6 rows of the first page (and every row
    /// of the older ones), more than a screen. iPhone holds the first page alone, so the
    /// older match is go1; iPad/Mac loaded the second page on open, so it is gx1, the last.
    func testReachingTheTopOfSearchResultsFindsOlderMatches() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 10), "the feed opens")
        Thread.sleep(forTimeInterval: 3)
        let pagesBefore = listPages(app)
        let field = openSearchField(app)
        field.tap()
        field.typeText("vetrina")
        let matches = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(matches.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(listPages(app), pagesBefore, "typing the query fetches nothing")
        let shown = matches.value as? String ?? ""
        let older = app.descendants(matching: .any)[shown == "6 messages" ? "gram-bubble-go1" : "gram-bubble-gx1"]
        XCTAssertFalse(older.exists, "the older match is not loaded yet; feed says \(shown)")

        for _ in 0..<10 where !older.exists {
            feed.swipeDown(velocity: .slow)
            _ = older.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(older.exists, "reaching the top of the results should fetch older pages until a match lands")
        XCTAssertGreaterThan(listPages(app), pagesBefore, "the older match came from an older page")
        XCTAssertNotEqual(matches.value as? String, shown, "more matches are shown")
    }

    /// No loaded message matches, but older history exists: the empty state says the search
    /// covered the recent messages and offers the older ones. "kickoff" is only in gx1, the
    /// last page; the button fetches (at most five pages) until it lands. With the whole
    /// history loaded, a query matching nothing is plain "No matches".
    func testNoRecentMatchesOffersToSearchOlderMessages() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 10), "the feed opens")
        Thread.sleep(forTimeInterval: 3)
        let pagesBefore = listPages(app)
        let field = openSearchField(app)
        field.tap()
        field.typeText("kickoff")
        XCTAssertTrue(app.staticTexts["No matches in recent messages"].waitForExistence(timeout: 5),
                      "no loaded match, older history left: say what was searched")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(listPages(app), pagesBefore, "the empty state fetches nothing by itself")
        let searchOlder = app.buttons["gram-search-older"]
        XCTAssertTrue(searchOlder.waitForExistence(timeout: 3))
        searchOlder.tap()
        let match = app.descendants(matching: .any)["gram-bubble-gx1"]
        XCTAssertTrue(match.waitForExistence(timeout: 10), "Search older messages should find the older match")
        XCTAssertGreaterThan(listPages(app), pagesBefore)

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5),
                      "with every page loaded, no match is the whole answer")
        XCTAssertFalse(app.buttons["gram-search-older"].exists, "and there is nothing older to search")
    }

    /// vetrina's report runs to 11 lines, past the 8-line fold, so it ends in "…" with a
    /// separate "Read more" line; tapping it shows the whole message (the bubble grows) and the
    /// line becomes "Show less", which folds it back.
    func testReadMoreExpandsALongMessageAndShowLessFoldsIt() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let readMore = app.buttons["gram-read-more"].firstMatch
        let showLess = app.buttons["gram-show-less"].firstMatch
        XCTAssertTrue(readMore.waitForExistence(timeout: 5), "a long report should fold with Read more")
        XCTAssertFalse(showLess.exists, "a folded report offers Read more, not Show less")
        // The feed opens at the newest message; on a phone the report can sit just above it.
        for _ in 0..<3 where !readMore.isHittable { app.swipeDown() }
        XCTAssertTrue(readMore.isHittable, "Read more should be reachable")

        // The report is exposed ONCE: the fold measures it with hidden copies, which must
        // not reach VoiceOver (they did once, and read the report three times).
        let prose = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Deployed."))
        XCTAssertEqual(prose.count, 1, "VoiceOver should meet the report once")
        let bubble = app.descendants(matching: .any)["gram-bubble-g4"]
        XCTAssertTrue(bubble.exists, "the folded report's bubble should be on screen")
        let folded = bubble.frame

        readMore.tap()
        XCTAssertTrue(showLess.waitForExistence(timeout: 3), "an expanded message offers Show less")
        XCTAssertFalse(readMore.exists, "an expanded message has no Read more")
        Thread.sleep(forTimeInterval: 0.4)   // the expand animates (0.2 s)
        // Three more 20 pt lines (the 15/20 body): the whole report, all 11 lines.
        XCTAssertGreaterThanOrEqual(bubble.frame.height, folded.height + 3 * 20 - 4,
                                    "the expanded report should show all 11 lines")
        // Like Messages, the bubble hugs its widest line, so it may widen; never narrower.
        XCTAssertGreaterThanOrEqual(bubble.frame.width, folded.width - 1, "expanding never narrows the bubble")

        attach(app, "gram-read-more-expanded")

        for _ in 0..<3 where !showLess.isHittable { app.swipeDown() }
        showLess.tap()
        XCTAssertTrue(readMore.waitForExistence(timeout: 3), "Show less folds the report back to Read more")
        XCTAssertFalse(showLess.exists, "a folded report has no Show less")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(bubble.frame.height, folded.height, accuracy: 2, "Show less folds back to 8 lines")
    }

    /// The label of the DEBUG `gram-post-calls` probe once it contains `expected`: the mock's
    /// recorded `gram.post` calls, one `to=<name|queue> text=<text>` per line ("none" before
    /// any). The label, not the value: on the iPhone tab the value reads the tab's badge.
    private func waitForPostCall(_ app: XCUIApplication, containing expected: String) -> String {
        let probe = app.descendants(matching: .any)["gram-post-calls"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG post probe should be present")
        let recorded = NSPredicate(format: "label CONTAINS %@", expected)
        let landed = waitForPredicate(recorded, object: probe, timeout: 5)
        XCTAssertTrue(landed, "the mock should record \"\(expected)\"; probe says \(probe.label)")
        return probe.label
    }

    /// Mock D: typing "@" lists the agents seen in Gram above the composer, typing narrows the
    /// list, and picking one puts "@vetrina " in the field. Sending posts to vetrina alone,
    /// with the leading mention taken off the text.
    func testAtMentionPicksAnAgentAndSendsToItAlone() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        let list = app.descendants(matching: .any)["gram-mention-list"]
        XCTAssertFalse(list.exists, "no list before an @")
        field.typeText("@")
        XCTAssertTrue(list.waitForExistence(timeout: 3), "typing @ lists the agents")
        XCTAssertTrue(app.staticTexts["Send to one agent"].exists, "the list says what picking does")
        XCTAssertTrue(app.staticTexts["No @ and it goes to the shared queue."].exists,
                      "the list reminds that no @ means the shared queue")
        let vetrina = app.buttons["gram-mention-vetrina"]
        // Two agents are called clientloop: the local one (sender ID "clientloop") and the one
        // relayed from hetzner-1. Both are listed, each under its own sender ID.
        let clientloop = app.buttons["gram-mention-clientloop"]
        let relayedClientloop = app.buttons["gram-mention-\(Self.relayedClientloop)"]
        XCTAssertTrue(vetrina.exists, "vetrina has messaged in Gram, so it is listed")
        XCTAssertTrue(clientloop.exists, "the local clientloop has messaged in Gram, so it is listed")
        XCTAssertTrue(relayedClientloop.exists, "the relayed clientloop is listed too, not merged into the local one")

        field.typeText("vet")
        XCTAssertTrue(clientloop.waitForNonExistence(timeout: 3), "\"vet\" filters clientloop out")
        XCTAssertTrue(vetrina.exists, "\"vet\" keeps vetrina")

        vetrina.tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 3), "picking an agent closes the list")
        XCTAssertEqual(field.value as? String, "@vetrina ", "picking completes the mention")

        field.typeText("Ship the drop")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isEnabled)
        send.tap()

        let calls = waitForPostCall(app, containing: "to=vetrina text=Ship the drop")
        XCTAssertFalse(calls.contains("@vetrina"), "the leading mention is not part of the text")
        XCTAssertFalse(calls.contains("to=queue"), "a mention never also posts to the queue")
    }

    /// The relayed clientloop's full sender ID in the mock (g2); the local one's is "clientloop".
    private static let relayedClientloop = "4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/clientloop"

    /// "@vetrina " with nothing after it has no message: Send shows but stays disabled.
    func testAMentionWithNoMessageCannotBeSent() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("@vet")
        let vetrina = app.buttons["gram-mention-vetrina"]
        XCTAssertTrue(vetrina.waitForExistence(timeout: 3))
        vetrina.tap()
        XCTAssertEqual(field.value as? String, "@vetrina ")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "a mention is content: send takes the saved-prompts place")
        XCTAssertFalse(send.isEnabled, "a mention alone has no message to send")
    }

    /// Two agents share the name clientloop. Typed, the name picks neither and Send stays off;
    /// picking the relayed one from the list sends to its full sender ID, never the local one.
    func testASharedNameSendsToTheAgentPicked() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // No space after the name, so autocorrect has nothing to act on.
        field.typeText("@clientloop")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "a typed name two agents share picks neither")

        let relayed = app.buttons["gram-mention-\(Self.relayedClientloop)"]
        XCTAssertTrue(relayed.waitForExistence(timeout: 3), "the list offers both clientloops")
        XCTAssertTrue(app.buttons["gram-mention-clientloop"].exists)
        XCTAssertTrue(relayed.label.contains("clientloop · hetzner-1"),
                      "a shared name is told apart by its machine; row reads \(relayed.label)")
        relayed.tap()
        XCTAssertEqual(field.value as? String, "@clientloop ")
        field.typeText("deploy?")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let calls = waitForPostCall(app, containing: "to=\(Self.relayedClientloop) text=deploy?")
        XCTAssertFalse(calls.contains("to=clientloop "), "the local clientloop must not get it")
    }

    /// The agents sheet addresses the exact agent: its relayed clientloop row sends to that
    /// agent's full sender ID, though a local agent has the same name.
    func testTheAgentsSheetSendsToTheExactAgent() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Status please")

        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()
        let row = app.buttons["gram-recipient-\(Self.relayedClientloop)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the sheet lists the relayed clientloop by its sender ID")
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "choosing an agent closes the sheet")
        XCTAssertEqual(field.value as? String, "@clientloop Status please",
                       "the sheet puts the agent's mention at the start")

        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isEnabled)
        send.tap()
        _ = waitForPostCall(app, containing: "to=\(Self.relayedClientloop) text=Status please")
    }

    /// A leading @name that names no agent in Gram is never sent to the shared queue: Send
    /// stays off and the composer says why.
    func testAnUnknownLeadingMentionBlocksSend() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // No space after the name, so autocorrect has nothing to act on.
        field.typeText("@nobody")
        let hint = app.staticTexts["gram-composer-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "the composer says why it cannot send")
        XCTAssertEqual(hint.label, "No agent called @nobody in Gram")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "an @name matching no agent must not fall back to the queue")
    }

    /// No "@" in the text: the post goes to the shared queue, text unchanged.
    func testSendingWithoutAMentionPostsToTheQueue() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Please review the docs")
        XCTAssertFalse(app.descendants(matching: .any)["gram-mention-list"].exists,
                       "no @, no agent list")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        _ = waitForPostCall(app, containing: "to=queue text=Please review the docs")
    }

    /// herdrup#455: a file whose post failed keeps its upload, so the one-tap retry posts the
    /// same bytes again instead of uploading them again (the terminal and guest composers
    /// already resumed; the Gram composer re-uploaded everything unsent).
    func testARetriedAttachmentPostsTheUploadItAlreadyHas() {
        let app = launchGram(environment: ["HERDR_MOCK_PICKED_FILE": "1", "HERDR_MOCK_GRAM_POST_FAIL": "1"])
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let paperclip = app.buttons["gram-attach-button"]
        XCTAssertTrue(paperclip.waitForExistence(timeout: 5))
        paperclip.tap()
        let file = app.buttons["composer-attach-file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), "the paperclip should open the attach sheet")
        file.tap()
        let chip = app.staticTexts["picked-notes.txt"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the picked file should stage a chip")
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Notes attached")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        _ = waitForPostCall(app, containing: "text=Notes attached file=picked-notes.txt@")
        XCTAssertTrue(app.staticTexts["The gram store is busy."].waitForExistence(timeout: 5),
                      "the refused post should say why")
        XCTAssertTrue(chip.exists, "the unsent file stays staged for the retry")

        send.tap()
        let probe = app.descendants(matching: .any)["gram-post-calls"].firstMatch
        let retried = NSPredicate(format: "label MATCHES %@", "(?s).*file=.*file=.*")
        XCTAssertTrue(waitForPredicate(retried, object: probe, timeout: 10),
                      "the retry should post again; probe says \(probe.label)")
        let uploads = probe.label.components(separatedBy: "\n")
            .compactMap { $0.components(separatedBy: " file=").dropFirst().first }
        XCTAssertEqual(uploads.count, 2, "\(probe.label)")
        XCTAssertEqual(uploads.first, uploads.last, "the retry posts the upload it already has: \(uploads)")
        XCTAssertTrue(poll(10, every: 0.25) { !chip.exists }, "a posted file leaves the strip")
    }

    /// The header floats over the feed with no band, but the feed's top stops below it: scrolled
    /// to the top, the oldest loaded message is clear of the header's controls and hittable.
    func testOldestMessageClearsTheFloatingHeaderAtTheTop() {
        let app = launchGram()
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let oldest = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Picked up the deploy ticket.")).firstMatch
        let oldestBubble = app.descendants(matching: .any)["gram-bubble-g9"]
        for _ in 0..<6 { feed.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.6)   // let the scroll settle
        XCTAssertTrue(oldest.waitForExistence(timeout: 3) && oldest.isHittable,
                      "at the top, the oldest loaded message is on screen and hittable")

        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.exists, "the floating header shows the Gram pill")
        XCTAssertGreaterThanOrEqual(oldestBubble.frame.minY, pill.frame.maxY,
                                    "at the top, the oldest message sits below the floating header")
        if hasSidebar {
            XCTAssertTrue(app.buttons["gram-saved-toggle"].exists,
                          "iPad/Mac float a Saved capsule at the header's right")
        }
    }

    /// The attachment card of message `id`: the whole card is its Open button.
    private func attachmentCard(_ app: XCUIApplication, message id: String) -> XCUIElement {
        app.descendants(matching: .any)["gram-bubble-\(id)"]
            .descendants(matching: .button)["gram-attachment-open"].firstMatch
    }

    /// clientloop's zip (g2): tapping anywhere on its card opens it, and the card carries no
    /// Open / Save to Files bar of its own.
    func testTappingAFileCardOpensIt() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g2")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the zip should draw as a file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        XCTAssertEqual(card.label, "Open amigo-poc-scaffold.zip", "the card is one button that opens the file")
        let bubble = app.descendants(matching: .any)["gram-bubble-g2"]
        XCTAssertEqual(bubble.descendants(matching: .button).matching(identifier: "gram-attachment-open").count, 1,
                       "one Open target: the card itself")
        XCTAssertFalse(app.descendants(matching: .any)["gram-attachment-save"].exists,
                       "Save to Files is no longer a button on the card")
        XCTAssertFalse(bubble.buttons["Open"].exists, "no separate Open button")

        card.tap()
        let probe = app.descendants(matching: .any)["gram-opened-file"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG opened-file probe should be present")
        let opened = NSPredicate(format: "label BEGINSWITH %@", "opened:")
        XCTAssertTrue(waitForPredicate(opened, object: probe, timeout: 10),
                       "tapping the card should download the file and hand it to a viewer; probe says \(probe.label)")
    }

    /// Long-pressing the file card offers Save to Files in the message's menu, beside the
    /// message's own actions (one menu, not two).
    func testLongPressingAFileCardOffersSaveToFiles() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g2")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the zip should draw as a file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }

        card.press(forDuration: 1.2)
        let save = app.buttons["Save to Files"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the card's menu should offer Save to Files")
        XCTAssertTrue(app.buttons["Delete"].firstMatch.exists, "the same menu keeps the message's actions")
    }

    /// herdr#298: a file the store expired keeps its message. trend-scout's caption-less
    /// chart (g12) draws as just the expired card, never an empty bubble; its export (g11)
    /// draws the card under its text. The card names the file and says it is no longer
    /// available; it is not a button, has no Open or Save to Files, and tapping it fetches
    /// nothing.
    func testAnExpiredAttachmentDrawsAsAnInertCard() {
        let app = launchGram()
        let bubble = app.descendants(matching: .any)["gram-bubble-g12"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the file-only expired message should draw")
        let card = bubble.descendants(matching: .any)["gram-attachment-expired"].firstMatch
        reveal(card, in: app, older: true)
        XCTAssertTrue(card.exists && card.isHittable, "the expired file should draw as a card on screen")
        XCTAssertEqual(card.label, "trend-chart.png, no longer available")
        XCTAssertNotEqual(card.elementType, .button, "an expired file is not a button")
        XCTAssertEqual(bubble.descendants(matching: .button).count, 0, "nothing in the expired card opens")
        XCTAssertFalse(bubble.descendants(matching: .any)["gram-image-preview-g12"].exists,
                       "an expired image draws no picture card")
        // Not an empty bubble: the message is the card alone (its padded box holds the name
        // and status lines, the element's frame), with no second, empty bubble beside it.
        XCTAssertGreaterThan(card.frame.height, 30, "the card draws its name and status")
        XCTAssertTrue(bubble.frame.insetBy(dx: -1, dy: -1).contains(card.frame), "the card is the message's bubble")
        XCTAssertLessThan(bubble.frame.height, card.frame.height + 30,
                          "the file-only message is the card alone, with no empty bubble beside it")

        let withText = app.descendants(matching: .any)["gram-bubble-g11"]
        XCTAssertTrue(withText.waitForExistence(timeout: 5))
        let textCard = withText.descendants(matching: .any)["gram-attachment-expired"].firstMatch
        XCTAssertTrue(textCard.exists, "the expired file draws under its message's text")
        XCTAssertEqual(textCard.label, "trend-export.csv, no longer available")
        XCTAssertTrue(withText.staticTexts["Raw export of the run, for the record."].exists,
                      "the message's own text stays")
        XCTAssertEqual(withText.descendants(matching: .button).matching(identifier: "gram-attachment-open").count, 0)

        let calls = probe(app, "gram-get-file-calls")
        card.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(waitForGetFileCalls(calls, "g12", 0, timeout: 0.5),
                      "tapping the expired card fetches nothing; probe says \(calls.label)")
        XCTAssertTrue(waitForGetFileCalls(calls, "g11", 0, timeout: 0.5),
                      "the expired export is never fetched; probe says \(calls.label)")
        XCTAssertFalse(probe(app, "gram-opened-file").label.hasPrefix("opened:"), "tapping it opens nothing")

        card.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 5),
                      "the message's own menu stays")
        XCTAssertFalse(app.buttons["Save to Files"].exists, "an expired file has nothing to save")
        XCTAssertFalse(app.buttons["Open"].exists, "an expired file has nothing to open")
    }

    /// A message saved while its file was live, whose file the store expires afterwards
    /// (`HERDR_MOCK_GRAM_EXPIRE_SAVED`: the next `gram.list` answers a saved g2 with its zip as
    /// `expired_file`): once the inbox load brings the expiry, the Saved copy shows the
    /// non-interactive expired chip, not the old Open chip, and tapping it fetches nothing.
    func testASavedCopyStopsOfferingAFileTheStoreExpired() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_EXPIRE_SAVED": "1"])
        let card = attachmentCard(app, message: "g2")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "precondition: the zip is a live file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        card.press(forDuration: 1.2)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the message menu offers Save")
        save.tap()

        // The next poll answers g2 with its file expired; the inbox redraws it as such.
        let bubble = app.descendants(matching: .any)["gram-bubble-g2"]
        let inboxExpired = bubble.descendants(matching: .any)["gram-attachment-expired"].firstMatch
        XCTAssertTrue(inboxExpired.waitForExistence(timeout: 15), "the mock should expire the saved message's file")

        let toggle = app.buttons["gram-saved-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        // The one saved message: its row folds into the feed's element, so look in the feed.
        let saved = app.scrollViews["gram-saved-feed"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the Saved feed should show")
        XCTAssertTrue(saved.staticTexts["hetzner-1/clientloop"].waitForExistence(timeout: 5),
                      "Saved should hold the copy of g2")
        let chip = saved.descendants(matching: .any)["gram-attachment-expired"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "the saved copy should show the file as expired")
        XCTAssertEqual(chip.label, "amigo-poc-scaffold.zip, no longer available")
        XCTAssertNotEqual(chip.elementType, .button, "an expired file is not a button")
        XCTAssertEqual(saved.buttons.matching(NSPredicate(format: "label CONTAINS %@", "amigo-poc-scaffold.zip")).count, 0,
                       "the saved copy no longer offers the file to open")

        let calls = probe(app, "gram-get-file-calls")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(waitForGetFileCalls(calls, "g2", 0, timeout: 0.5),
                      "tapping the expired chip fetches nothing; probe says \(calls.label)")
        chip.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Open"].waitForExistence(timeout: 2), "an expired file has nothing to open")
        XCTAssertFalse(app.buttons["Save to Files…"].exists, "an expired file has nothing to save")
    }

    /// Saving a message from its menu redraws that row with the saved badge, and unsaving
    /// removes it. Guards GramRow's `==`: a row that skipped `isSaved` would stay stale.
    func testSavingAMessageRedrawsItsBadge() {
        // A Gram pass at every touch-down (as a poll landing mid-tap): the open menu must
        // still take the tap (#437).
        let app = launchGram(environment: ["HERDR_REDRAW_ON_TOUCH": "1"])
        let bubble = app.descendants(matching: .any)["gram-bubble-g1"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the newest message should draw")
        let badge = bubble.descendants(matching: .any)["gram-saved-badge"]
        XCTAssertFalse(badge.exists, "precondition: not saved")

        bubble.press(forDuration: 1.2)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the message menu offers Save")
        save.tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 3), "a saved message shows its badge")

        bubble.press(forDuration: 1.2)
        let unsave = app.buttons["Unsave"].firstMatch
        XCTAssertTrue(unsave.waitForExistence(timeout: 5), "a saved message's menu offers Unsave")
        unsave.tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 3), "unsaving removes the badge")
    }

    /// A DEBUG probe element by identifier (its state is in its label).
    private func probe(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits until `element`'s label matches the regular expression `pattern`.
    private func waitForLabel(_ element: XCUIElement, matching pattern: String, timeout: TimeInterval) -> Bool {
        waitForPredicate(NSPredicate(format: "label MATCHES %@", pattern), object: element, timeout: timeout)
    }

    /// Waits until the feed's message stack (`gram-feed-messages`) reports `count` loaded messages.
    private func waitForCount(_ messages: XCUIElement, _ count: Int, timeout: TimeInterval) -> Bool {
        let loaded = NSPredicate(format: "value == %@", "\(count) messages")
        return waitForPredicate(loaded, object: messages, timeout: timeout)
    }

    /// Polls rather than using XCTest's asynchronous waiter, which can time out during a slow
    /// accessibility query even when the observed state already matches.
    private func waitForPredicate(_ matches: NSPredicate, object: Any?, timeout: TimeInterval) -> Bool {
        poll(timeout, every: 0.2) { matches.evaluate(with: object) }
    }

    /// Waits until `gram-get-file-calls` reports `count` `gram.get_file` calls for `id` (the
    /// label reads e.g. "g2=0 g3=1"). Polls the label directly: a predicate waiter with a
    /// regex re-checked too rarely for these short windows and failed on a matching label.
    private func waitForGetFileCalls(_ probe: XCUIElement, _ id: String, _ count: Int,
                                     timeout: TimeInterval) -> Bool {
        let wanted = "\(id)=\(count)"
        return poll(timeout, every: 0.2) { probe.label.split(separator: " ").contains(Substring(wanted)) }
    }

    /// Scrolls the feed until `element` is on screen below the floating header (the header is
    /// see-through: a row behind it is "hittable" for XCUITest but not visible, and the app
    /// rightly does not count it as seen). Down for older rows, up for newer.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, older: Bool) {
        let feed = app.scrollViews["gram-feed"]
        let header = app.descendants(matching: .any)["gram-header-pill"]
        func shown() -> Bool {
            guard element.isHittable else { return false }
            let headerBottom = header.exists ? header.frame.maxY : feed.frame.minY
            return element.frame.minY >= headerBottom && element.frame.maxY <= feed.frame.maxY
        }
        for _ in 0..<12 where !shown() {
            if older { feed.swipeDown(velocity: .slow) } else { feed.swipeUp(velocity: .slow) }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// vetrina's image (g3) shows its picture without a tap: the card fetches it through the
    /// download cache while on screen and decodes a preview (the DEBUG
    /// `gram-image-preview-g3` probe says "placeholder" / "preview").
    func testImageCardShowsAPreviewWithoutOpening() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the image should draw as an image card")
        XCTAssertEqual(card.label, "Open vetrina-live.png, 412 KB")
        reveal(card, in: app, older: true)
        let preview = probe(app, "gram-image-preview-g3")
        XCTAssertTrue(waitForLabel(preview, matching: "preview", timeout: 8),
                      "the image card should decode its preview on its own; probe says \(preview.label)")
        attach(app, "gram-image-preview")
    }

    /// Opening an image whose preview already landed opens the cached file: the daemon is
    /// asked for g3 once, by the prefetch, never again by the open.
    func testOpeningAPreviewedImageDoesNotFetchItAgain() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the image should draw as an image card")
        reveal(card, in: app, older: true)
        XCTAssertTrue(waitForLabel(probe(app, "gram-image-preview-g3"), matching: "preview", timeout: 8),
                      "the preview should land first")
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 3),
                      "the prefetch fetched g3 once; probe says \(calls.label)")

        card.tap()
        let opened = probe(app, "gram-opened-file")
        XCTAssertTrue(waitForLabel(opened, matching: "opened:vetrina-live\\.png", timeout: 5),
                      "tapping the card should open the image; probe says \(opened.label)")
        // Past the probe's poll, so a second fetch would show.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 1),
                      "the open must reuse the cached file, not fetch it again; probe says \(calls.label)")
    }

    /// #451: closing the HTML/SVG viewer must leave the download cache alone. A cached open
    /// hands the viewer the cache entry itself, and the viewer used to delete its file on
    /// close, so every reopen fetched the report again (`HERDR_MOCK_GRAM_HTML`: gh1 is an
    /// HTML file). Opened, closed, opened again: the daemon is asked for gh1 once.
    func testClosingTheHtmlViewerKeepsTheCachedFile() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_HTML": "1"])
        let card = attachmentCard(app, message: "gh1")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the HTML file should draw as a file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        let done = app.buttons["Done"].firstMatch
        let gone = NSPredicate(format: "exists == false")
        for open in 1...2 {
            card.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10),
                          "open \(open): the report should show in the web viewer")
            done.tap()
            XCTAssertTrue(waitForPredicate(gone, object: done, timeout: 5),
                          "open \(open): Done should close the viewer")
        }
        let opened = probe(app, "gram-opened-file")
        XCTAssertEqual(opened.label, "opened:run-report.html")
        // Past the probe's poll, so a second fetch would show.
        Thread.sleep(forTimeInterval: 1)
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "gh1", 1, timeout: 1),
                      "the reopen must use the cached file, not fetch it again; probe says \(calls.label)")
    }

    /// The feed is an eager stack, so a drawn row exists whether it is seen or not: the
    /// image card must fetch only once it is really on screen. Fourteen newer messages
    /// (`HERDR_MOCK_GRAM_NEWER`) put g3 above the fold, inside a window that draws it.
    func testAnImageCardAboveTheFoldFetchesOnlyOnceScrolledIntoView() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_NEWER": "1", "HERDR_GRAM_RENDER_WINDOW": "200"])
        let newest = app.descendants(matching: .any)["gram-bubble-gn14"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the newer messages should load")
        let landed = NSPredicate(format: "hittable == true")
        XCTAssertTrue(waitForPredicate(landed, object: newest, timeout: 5), "the feed opens at the newest message")
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.exists, "the image row is drawn")
        XCTAssertFalse(card.isHittable, "precondition: the image sits above the fold")

        // Past the landing, the prefetch delay and the probe's poll.
        Thread.sleep(forTimeInterval: 2)
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 0, timeout: 1),
                      "an image card off screen must not fetch; probe says \(calls.label)")

        reveal(card, in: app, older: true)
        XCTAssertTrue(card.isHittable, "scrolling up should bring the image on screen")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 5),
                      "on screen, the card fetches its preview once; probe says \(calls.label)")
        XCTAssertTrue(waitForLabel(probe(app, "gram-image-preview-g3"), matching: "preview", timeout: 8),
                      "and draws it")
    }

    /// A prefetch never holds up an open: with g3's download held in flight for 10 s
    /// (`HERDR_MOCK_GRAM_FILE_DELAY`), opening the zip (g2) still opens it at once.
    func testAPrefetchDoesNotBlockOpeningAnotherFile() {
        // Held for 10 minutes, i.e. for the whole test: a slow CI runner took ~90 s to scroll
        // the image into view (run 38629962966), longer than the earlier 60 s hold, and the
        // preview landed before the precondition check. The test ends when the zip opens.
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_FILE_DELAY": "g3=600"])
        let image = attachmentCard(app, message: "g3")
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the image should draw as an image card")
        reveal(image, in: app, older: true)
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 5),
                      "the image's prefetch should be in flight; probe says \(calls.label)")
        XCTAssertEqual(probe(app, "gram-image-preview-g3").label, "placeholder",
                       "precondition: the held download has not landed")

        let file = attachmentCard(app, message: "g2")
        reveal(file, in: app, older: false)
        file.tap()
        let opened = probe(app, "gram-opened-file")
        XCTAssertTrue(waitForLabel(opened, matching: "opened:.+", timeout: 4),
                      "the zip should open while the image is still downloading; probe says \(opened.label)")
        XCTAssertTrue(waitForGetFileCalls(calls, "g2", 1, timeout: 2),
                      "the open fetched the zip itself; probe says \(calls.label)")
    }

    /// #574: a download started in Gram keeps going while the reader is on Agents. The zip
    /// (g2) is held in flight for 20 s (`HERDR_MOCK_GRAM_FILE_DELAY`); the reader opens it,
    /// goes to Agents (the phone's tab bar, the iPad's sidebar) and comes back. The card's
    /// ring is still there, the file opens when its bytes land, and the daemon was asked for
    /// it ONCE: the page going off screen used to cancel the download, so it never landed and
    /// the reader had to tap again, which asked again.
    func testADownloadKeepsGoingWhileTheReaderIsOnAgents() {
        // The hold must outlast every step before the return to Gram below (up to ~32 s of
        // waits on a slow runner), or the download finishes first and the card rightly shows
        // the file, not the ring (failed that way on two CI runs at 20 s).
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_FILE_DELAY": "g2=60"])
        let file = attachmentCard(app, message: "g2")
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the zip should draw as a file card")
        reveal(file, in: app, older: false)
        file.tap()
        let downloading = NSPredicate(format: "value BEGINSWITH %@", "Downloading")
        XCTAssertTrue(waitForPredicate(downloading, object: file, timeout: 5),
                      "the card should show its download; value \(file.value ?? "nil")")
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g2", 1, timeout: 5),
                      "the open asked the daemon for the zip; probe says \(calls.label)")

        // The phone's tab bar, or the iPad's sidebar (where the page is rebuilt per section).
        let sections: XCUIElement = hasSidebar ? app : app.tabBars.firstMatch
        let agents = sections.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.tap()
        let covered = NSPredicate(format: "exists == false OR hittable == false")
        XCTAssertTrue(waitForPredicate(covered, object: file, timeout: 5), "Agents should cover Gram")
        // Long enough for the page's teardown to have run, well inside the 60 s hold.
        Thread.sleep(forTimeInterval: 2)
        sections.buttons["Gram"].firstMatch.tap()

        XCTAssertTrue(file.waitForExistence(timeout: 10), "back on Gram, the zip's card is drawn")
        XCTAssertTrue(waitForPredicate(downloading, object: file, timeout: 5),
                      "back on Gram, the download's ring is on the card again; value \(file.value ?? "nil")")
        let opened = probe(app, "gram-opened-file")
        // Any name: the mock answers every non-image file with the same fixture.
        XCTAssertTrue(waitForLabel(opened, matching: "opened:.+", timeout: 80),
                      "the download should finish and open the zip; probe says \(opened.label)")
        // Past the probe's poll, so a second request would show.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(waitForGetFileCalls(calls, "g2", 1, timeout: 1),
                      "the download must not have started again; probe says \(calls.label)")
        attach(app, "gram-download-after-agents")
    }

    /// iPad/Mac: the sidebar lists Gram's two conversations, Gram selected, and selecting Saved
    /// swaps the feed in place (the mock inbox's senders leave; Saved holds only local copies,
    /// and no test saves one). Selecting Gram brings them back.
    func testSidebarConversationsSwitchTheFeed() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone,
                      "the conversation rows are the iPad/Mac sidebar's; iPhone has no sidebar")
        let app = launchGram()

        let gram = app.buttons["gram-conversation-gram"]
        let saved = app.buttons["gram-conversation-saved"]
        XCTAssertTrue(gram.waitForExistence(timeout: 10), "the sidebar should list the Gram conversation")
        XCTAssertTrue(saved.exists, "the sidebar should list the Saved conversation")
        XCTAssertTrue(gram.isSelected, "Gram is the conversation shown at first")
        XCTAssertFalse(saved.isSelected)
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10),
                      "the Gram feed shows the mock inbox")

        saved.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForNonExistence(timeout: 5),
                      "selecting Saved should replace the Gram feed")
        XCTAssertTrue(saved.isSelected, "Saved should read as selected")
        XCTAssertFalse(gram.isSelected)

        gram.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "selecting Gram should bring the feed back")
        XCTAssertTrue(gram.isSelected)
    }

    /// Reported on TestFlight 170: the keyboard could not be dismissed from the composer.
    /// Whenever a full software keyboard is on screen the composer must offer the button,
    /// and tapping it must put the keyboard away.
    func testFullSoftwareKeyboardCanBeDismissedFromComposer() throws {
        let app = launchGram()
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no full software keyboard on this destination; nothing to dismiss")
        }
        let collapse = app.buttons["Collapse keyboard"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "a visible software keyboard must be dismissible")
        collapse.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the collapse button puts the keyboard away")
    }

    /// A reader at the newest message who starts typing stays there, as in Messages: the
    /// keyboard shrinks the feed, and the newest message must stay visible above the composer
    /// (not slide under it, and no "New messages" pill when nothing arrived).
    func testReaderAtTheBottomStaysThereWhenTheKeyboardComesUp() throws {
        let app = launchGram()
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(newest.isHittable, "the feed opens at the newest message")
        let field = app.textViews["gram-composer-input"]
        field.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no software keyboard on this destination: the feed does not shrink")
        }
        field.typeText("ok")
        let card = app.descendants(matching: .any)["composer-card"].firstMatch
        let settled = NSPredicate { _, _ in newest.isHittable && newest.frame.maxY <= card.frame.minY + 1 }
        XCTAssertTrue(waitForPredicate(settled, object: nil, timeout: 3),
                       "the newest message should stay visible above the composer")
        XCTAssertFalse(app.buttons["gram-new-messages"].exists, "nothing new arrived: no pill")
    }

    func testComposerStartsAsOneRowThenDropsToToolbarAndScrolls() {
        let app = launchGram()

        let field = app.textViews["gram-composer-input"]
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("one")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        let oneLine = field.frame
        let sendBottom = send.frame.maxY
        XCTAssertEqual(oneLine.midY, send.frame.midY, accuracy: 4,
                       "a one-line message shares a single row with the send button")
        // No dead strip above a one-row composer (review f1 on #297 suspected an empty
        // attachment slot added 8 points; it does not, and this keeps it that way).
        let card = app.descendants(matching: .any)["composer-card"].firstMatch
        XCTAssertTrue(card.exists)
        XCTAssertLessThanOrEqual(card.frame.height - send.frame.height, 13,
                                 "a one-row composer is the button row plus its padding, with no dead space")

        field.typeText("\ntwo\nthree")
        Thread.sleep(forTimeInterval: 0.6)
        let threeLines = field.frame
        XCTAssertGreaterThan(threeLines.height, oneLine.height)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertLessThanOrEqual(threeLines.maxY, send.frame.minY + 1,
                                 "wrapped text moves above a toolbar holding the buttons")
        XCTAssertTrue(send.isHittable)
        attach(app, "gram-composer-three-lines")

        // The pull-to-expand editor: the handle appears at three lines, a tap opens a
        // taller editor above a fixed send button, and a second tap closes it.
        let handle = app.descendants(matching: .any)["composer-expand-handle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 3), "three lines offer the expand handle")
        handle.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(field.frame.height, threeLines.height + 20, "tapping the handle opens the editor")
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2, "opening the editor does not move send")
        attach(app, "gram-composer-editor")
        handle.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(field.frame.height, threeLines.height, accuracy: 2, "a second tap closes it")

        field.typeText("\nfour\nfive")
        Thread.sleep(forTimeInterval: 0.6)
        let fiveLines = field.frame
        XCTAssertGreaterThan(fiveLines.height, threeLines.height)
        field.typeText("\nsix\nseven")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(field.frame.height, fiveLines.height, accuracy: 2,
                       "past five lines the text scrolls instead of growing")
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("seven") == true)
        XCTAssertTrue(send.isHittable)
    }
}
