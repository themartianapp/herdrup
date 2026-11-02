import XCTest
import UIKit

/// Receipts for the Settings switches that change how the app treats data it did not
/// author. The DEFAULT of the JavaScript switch is pinned on Linux
/// (`WebViewPolicyTests.testJavaScriptIsOffUntilTheSettingIsTurnedOn`), because
/// `@AppStorage` survives between simulator launches, so a UI test cannot honestly
/// claim to observe a fresh install.
final class SettingsTests: XCTestCase {
    func testCompactSettingsSurviveResizeAndResume() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Exercises the iPad split-to-compact transition")
        }
        continueAfterFailure = false
        let app = XCUIApplication.launched(mock: "list")
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let initialSize = window.frame.size
        if window.frame.width > 600 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65)))
        }
        // Check process state before queries/activate can relaunch a crashed app.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        window.waitForSettledFrame()
        attach(app, "settings-first-settled-width-\(Int(window.frame.width))")
        // iPadOS can settle a corner drag out of full screen at a system window size just over
        // 600 pt (CI run 39966934030 stopped at 613 pt, #491), so Settings would never be
        // compact. Drag this window's own corner once more, to 480 pt from its left edge.
        if window.frame.width >= 600 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 480, dy: window.frame.height - 20)))
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            window.waitForSettledFrame()
        }
        XCTAssertLessThan(window.frame.width, 600, "The regression must exercise compact Settings")
        app.buttons["Settings"].firstMatch.tap()
        let machines = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Machines")).firstMatch
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        XCTAssertTrue(machines.isHittable)
        XCUIDevice.shared.press(.home)
        XCTAssertNotEqual(app.state, .notRunning, "Settings must not crash during the Home transition")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        XCTAssertTrue(machines.isHittable)
        machines.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        attach(app, "settings-compact-resumed-width-\(Int(window.frame.width))")
        back.tap()
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        XCTAssertTrue(machines.isHittable)
        // iPadOS resizes this floating window around its centre: a 275-point handle
        // movement widened 375 to 915, moving both edges. Request half the width delta.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: (window.frame.width + 650) / 2,
                                     dy: window.frame.height)))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        window.waitForSettledFrame()
        XCTAssertGreaterThanOrEqual(window.frame.width, 600)
        XCTAssertLessThan(window.frame.width, 800)
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        XCTAssertTrue(machines.isHittable, "Narrow regular width must keep Settings navigation reachable")
        attach(app, "settings-narrow-regular-width-\(Int(window.frame.width))")
        // Returning to full width must preserve that navigation too.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: max(initialSize.width, 900) - 50,
                                     dy: max(initialSize.height, 700) - 50)))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        window.waitForSettledFrame()
        XCTAssertGreaterThanOrEqual(window.frame.width, 800,
                                    "The final resize must leave the narrow regular-width range")
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        XCTAssertTrue(machines.isHittable)
        attach(app, "settings-expanded-width-\(Int(window.frame.width))")
    }


    /// The switch exists and its explanation tracks it: with script ON the row must say
    /// scripts will run, with it OFF that they are ignored. A reader flipping this is
    /// loosening how an attachment somebody else wrote gets rendered, so the screen has
    /// to state which of the two it is doing — silently changing is the failure.
    ///
    /// Drives both directions from whatever state the simulator was left in, and leaves
    /// it OFF, so neither the assertion nor a later test depends on run order.
    func testJavaScriptPreviewSwitchFlipsAndExplainsItself() {
        let app = XCUIApplication.launched(mock: "settings")

        // Proposal B (#572): the switch is an inline row of the root's Preferences group,
        // its explanation the row's subtitle.
        let heading = app.staticTexts["PREFERENCES"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Settings should carry a Preferences group")

        let row = app.staticTexts["Run JavaScript in previews"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        var scrolls = 0
        while !app.frame.contains(row.frame), scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }

        let willRun = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "will run")).firstMatch
        let ignored = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "are ignored")).firstMatch

        if !willRun.exists { row.tap() }
        XCTAssertTrue(willRun.waitForExistence(timeout: 5),
                      "turning the switch on must say scripts will run")

        row.tap()
        XCTAssertTrue(ignored.waitForExistence(timeout: 5),
                      "and turning it off must say they are ignored")
    }

    /// THE BEHAVIOUR, not the copy: a received document whose script rewrites the page
    /// is rendered by the shipping viewer, and what the page ends up SAYING is the
    /// answer. With the switch off the script must not have run.
    ///
    /// The value is forced through the argument domain rather than left to whatever a
    /// previous run on this simulator stored, so each direction is deterministic. The
    /// DEFAULT — an absent key — is pinned on Linux, where a fresh `UserDefaults` suite
    /// can actually be created.
    func testAPreviewedScriptDoesNotRunWhenTheSwitchIsOff() {
        let app = launchPreview(javaScript: false)
        XCTAssertTrue(app.webViews.staticTexts["script did not run"].waitForExistence(timeout: 20),
                      "the document must render unexecuted")
        XCTAssertFalse(app.webViews.staticTexts["script ran"].exists,
                       "and the script must not have rewritten it")
    }

    /// And the switch has to actually reach the viewer: with it on, the same document
    /// rewrites itself. Without this direction the test above would pass just as well
    /// against a viewer that ignored the setting entirely.
    func testAPreviewedScriptRunsWhenTheSwitchIsOn() {
        let app = launchPreview(javaScript: true)
        XCTAssertTrue(app.webViews.staticTexts["script ran"].waitForExistence(timeout: 20),
                      "turning the switch on must let the document's script run")
    }

    private func launchPreview(javaScript: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "htmlpreview"
        app.launchArguments += ["-previews.javascript", javaScript ? "YES" : "NO"]
        app.launch()
        return app
    }
    /// THE DISCORD ROW RENDERS IN THE REAL SETTINGS SCREEN, which is the half a font test
    /// cannot reach.
    ///
    /// The icon is Discord's official asset from an imageset, so there is no font glyph
    /// left to assert on — an earlier font test pinning U+F1FF was deleted with the glyph
    /// it covered, since a test that pins something the app no longer draws is worse than
    /// no test. What remains worth proving is that this row is BUILT and REACHABLE, which
    /// only the real screen can answer: this drives the shipping `SettingsView` under the
    /// settings mock and asserts the row exists, sits ON SCREEN, and announces itself as
    /// Discord.
    ///
    /// A missing asset is NOT detectable here: SwiftUI renders an absent `Image("…")` as
    /// empty space inside the same element tree, and the chip is `accessibilityHidden`, so
    /// no query can see it. The attached screenshot is the only evidence for the mark
    /// itself, which is why it is attached unconditionally.
    ///
    /// GEOMETRY, NOT `isHittable`, and not `exists` as a scroll condition. In an eager
    /// `VStack` inside a `ScrollView`, `exists` is true for nodes below the fold, so a
    /// loop keyed on it can swipe zero times and then interrogate a row parked outside the
    /// viewport — where this repo has already documented `isHittable` raising "Activation
    /// point invalid" rather than answering false (see `TerminalInteractionTestCase`).
    /// So the loop scrolls until the row's frame lies inside the app frame, and that
    /// containment IS the assertion.
    ///
    /// It deliberately does NOT tap: the tap hands off to Safari, and asserting on another
    /// app's state would be a receipt about `SafariViewController`. The invite is a single
    /// constant, so a tap proves nothing that reading it does not.
    ///
    /// The glyph's appearance stays unverifiable here for an honest reason: XCUITest
    /// cannot read a rendered outline, so the mark and a missing-glyph box are the same
    /// element tree. The screenshot is attached for a human to judge.
    func testTheDiscordRowIsPresentAndOnScreen() {
        let app = XCUIApplication.launched(mock: "settings")

        let row = app.buttons["settings-discord"]
        guard row.waitForExistence(timeout: 15) else {
            return XCTFail("Settings should build the Discord row in its ABOUT section")
        }
        // Scroll on CONTAINMENT, not existence: the row can exist below the fold.
        var scrolls = 0
        while !app.frame.contains(row.frame), scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }

        attach(app, "settings-about-discord")

        XCTAssertTrue(
            app.frame.contains(row.frame),
            "the Discord row never came fully on screen after \(scrolls) swipes (row \(row.frame), app \(app.frame))")
        XCTAssertTrue(
            row.label.contains("Discord"),
            "the row must announce itself as Discord, not read out a private-use codepoint (got: \(row.label))")
    }


    /// GEOMETRY, because the defect was geometric and every text assertion passed
    /// through it. An exhausted account that also reports usage — the common case, since
    /// reaching 100% is what exhausts it — put the meters and the status pill on one
    /// line. `Text("exhausted")` had no line limit, so it wrapped to one letter per
    /// line into a ~9-line red capsule that doubled the row height, and the width it
    /// claimed squeezed "Claude Pro (personal)" down to "C…".
    ///
    /// Accessibility labels are unaffected by truncation, so a `staticTexts["..."]`
    /// existence check reports success on the broken layout. What separates the two is
    /// the rendered FRAME: the pill's height, and the label's width.
    ///
    /// The mock's `acc-claude-2` is exactly this case (active false, both windows at
    /// 100%), which is why this is checkable at all.
    func testAnExhaustedAccountRowKeepsItsShape() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "settings"
        // TEXT SCALE PINNED. `ui.fontScale` is @AppStorage and survives between simulator
        // launches, so without this the measurements below depend on whatever a previous
        // run left behind — at scale 1.2 the same correct layout measures 0.136.
        app.launchArguments += ["-ui.fontScale", "1.0"]
        app.launch()

        let accountsRow = app.staticTexts["Accounts"]
        XCTAssertTrue(accountsRow.waitForExistence(timeout: 15), "Settings should list Accounts")
        accountsRow.tap()

        let pill = app.staticTexts["exhausted"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the exhausted account must show its status")

        let exhaustedRow = app.staticTexts["Claude Pro (personal)"]
        XCTAssertTrue(exhaustedRow.waitForExistence(timeout: 5))

        // THE PILL MUST BE ONE LINE, expressed against a known single line of text rather
        // than a point constant. The bug wrapped "exhausted" to one letter per line into a
        // ~9-line capsule; the label beside it is always one line, so a pill more than
        // three label-heights tall is wrapped whatever the device or text size.
        XCTAssertLessThan(
            pill.frame.height, exhaustedRow.frame.height * 3,
            """
            the pill is \(pill.frame.height)pt against a \(exhaustedRow.frame.height)pt             single-line label, so it wrapped instead of keeping its intrinsic width.
            """)

        // COMPARE THE TWO ROWS, not the window. Fourth calibration of this gate, and the
        // first that is device-free — because a share-of-window gate CANNOT work: the
        // name saturates at its 136.25pt intrinsic width, so the correct layout's share
        // falls as 1/W and goes red above ~505pt. The review measured the correct layout
        // at 0.183 on a 744pt iPad and 0.132 at 1032pt — the iPad Pro ci.yml:167-170
        // deliberately selects — and at 320pt iPad Slide Over. My width-bucket table
        // passed every phone and would have failed every iPad.
        //
        // The two labels this test already holds are enough — with ONE premise, which is
        // now asserted rather than assumed.
        //
        // `acc-claude-2` carries no resets_at, so its meter has no reset hint and its row
        // is identical in the correct layout and in the `mid` one (125.80pt cluster in
        // both). That is what makes it usable as a yardstick. Two honest caveats the
        // review established:
        //
        //  * it is NOT invariant in the `base` layout (158.71pt there, because the status
        //    sat beside the meters and the pill compressed this row too). The gate still
        //    catches `base` on phones, but because BOTH rows compress and the name
        //    compresses harder — 20.40pt against 68.29pt at 375pt — not because the
        //    denominator held still.
        //  * if that fixture ever gains a resets_at — the production-NORMAL case for an
        //    exhausted account — the yardstick compresses too and the ratio rises to
        //    ~1.08, which would BLIND this gate silently. So the premise is pinned below:
        //    the yardstick's readout must be exactly "100% · weekly", with no hint.
        //
        // Executed ratios of name / yardstick:
        //
        //   correct  0.842 … 0.886 across 375-440pt, and 0.871 at 820 and 1032
        //   mid      0.379 … 0.661   (readout rigid)
        //   base     0.202 … 0.546   (the reported bug)
        //
        // 0.70 rather than the 0.75 the review suggested: if SwiftUI's minimum for the
        // truncating hint is the longest word rather than one ellipsis cell, the correct
        // ratio at 375pt is 0.711, which 0.75 would fail. 0.70 survives both models.
        //
        // The margin against `mid` at 440pt is only 0.92 of one IBM Plex Mono cell, so it
        // depends on the mock's reset hint staying two tokens long. That is exactly why
        // the premise assertion below exists: a fixture change breaks the test loudly
        // instead of quietly disarming it.
        //
        // Above ~472pt all three layouts converge, which is honest: nothing truncates
        // there, so there is no defect to detect.
        XCTAssertTrue(
            app.staticTexts["100% · weekly"].waitForExistence(timeout: 5),
            """
            the yardstick row's readout is not exactly "100% · weekly" any more, so \
            `acc-claude-2` has gained a reset hint and the ratio gate below is no longer \
            discriminating — re-derive it before trusting a green result.
            """)

        // NAMES, not "widest"/"short": at 15pt Geist-SemiBold "Claude Max (work)" is
        // 136.25pt and "Claude Pro (personal)" is 156.38pt, so the row this gate measures
        // is the NARROWER of the two and a fully healthy render tops out at 0.871.
        let measuredName = app.staticTexts["Claude Max (work)"]
        XCTAssertTrue(measuredName.waitForExistence(timeout: 5))
        let yardstick = exhaustedRow
        let ratio = measuredName.frame.width / yardstick.frame.width
        XCTAssertGreaterThan(
            ratio, 0.70,
            """
            "Claude Max (work)" rendered at \(Int(ratio * 100))% of the unsqueezed \
            "Claude Pro (personal)" row (\(measuredName.frame.width)pt vs \
            \(yardstick.frame.width)pt, healthy ceiling 87%), so the trailing cluster \
            squeezed the name column — this is what showed as "C…".
            """)

        // THE WINDOW LABEL MUST SURVIVE. An earlier fix let the readout absorb the whole
        // deficit, so both meters truncated to "42% · 5…" / "68% · w…" and a stacked pair
        // became indistinguishable — worse than a short name. The window token is what
        // tells them apart, so assert it rendered.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "weekly"))
                .firstMatch.waitForExistence(timeout: 5),
            "the weekly meter lost its window label, so two stacked meters cannot be told apart")
    }

    /// THE MACHINE'S ANSWER REACHES THE SCREEN. The notify card used to say "Push needs the
    /// herdr fork" whatever the daemon could do; it now renders `notifications.status`. Each
    /// launch picks the mock daemon's answer through `HERDR_MOCK_PUSH_STATE`, including a
    /// daemon too old to know the method (`legacy`), which must ask for an update rather than
    /// fall back to a generic line.
    func testNotificationsShowWhatThisMachineCanDo() {
        let cases: [(state: String, title: String)] = [
            ("relay_ready", "Notifications are on"),
            ("unconfigured", "This machine can't send notifications yet"),
            ("off", "Notifications are turned off in Herdr on this machine"),
            ("legacy", "Update Herdr on this machine to get notifications"),
        ]
        for (state, title) in cases {
            let app = XCUIApplication.launched(mock: "settings", environment: ["HERDR_MOCK_PUSH_STATE": state])

            let manage = app.staticTexts["Notifications"].firstMatch
            XCTAssertTrue(manage.waitForExistence(timeout: 15), "Settings should list Notifications")
            manage.tap()

            let row = app.staticTexts[title]
            // The row sits under the four toggles; bring it into view before judging it.
            var scrolls = 0
            while scrolls < 6 {
                if row.waitForExistence(timeout: 3), app.frame.contains(row.frame) { break }
                app.swipeUp()
                scrolls += 1
            }

            attach(app, "settings-push-\(state)")

            XCTAssertTrue(row.exists, "\(state): expected \"\(title)\"")
            XCTAssertFalse(app.staticTexts["Push needs the herdr fork"].exists,
                           "\(state): the old unconditional line is still shown")
            app.terminate()
        }
    }

    /// PROPOSAL B's SUGGESTIONS (#572): an update waiting and an exhausted account show as
    /// rows under the machine card, each with its count, and each opens the page that acts
    /// on it. The `serverupdate` mock offers herdr 0.9.5 to a 0.9.3 mac-mini, and its
    /// accounts are the shared fixture, where `acc-claude-2` ("Claude Pro (personal)") is
    /// exhausted. Without the suggestions group neither identifier exists; a row wired to
    /// the wrong page fails on the page title it lands on.
    func testSuggestionsShowUpdateAndExhaustedAccountAndOpenTheirPages() {
        let app = XCUIApplication.launched(mock: "serverupdate", environment: ["HERDR_MOCK_UPDATE": "available"])
        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"] : app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()

        let card = app.buttons["settings-machine-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the machine card should lead Settings")
        XCTAssertTrue(card.label.contains("mac-mini"), "the card names the machine (got \(card.label))")

        let update = app.buttons["settings-suggestion-update"]
        XCTAssertTrue(update.waitForExistence(timeout: 15), "an available herdr update is a suggestion")
        XCTAssertTrue(update.label.contains("Update herdr to 0.9.5"), "got \(update.label)")
        let exhausted = app.buttons["settings-suggestion-exhausted"]
        XCTAssertTrue(exhausted.waitForExistence(timeout: 15), "an exhausted account is a suggestion")
        XCTAssertTrue(exhausted.label.contains("Claude Pro (personal)"), "got \(exhausted.label)")
        XCTAssertGreaterThan(exhausted.frame.minY, update.frame.minY, "the update leads, the account follows")
        XCTAssertGreaterThan(update.frame.minY, card.frame.maxY, "suggestions sit under the machine card")
        attach(app, "settings-b-suggestions")

        // The update opens Machines, where the shipped update card waits.
        update.tap()
        XCTAssertTrue(app.staticTexts["server-update-title"].firstMatch.waitForExistence(timeout: 15),
                      "the update suggestion should open Machines and its update card")
        XCTAssertTrue(app.staticTexts["Machines"].firstMatch.exists)
        attach(app, "settings-b-machines")

        // Back to the root (iPhone) — on the iPad the sidebar stays beside the detail.
        if UIDevice.current.userInterfaceIdiom != .pad {
            let back = app.buttons["Back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(exhausted.waitForExistence(timeout: 10))
        exhausted.tap()
        XCTAssertTrue(app.staticTexts["ACCOUNTS"].waitForExistence(timeout: 10),
                      "the exhausted suggestion should open Accounts")
        XCTAssertTrue(app.staticTexts["exhausted"].firstMatch.waitForExistence(timeout: 10),
                      "Accounts should show the exhausted account's status")
        attach(app, "settings-b-accounts")
    }
}
