import XCTest
import UIKit

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// WHAT IT DOES AND DOES NOT GUARD, stated first because the previous version of this comment
/// claimed the wrong thing. A review found the repaired behaviour unguarded by a mutant that
/// removes `clearTap.require(toFail: t)` — and a LATER review showed this receipt does not kill
/// that mutant either, for a timing reason neither of us had accounted for: without the failure
/// requirement `clearTap` recognizes at tap-2 touch-up, which is STRICTLY BEFORE SwiftTerm's
/// tripleTap-delayed `doubleTap` selects the word. The clear lands on the pre-tap state, the
/// selection is made ~0.3s later, the highlight paints, and this test passes.
///
/// The same timing implies the mutant is largely BENIGN in production, so the original P1 was a
/// reasoned coin-toss rather than a measured wipe. What this file does guard: no highlight at
/// all, a selection that is active but EMPTY, a selection SwiftTerm holds but does not paint,
/// and a deselection that never reaches the view. Those are real and it has caught three of
/// them. It is not a guard on the require(toFail:) line, and saying so was overclaiming.
///
/// THIS FILE HAS NOW BEEN WRONG FOUR TIMES, always about its own instrument and never about the
/// product code. Each lesson is kept because each was independently discoverable and I missed
/// it:
///
/// 1. PIXELS AGAINST A BASELINE CANNOT TELL A SELECTION FROM A POPOVER. v1 proved persistence
///    by diffing against the pre-selection frame, so ANY on-screen difference satisfied it —
///    including SwiftTerm's context menu merely being present.
/// 2. NEVER READ THE PASTEBOARD IN THIS REPO. v2 asserted on `UIPasteboard.general.string`. A
///    pasteboard READ raises a system paste prompt, nothing answers it in CI, and the run hung
///    to the 45-minute job timeout and was cancelled with no test results at all. The
///    constraint was already written twice in the app, at CopyForAgentButton.swift:9 and
///    HerdrApp.swift:685, both saying the app writes and never reads because that prompt
///    failed App Review under 2.1a.
/// 3. A COPY MENU IS NOT A SELECTION. v3 asserted `menuItems["Copy"].exists`. A reviewer
///    measured SwiftTerm's `selectedTextBackgroundColor` at 0 of 3,162,132 pixels in every
///    frame while Copy WAS present: `selectedColumnsRange` yields an EMPTY range when
///    `startCol == endCol`, so a tap off the glyphs leaves `selection.active == true` with
///    nothing selected and nothing painted, and `canPerformAction` offers Copy anyway.
/// 4. A PIXEL COUNT CANNOT NAME A CAUSE. v4 measured the highlight and reported "teal px=0"
///    twice, which is consistent with four different bugs. I diagnosed it twice from that one
///    number and was wrong both times — first a keyboard-relayout race, then coordinates. So
///    the app now publishes SwiftTerm's own selection state under the mock env var and this
///    reads it, asserting STATE before PIXELS so a failure says which layer broke.
///
/// Two corrections to v4's own claims, both from review: my "these mock lines are short"
/// remark was wrong (they are 68 of 80 columns, so the earlier dx values were over text after
/// all, and the retroactive "past end of line" diagnosis was dubious), and the coordinates were
/// sound throughout. The two-stage focus tap is kept anyway: it removes a real race in which a
/// keyboard-driven resize can clear a just-made selection, which is a hazard on device even
/// when CI happens to win it.
final class TerminalSelectionTests: XCTestCase {

    /// SwiftTerm's default `selectedTextBackgroundColor` is (0, 166/255, 178/255) and the app's
    /// `Coordinator.style` never overrides it — verified: nothing in App/ or Sources/ assigns
    /// `selectedTextBackgroundColor` or `selectedTextForegroundColor` at all, and `style(view)`
    /// sets only font, nativeBackground/Foreground, backgroundColor, caretColor, isOpaque and
    /// installColors. So a teal region in a frame IS SwiftTerm's selection.
    ///
    /// "NOTHING ELSE IN THE PALETTE IS NEAR IT" WAS FALSE, and a reviewer did the arithmetic:
    /// `Palette.working` and `caretColor` are both 0x5B9BE8, which passes this detector
    /// outright (g=155 > 91+40, b=232 > 131, g > 70), as do the ANSI cyan slots 0x4FB8C8 and
    /// 0x74CEDC. None of them appears in THIS mock — the fixture's blocked agent draws an amber
    /// dot, the cursor is hidden by ESC[?25l, and the seeded text is uncoloured — so the
    /// detector is specific here. What makes that safe is not the constant but the
    /// `baseTeal < 20` premise: a working-status dot would contribute roughly 28 downsampled
    /// pixels, so any future collision fails the PREMISE loudly instead of quietly satisfying
    /// the conclusion.
    ///
    /// The hue tests (`g > r + 40`, `b > r + 40`) are the reviewer's, unchanged. The
    /// BRIGHTNESS floor is 70 rather than their 90 because they measured full-resolution
    /// frames and this downsamples: a teal pixel averaged with the terminal's near-black
    /// ground (#0B0D1C) at the edge of a glyph lands around g=89, which their threshold would
    /// reject. Relaxing it can only admit more colours, which is why the test asserts the
    /// BASELINE count is near zero before drawing any conclusion from a later count — that
    /// premise, not this constant, is what makes the detector specific to the selection.
    ///
    /// FAILS THE TEST when the screenshot cannot be decoded: a count of 0 would satisfy every
    /// "no teal" assertion without measuring anything.
    private func tealPixelCount(_ shot: XCUIScreenshot,
                                file: StaticString = #filePath, line: UInt = #line) -> Int {
        let w = 300, h = 600
        guard let buf = rgbaBuffer(shot.image, w: w, h: h) else {
            XCTFail("Could not decode the screenshot to count selection-teal pixels", file: file, line: line)
            return 0
        }
        var n = 0
        var i = 0
        while i < buf.count {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if g > r + 40 && b > r + 40 && g > 70 { n += 1 }
            i += 4
        }
        return n
    }

    override func setUp() { continueAfterFailure = false }

    /// A screenshot taken once the screen has held still for `hold` seconds: consecutive frames
    /// 0.25 s apart show no pixel differing (`pixelDiffFraction`). Replaces fixed settles before
    /// a pixel measurement — a repaint or relayout still in flight keeps it waiting, a settled
    /// screen returns at once. After `timeout` it returns the last frame and the measurement
    /// that follows judges it, so a screen that never settles still fails there, by name.
    private func settledScreenshot(_ app: XCUIApplication, hold: TimeInterval = 0.5,
                                   timeout: TimeInterval = 10) -> XCUIScreenshot {
        var last = app.screenshot()
        var stillSince = Date()
        _ = poll(timeout, every: 0.25) {
            let now = app.screenshot()
            if pixelDiffFraction(last, now) > 0 { stillSince = Date() }
            last = now
            return Date().timeIntervalSince(stillSince) >= hold
        }
        return last
    }

    func testDoubleTapSelectsAWordAndASingleTapDeselectsIt() {
        // If ANY system dialog appears, dismiss it rather than letting the run hang to the job
        // timeout with no results — the shape of lesson 2 above, guarded generally.
        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }

        let app = XCUIApplication.launched(mock: "scroll")

        // The mock feeds 200 numbered lines into a real SwiftTerm view asynchronously.
        XCTAssertTrue(app.terminalSurface.exists(within: 10), "the terminal pane never came up")
        // Kept: nothing on screen says the feed has been drawn, and a still-blank baseline would
        // pass the keyboard premise below (a large diff) without the keyboard. Then a second
        // without a redraw.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) PREMISES, both asserted before anything is concluded from them.
        let baseline = settledScreenshot(app, hold: 1.0)
        attach(baseline, "01-baseline")

        // 1a. The terminal is static when untouched, so a later change means the gesture did
        // something rather than the stream repainting under us.
        // Kept: this premise IS a stretch of time in which nothing may change.
        Thread.sleep(forTimeInterval: 1.0)
        let idleDiff = pixelDiffFraction(baseline, app.screenshot())
        XCTAssertLessThan(idleDiff, 0.02,
                          "terminal is not static when untouched (diff=\(idleDiff)); no later measurement would mean anything")

        // 1b. NOTHING is already teal. Without this the selection assertion could be satisfied
        // by any pre-existing colour in the palette, which is exactly how v1 passed.
        let baseTeal = tealPixelCount(baseline)
        XCTAssertLessThan(baseTeal, 20,
                          "found \(baseTeal) selection-coloured pixels BEFORE selecting anything; the detector cannot distinguish a selection here")

        // (2) RAISE THE KEYBOARD FIRST, AND ASSERT THAT IT HAPPENED. This step exists because
        // of a measured failure, not for tidiness: the previous version double-tapped a COLD
        // pane and got teal px=0 with a clean baseline. Tap 1 of that double tap fires
        // `focusTap`, which requests terminal focus and so raises the iPhone software keyboard;
        // the keyboard takes roughly the bottom 40%, the terminal band relaid out under the
        // finger, and tap 2 therefore hit different content and word-selected an EMPTY range —
        // active selection, Copy offered, nothing painted. Doing it in two stages means the
        // layout is settled before the gesture under test runs.
        //
        // The assertion is what makes this a wait with a reason rather than a sleep: a large
        // diff IS the keyboard arriving, so if it ever stops arriving this fails here, naming
        // the cause, instead of failing later as a mysteriously absent selection.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.30)).tap()
        // Wait for the keyboard, then for the relaid-out terminal band to finish redrawing.
        _ = app.keyboards.element.exists(within: 10)
        let focused = settledScreenshot(app)
        attach(focused, "02-keyboard-up")
        let focusDiff = pixelDiffFraction(baseline, focused)
        XCTAssertGreaterThan(focusDiff, 0.10,
                             "the focus tap changed almost nothing (diff=\(focusDiff)); the keyboard did not come up, so the double tap below would run against a layout that is still about to move")
        XCTAssertLessThan(tealPixelCount(focused), 20,
                          "a single tap on an unselected pane produced selection colour; the premise for step 4 is broken")

        // (3) DOUBLE TAP AT A COLUMN THAT IS WRITTEN ON BOTH ROW TYPES, because the terminal
        // WRAPS and half the visible rows are continuations.
        //
        // The stream-lifecycle fix changed the geometry this test runs against, and the probe
        // reported the new truth: rows=19 cols=50, not the 24x80 the fixture declares. The app
        // pins the PTY to the phone's fit, so the fixture's 64-character line wraps:
        //   row A (cols 0-49):  "SCROLLTEST line 187  the quick brown fox jumps ove"
        //   row B (cols 0-13):  "r the lazy dog"   — and cols 14-49 are UNWRITTEN
        // A tap on an unwritten cell hits selectWordOrExpression's NUL branch, which selects the
        // run of nulls: active, and empty when read back. That is exactly what CI reported at the
        // previous head — sel=1 len=0 text=<> — and dx 0.344 lands on col 17, which is inside the
        // line number on row A and NUL on row B. Roughly half the rows are continuations, so that
        // coordinate was a coin toss for the third time.
        //
        // dx 0.150 is col 7, and it is chosen by enumerating every column written on BOTH row
        // types with one column of slack either side, inside a word of at least three characters:
        // columns 3, 7, 8 and 12 qualify. Col 7 is "SCROLLTEST" on a primary row and "lazy" on a
        // continuation row, and cols 6 and 8 are inside the same two words, so a one-column drift
        // still selects a real word.
        //
        // The cost is that the selected text no longer identifies the line, so the placement
        // arithmetic below degrades to best-effort. That is an acceptable trade now: the row-space
        // question it was built to answer has been ANSWERED — the fixture was re-seeding — and the
        // ydisp guard is what protects against that returning.
        //
        // dy=0.30 stays in the terminal band, which the keyboard has shrunk to roughly the top 58%.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.150, dy: 0.30)).doubleTap()
        // Wait for SwiftTerm to report the selection (the state asserted in step 4), then for
        // its highlight and the Copy menu to finish drawing.
        let selectionProbe = app.descendants(matching: .any)["terminal-selection-probe"]
        _ = poll(10, every: 0.25) { selectionProbe.exists && selectionProbe.label.contains("sel=1") }
        let selected = settledScreenshot(app)
        attach(selected, "03-selection-held")

        // (4) READ THE STATE, THEN THE PIXELS — in that order, because for four consecutive CI
        // runs "no teal" was all this test could say, and it cannot distinguish: no selection
        // was made; an EMPTY range was selected; a late resize wiped it (SwiftTerm clears the
        // selection on any rows/cols change); or a selection exists and is painted a colour the
        // detector does not match. Those are four different bugs and I guessed wrong twice.
        // `terminal-selection-probe` is published by the app under the same mock env var and
        // reports sel/len/rows/cols/resizes, so the diagnosis now comes from SwiftTerm.
        let probe = app.descendants(matching: .any)["terminal-selection-probe"]
        let reading = probe.exists(within: 5) ? (probe.label) : "PROBE ABSENT"

        // THE STATE ASSERTIONS, in order of how badly a failure would mislead.
        XCTAssertTrue(reading.contains("sel=1"),
                      "SwiftTerm reports no active selection after a double tap. probe[\(reading)]. If resizes climbed since the focus tap, a late relayout wiped it; if not, the double tap never reached SwiftTerm's recognizer")
        XCTAssertFalse(reading.contains("len=0"),
                       "the selection is active but EMPTY, so the tap landed past the end of the line. probe[\(reading)]")

        // A WHITESPACE SELECTION IS A COORDINATE MISS, NOT A RENDER BUG, and it must say so.
        // `selectWordOrExpression` has a dedicated branch that selects a RUN OF SPACES, so a tap
        // between words yields an active, non-empty selection that paints one or two cells —
        // which then fails the pixel threshold below and reads exactly like a drawing failure.
        // That cost a CI round: the probe reported `len=1 text=< >` while the message blamed the
        // renderer. Extracting the text and checking it is a word turns the same run into a
        // one-line diagnosis.
        let selectedText = reading.range(of: "text=<").flatMap { start -> String? in
            let rest = reading[start.upperBound...]
            guard let end = rest.range(of: ">") else { return nil }
            return String(rest[..<end.lowerBound])
        } ?? ""
        XCTAssertFalse(selectedText.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the double tap selected WHITESPACE (\(selectedText.count) char(s)), so the coordinate missed the glyphs — this is a test-aim failure, not a drawing failure. probe[\(reading)]")
        // Three characters, which is both the shortest word in the visible fixture text and the
        // exact width of its line number — the intended target. Shorter means the tap clipped an
        // edge, and the pixel threshold below would then be measuring a sliver.
        XCTAssertGreaterThanOrEqual(selectedText.count, 3,
                                    "selected '\(selectedText)', shorter than the fixture's line number or any of its words, so the tap clipped an edge and the pixel threshold below would be unreliable. probe[\(reading)]")

        // THE RENDER ASSERTION, which the state assertions cannot replace: the user sees pixels,
        // and a selection that exists without being drawn is still broken for them.
        //
        // 60, three times the baseline ceiling of 20, so a marginal pass cannot straddle the
        // two limits: a run reading 19 before and 21 after would satisfy both a "nothing is
        // teal" premise and a "something is teal" conclusion, and mean neither. A three-cell
        // selection is roughly 250 downsampled pixels here, so the gap is not tight.
        //
        // AND THE MESSAGE NAMES THE CAUSE ARITHMETICALLY. Two explanations survived the source
        // reading and neither could be chosen from a pixel count: the selection sits on a row
        // being drawn and the PAINT is broken, or it sits outside the drawn window and the tap's
        // ROW SPACE is wrong. The fixture numbers its lines, so the selected text identifies the
        // selection's line, and the probe now carries ydisp — which turns the choice into
        // subtraction instead of another hypothesis.
        let heldTeal = tealPixelCount(selected)
        let selRow = Int(selectedText).map { $0 - 1 }          // "187" is 1-indexed; buffer rows are 0-indexed
        let yDisp = value(of: "ydisp", in: reading)
        let rowCount = value(of: "rows", in: reading)

        // THE FIXTURE MUST NOT HAVE RE-SEEDED, asserted before anything is concluded from ydisp.
        //
        // This is the guard for the defect that cost this PR four CI rounds. The mock's
        // `pane.stream` used to FINISH after delivering its 200-line reset; the app correctly
        // treats an ended stream as a drop and reconnects, so every reconnect appended another
        // 200 lines. CI measured ydisp=3598 in one pass and 3777 in the next — a buffer of
        // thousands of lines in a fixture that seeds 200 — and the scroll view's geometry tracked
        // the original ~200 while yDisp ran away, so a tap resolved to a row nobody was drawing.
        // The selection was real and off-screen, which is why no highlight ever appeared and why
        // I spent four rounds looking at SwiftTerm's renderer, which was innocent throughout.
        //
        // THE CEILING IS 600, AND MY FIRST ATTEMPT AT 400 WAS ABOUT TO FALSE-FAIL. I sized it for
        // an UNWRAPPED buffer — 200 lines in a 24-row terminal parks yDisp near 176 — but the app
        // pins the PTY to the phone's fit of 50 columns, so each 64-character fixture line wraps
        // to TWO rows: about 400 buffer rows, minus the 19 visible, giving yDisp ≈ 381. CI observed
        // 382. A guard at 400 would have fired on correct behaviour within nineteen rows of slack,
        // which is the sort of check that gets deleted for crying wolf rather than fixed.
        //
        // One extra re-seed reaches roughly 781, so 600 separates one seed from two with room on
        // both sides. Computed from the fixture rather than guessed, and stated here so the next
        // change to the fixture's line length or column pinning knows what this number depends on.
        // AND THE GUARD MUST FAIL WHEN IT CANNOT RUN. `if let yDisp` silently took the else path
        // if the probe ever stopped publishing that field — rename it, reorder the label, or let a
        // selection contain "ydisp=" earlier in the string, and a fixture re-seeding to 3598 would
        // produce a GREEN test. That is precisely the shape this file's header warns about: an
        // instrument that cannot report its own absence. Caught by review, not by me.
        XCTAssertNotNil(yDisp, "probe stopped publishing ydisp, so the re-seed guard did not run. probe[\(reading)]")
        XCTAssertNotNil(rowCount, "probe stopped publishing rows, so the placement arithmetic cannot be derived. probe[\(reading)]")
        if let yDisp {
            XCTAssertLessThan(yDisp, 600,
                              "ydisp=\(yDisp) is far beyond the ~381 a single 200-line seed produces when wrapped at 50 columns, so the mock stream is re-seeding on reconnect again. The paint assertion below would then fail for that reason and not for a rendering fault. probe[\(reading)]")
        }
        let placement: String = {
            guard let selRow, let yDisp, let rowCount else {
                return "could not derive placement (selected text is not a line number, or the probe lacked ydisp/rows)"
            }
            let visible = yDisp...(yDisp + rowCount - 1)
            return visible.contains(selRow)
                ? "the selection is on buffer row \(selRow), INSIDE the drawn window \(visible), so the ROW SPACE IS CORRECT and the PAINT is what fails"
                : "the selection is on buffer row \(selRow), OUTSIDE the drawn window \(visible), so the TAP'S ROW SPACE is wrong and the paint never had a chance"
        }()
        XCTAssertGreaterThan(heldTeal, 60,
                             "SwiftTerm holds a selection but nothing is painted in the selection colour (teal px=\(heldTeal), baseline \(baseTeal)). \(placement). probe[\(reading)]")

        // Secondary only: Copy SHOULD be offered, but its presence alone proves nothing, since
        // an empty-but-active selection also offers it.
        XCTAssertTrue(app.menuItems["Copy"].exists(within: 5),
                      "a word is highlighted but Copy is not offered, so the selection cannot be acted on")

        // (5) DESELECTION still works, so the fix did not simply disable it.
        //
        // dy MATCHES THE TAPS THAT DEMONSTRABLY REACH THE TERMINAL. This was 0.20, and CI failed
        // deterministically in both passes with the selection untouched — sel=1 len=4 text=<lazy>,
        // republished by nobody. Since `handleClearSelectionTap` publishes AFTER clearing, sel=1
        // means clearTap never ran; and dy 0.20 was a guess about where the terminal band starts,
        // never a measured value, while 0.30 is proven twice over in this very test — the focus tap
        // raises the keyboard from there and the double tap selects a word from there. So the most
        // likely reading is that 0.20 was above the terminal, in the header or the TUI banner, and
        // no terminal recognizer saw the touch at all.
        //
        // dx moves to 0.60 to stay clear of the selected word at column 7 while remaining inside
        // the 50-column viewport.
        //
        // THE SETTLE IS LONGER THAN IT LOOKS, on purpose. `clearTap` requires SwiftTerm's 2-tap
        // recognizer to fail, and `menuTap` — which joined clearTap's require-to-fail set when I
        // declared it first — requires the 3-tap one. A genuine single tap therefore clears only
        // after that chain times out, about two multi-tap intervals, which under CI load is not
        // instant.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.30)).tap()
        // A BOUNDED POLL, NOT A FIXED SLEEP, and this is the blocking finding from the review of
        // 295df46f. The recognizer chain was verified SOUND against SwiftTerm 1.15.0
        // (iOSTerminalView.swift:1077-1078), so the failure at 0544df88 — pub=focusTap#5, sel=1
        // after three seconds — is consistent with a STALLED RUNLOOP rather than a dead chain:
        // those failure timers run on the app's main runloop and are unbounded under CI load. A
        // fixed sleep therefore encodes a guess about machine speed as if it were a property of
        // the product, and fails a slow-but-healthy chain.
        //
        // Polling for the state this step is actually about lets a slow chain pass and still fails
        // a genuinely dead one, at the cost of up to 10s only when something is already wrong.
        // The poll waits for a reading that is BOTH cleared and NEWER than the pre-tap one. Polling
        // on `sel=0` alone would also accept a stale label from before the tap, which is the same
        // class of error as the assertion above: a condition that can be satisfied without the
        // event under test having happened. `pub=<handler>#<count>` is monotonic, so a changed
        // label is proof of a fresh publish.
        let beforeReading = probe.exists ? probe.label : ""
        _ = poll(10, every: 0.25) {
            probe.exists && probe.label.contains("sel=0") && probe.label != beforeReading
        }
        // Then wait for the screen to hold still, so the screenshot cannot catch a half-drawn
        // repaint: the clear reaches the model synchronously but selectionChanged repaints on the
        // next main-queue hop.
        let cleared = settledScreenshot(app)
        attach(cleared, "04-after-single-tap")

        // STATE BEFORE PIXELS HERE TOO, which this step lacked while step 4 had it — so the one
        // step that failed was the one that could not name its layer.
        //
        // AND `pub` SEPARATES THE TWO REMAINING CAUSES. The probe now reports which handler
        // published it and a monotonic count, so:
        //   pub=focusTap#N with N above the pre-tap value -> the touch REACHED the terminal
        //     (focusTap has no failure requirement and fires on tap 1 of anything), so a still-
        //     active selection means clearTap's require-to-fail chain is the fault;
        //   pub unchanged from the double tap -> no terminal recognizer saw the touch, i.e. the
        //     coordinate missed the view, which is a test-aim failure and not a product one.
        // Without that field those two produce byte-identical readings, which is what cost the
        // previous round.
        let afterReading = probe.exists ? probe.label : "PROBE ABSENT"

        // WHAT THIS STEP CAN AND CANNOT PROVE, corrected after a review showed the previous version
        // passing while the app's own clear never executed.
        //
        // By this point the view IS first responder — focusTap took it on tap 1, and
        // showStandardContextMenu takes it too (iOSTerminalView.swift:1392). SwiftTerm's OWN
        // singleTap therefore runs its `if isFirstResponder` branch and calls selection.selectNone()
        // (iOSTerminalView.swift:743-768), and it requires only its own doubleTap to fail — whereas
        // the app's clearTap was made to require TWO 2-tap recognizers (SwiftTerm's doubleTap plus
        // the app's menuTap, since the attach loop runs after menuTap is added). So on this path
        // SWIFTTERM CLEARS FIRST, and the app's clearTap arrives later, publishes clearTapEntry
        // reading sel=0, hits its `guard view.hasActiveSelection` and returns without clearing.
        //
        // The old assertion accepted `contains("pub=clearTap")`, which ALSO prefix-matches
        // "pub=clearTapEntry" — so the receipt greened with view.clearSelection() never called. It
        // was testing SwiftTerm and reporting it as testing the app.
        //
        // So this now asserts the USER-VISIBLE property — the selection is gone after a genuine
        // single tap — and says plainly that it does not attribute the clear to either
        // implementation. clearTap's own value is on an UNFOCUSED pane, where SwiftTerm's singleTap
        // spends its tap taking the responder and does not clear; that path is not exercised here
        // and is worth its own receipt.
        XCTAssertTrue(afterReading.contains("pub=focusTap") || afterReading.contains("pub=clearTap"),
                      "no terminal tap handler published after the single tap, so the touch never reached the terminal view — the coordinate missed it. Compare against the pre-tap reading probe[\(reading)]; after probe[\(afterReading)]")
        XCTAssertTrue(afterReading.contains("sel=0"),
                      "the touch reached the terminal but a selection is still active, so nothing cleared it — neither SwiftTerm's singleTap nor the app's clearTap. probe[\(afterReading)]")

        let clearedTeal = tealPixelCount(cleared)
        XCTAssertLessThan(clearedTeal, 20,
                          "SwiftTerm reports the selection cleared but the highlight is still painted (teal px=\(clearedTeal)), so the clear reached the model and not the screen. probe[\(afterReading)]")
    }


    /// THE COLLAPSE CHEVRON'S RECEIPT, and it exists because this PR's FIRST attempt at the
    /// chevron fix was inert and nothing here could tell.
    ///
    /// The defect: on iPhone, with a word selected, the chevron cleared both focus flags — which
    /// hides the chevron itself — while `updateUIView`'s resign stayed gated on
    /// `!hasActiveSelection`. So the keyboard stayed up over ~40% of the pane with its only
    /// dismiss affordance gone. The first fix set a bool and cleared it in
    /// `DispatchQueue.main.async`; that queue drains BEFORE SwiftUI's update flush, so the pane
    /// read the flag as already false and the resign never ran. Review caught it by reading,
    /// because an inert fix and a working one produce identical screenshots — there was no
    /// observable for "gave up the responder while keeping the selection". Hence `fr=` on the
    /// probe and hence this test.
    ///
    /// Without a physical keyboard, deliberate collapse resigns the responder AND
    /// preserves the selection. With one attached, the control must stay hidden. A double
    /// tap re-presents Copy without re-selecting. Under the async-reset mechanism this fails at
    /// the `fr=0` poll; under a mechanism that resigns by clearing the selection it fails at
    /// `sel=1`. Both are real regressions and each has its own failure message.
    func testKeyboardDismissalRespectsHardwareAndPreservesSelection() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "this regression exercises the iPhone terminal keyboard")

        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }
        let app = XCUIApplication.launched(mock: "scroll")

        let probe = app.descendants(matching: .any)["terminal-selection-probe"]
        XCTAssertTrue(probe.exists(within: 20),
                      "the terminal never came up, so nothing below is about the chevron")

        // Two stages for the same reason the other test uses two: tap 1 raises the keyboard and
        // relayouts the terminal band, so a double tap fired into that motion selects whatever
        // slid under the finger. Settle first, then select.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.30)).tap()
        _ = app.keyboards.element.exists(within: 10)
        app.terminalSurface.waitForSettledFrame()
        // dx 0.150 is col 7 — written on BOTH the primary and continuation row types with a
        // column of slack either side. See the long note in the other test for the enumeration.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.150, dy: 0.30)).doubleTap()
        // Wait for the double tap's selection to be reported while the terminal still holds the
        // responder; the premises below judge the reading either way.
        _ = poll(10, every: 0.25) {
            probe.exists && probe.label.contains("sel=1") && probe.label.contains("fr=1")
        }

        // PREMISES FIRST. Without a live selection AND a held responder this test would pass on a
        // pane that simply never focused, which is the vacuity that cost this PR a round already.
        let beforeReading = probe.exists ? probe.label : "PROBE ABSENT"
        XCTAssertTrue(beforeReading.contains("sel=1"),
                      "premise: no selection to preserve, so the gate under test is never reached. probe[\(beforeReading)]")
        XCTAssertTrue(beforeReading.contains("fr=1"),
                      "premise: the terminal does not hold the responder, so there is nothing for the chevron to resign. probe[\(beforeReading)]")

        XCTAssertTrue(app.keyboards.element.exists(within: 10),
                      "premise: the software keyboard must be visible")
        let chevron = app.buttons["Collapse keyboard"]
        // Only a full software keyboard is dismissible. With a hardware keyboard iOS shows a
        // short shortcut bar. The probe's GCKeyboard reading is recorded but not trusted:
        // it can say "attached" while the full keyboard is on screen.
        let fullKeyboard = app.keyboards.element.frame.height >= 150
        if !fullKeyboard {
            XCTAssertFalse(chevron.exists(within: 2),
                           "a hardware keyboard's shortcut bar must not offer dismissal")
            print("Selection dismissal: only a shortcut bar is shown; hidden control verified. Dismissal was not exercised. probe[\(beforeReading)]")
            return
        }
        print("Selection dismissal: full software keyboard; exercising dismissal with selection. probe[\(beforeReading)]")
        XCTAssertTrue(chevron.exists(within: 5),
                      "the chevron is absent while the keyboard is up with a selection held — which IS the original defect: no affordance to dismiss with")
        chevron.tap()

        // A BOUNDED POLL FOR A READING THAT IS BOTH RESIGNED AND FRESH. `fr=0` alone would accept
        // the label from before the keyboard ever came up; `pub=<handler>#<count>` is monotonic, so
        // a changed label is proof of a new publish. The resign publishes `pub=collapseResign`,
        // which is the one path no gesture handler covers.
        _ = poll(10, every: 0.25) {
            probe.exists && probe.label.contains("fr=0") && probe.label != beforeReading
        }
        let afterReading = probe.exists ? probe.label : "PROBE ABSENT"

        XCTAssertTrue(afterReading.contains("fr=0"),
                      "the chevron did not resign the responder, so the keyboard is still up and the chevron has hidden itself — the exact defect this fix exists for. If pub= is unchanged from the pre-tap reading the update pass never observed the collapse token; if it changed and fr is still 1 the resign was refused by the selection guard. probe[\(afterReading)] before[\(beforeReading)]")
        XCTAssertTrue(afterReading.contains("sel=1"),
                      "the collapse also DROPPED the selection. Resigning is meant to hide the Copy menu while leaving the selection in the model, so a double tap re-presents it without re-selecting. probe[\(afterReading)]")
        XCTAssertTrue(afterReading.contains("pub=collapseResign"),
                      "the responder was resigned by some other path than the deliberate collapse (pub names the publisher), so this run did not exercise the chevron even though the end state looks right. probe[\(afterReading)]")
    }

    /// THE RECEIPT FOR "SCROLLING MUST NOT RAISE THE KEYBOARD", reported by the owner on a real
    /// iPhone: scrolling back through output would randomly raise the keyboard, which relayouts the
    /// terminal band, resizes the PTY and forces a re-render — losing the place they were reading.
    ///
    /// The cause is structural rather than a race: `focusTap` is a 1-tap recognizer with NO
    /// `require(toFail:)` (deliberately — the responder must exist by tap 1 for SwiftTerm's
    /// double-tap Copy menu), attached to `TerminalView`, which IS a `UIScrollView`. The universal
    /// iOS gesture for arresting momentum scrolling is a single tap, so that tap reaches the
    /// recognizer and was indistinguishable from a deliberate tap on the text.
    ///
    /// WHAT THIS PINS is the guard's behaviour, not the timing: a tap delivered while the pane is
    /// dragging or decelerating must NOT take the responder. `pub=scrollTapIgnored` is published
    /// only from that branch, so it proves the suppression ran rather than that the tap missed —
    /// two states that are otherwise byte-identical, both leaving focus untaken.
    ///
    /// HONEST ABOUT ITS OWN LIMIT: whether a synthesized tap lands inside the deceleration window
    /// is not something the test controls. So it retries, and if it never lands it SKIPS with the
    /// count rather than passing — a pass here would assert nothing at all, which is precisely the
    /// vacuity that let an inert fix green earlier in this PR's history.
    func testATapThatStopsAScrollDoesNotRaiseTheKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "the raised software keyboard this protects only exists on iPhone; iPad's terminal inputView is zero-frame")

        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }
        let app = XCUIApplication.launched(mock: "scroll")

        let probe = app.descendants(matching: .any)["terminal-selection-probe"]
        XCTAssertTrue(probe.exists(within: 20), "the terminal never came up")

        // PREMISE: start from an UNFOCUSED pane, so any fr=1 below is this test's own doing. A
        // pane that already held the responder would pass the assertion for the wrong reason.
        XCTAssertTrue(probe.label.contains("fr=0"),
                      "premise: the terminal already holds the responder before any tap, so this test cannot attribute a raise. probe[\(probe.label)]")

        let term = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        var suppressed = 0, duringMotion = 0, inertEvidence: [String] = []

        for _ in 1...6 {
            // Fling to get real motion, then tap into it immediately — the arrest-the-scroll
            // gesture a reader actually makes.
            let beforeTap = probe.exists ? probe.label : ""
            app.swipeDown(velocity: .fast)
            term.tap()
            // Wait for the focus decision's own publish (a fresh label naming it, see below)
            // rather than a fixed 0.4 s; a reading that never qualifies is discarded below.
            var reading = ""
            _ = poll(2, every: 0.1) {
                reading = probe.exists ? probe.label : ""
                return reading != beforeTap
                    && (reading.contains("pub=scrollTapIgnored") || reading.contains("pub=focusTap"))
            }
            let motionMs = value(of: "motionms", in: reading)

            // ONLY A READING PUBLISHED BY THE FOCUS DECISION ITSELF CAN BE JUDGED, and the previous
            // version of this test got that wrong in a way worth recording. It read the LAST label,
            // which a later handler routinely overwrites: CI showed `pub=clearTapEntry` carrying
            // `motionms=650`, and the test attributed that 650ms to the focus decision. It was never
            // the focus decision's number — `motionms` is computed at PUBLISH time, so a reading
            // from a different handler describes a different moment. That mis-attribution reported
            // the guard as inert on a run where it had behaved correctly.
            //
            // `handleFocusTap` publishes exactly one of two names — `focusTap` when it takes the
            // responder, `scrollTapIgnored` when it suppresses — so a reading bearing neither is
            // not evidence about this guard and is discarded rather than interpreted.
            let fromFocusDecision = reading.contains("pub=scrollTapIgnored") || reading.contains("pub=focusTap")

            // AND THE MEASUREMENT SHOWS XCUITEST CANNOT MAKE THIS GESTURE. Across two CI runs the
            // synthesized `swipeDown(velocity: .fast)` + `tap()` produced motion ages clustered at
            // ~630-870ms: the swipe settles completely before the tap is delivered, so it is a tap
            // on a STATIONARY pane, not the scroll-arresting tap a reader makes. A guard with a
            // 350ms window is RIGHT to let those through, so "not suppressed" at 650ms is not
            // evidence of inertness — which is precisely what the previous version concluded.
            if fromFocusDecision, let ms = motionMs, ms < 300 {
                duringMotion += 1
                if reading.contains("pub=scrollTapIgnored") {
                    suppressed += 1
                    XCTAssertTrue(reading.contains("fr=0"),
                                  "the tap was suppressed as scroll-arresting yet the terminal took the responder anyway, so the keyboard will still raise mid-scroll. probe[\(reading)]")
                } else if reading.contains("fr=1") {
                    // THE INERTNESS DETECTOR, narrowed to readings this guard actually published
                    // with motion demonstrably still in progress.
                    inertEvidence.append("motionms=\(ms) reading[\(reading)]")
                }
            }
            // Settle fully, and drop any focus a genuine settled tap took, so the next attempt
            // starts from the same premise this one did.
            //
            // BEST-EFFORT, AND THAT MATTERS: the first CI run of this test failed here rather than
            // on any assertion, because it tapped the chevron unconditionally and XCUITest hard-
            // fails a tap with no matching element ("No matches found for ... Collapse keyboard").
            // The chevron is only rendered while an input owner holds the keyboard, so on any
            // iteration where focus was not taken it legitimately does not exist. A RESET STEP MUST
            // NOT BE ABLE TO FAIL THE TEST IT IS RESETTING FOR — that reports a harness defect as a
            // product verdict, which is the same class of error as a test that passes vacuously.
            // Kept: the fling's deceleration must die out, so the next attempt's motion age is
            // its own swipe's and not this one's residue.
            Thread.sleep(forTimeInterval: 1.2)
            let chevron = app.buttons["Collapse keyboard"].firstMatch
            if probe.exists, probe.label.contains("fr=1"), chevron.exists(within: 2) {
                chevron.tap()
                _ = poll(5, every: 0.25) { probe.exists && probe.label.contains("fr=0") }
            }
        }

        // FAIL on positive evidence of inertness, whatever else happened. This is the assertion the
        // first version of the guard would have failed, and did not have.
        XCTAssertTrue(inertEvidence.isEmpty,
                      "a tap that arrived DURING content motion raised the keyboard anyway — the scroll guard is inert on this build. \(inertEvidence.count)/6 attempts: \(inertEvidence.joined(separator: " | "))")

        // Only if no tap ever landed during motion is this run genuinely uninformative. Skip rather
        // than pass, because a pass here would assert nothing at all.
        //
        // THIS SKIP IS THE EXPECTED OUTCOME IN CI, and saying so is the point. Two measured runs put
        // the synthesized swipe-then-tap at ~630-870ms after motion stopped, so it lands on a
        // settled pane and the guard is never reached. That is a limitation of XCUITest's gesture
        // synthesis, not of the guard: the real gesture has the finger arriving while the content is
        // still under it. So this test's job in CI is narrow and honest — it FAILS loudly if a tap
        // ever does arrive during motion and the keyboard still comes up, and otherwise reports that
        // it could not make the gesture. The scroll behaviour itself needs one on-device pass.
        try XCTSkipUnless(duringMotion > 0,
                          "no synthesized tap landed while the content was still moving in 6 attempts (motionms never below 300 on a reading published by the focus decision), so neither the guard nor its absence was exercised. Skipping rather than reporting a pass that measured nothing.")
        XCTAssertGreaterThan(suppressed, 0,
                             "\(duringMotion)/6 taps arrived during content motion and NONE were suppressed, so the guard is not firing on the path it exists for. probe last[\(probe.label)]")
    }

    /// THE BUSY-PANE RECEIPT, and it is the one CI can actually run.
    ///
    /// Review found that the scroll-tap guard, as first written, suppressed EVERY tap on a pane
    /// that was merely following output: SwiftTerm's auto-follow writes `contentOffset` on each
    /// output frame, so a guard keyed on "did the content just move" was permanently armed. The
    /// terminal became unfocusable exactly while an agent was working, which is the common case
    /// and a worse defect than the keyboard-on-scroll bug it was fixing.
    ///
    /// The fix records motion ONLY for offset writes made while the scroll view reports
    /// `isDragging || isDecelerating`, so auto-follow no longer counts. This test pins that: on a
    /// pane receiving output about eight times a second, a tap must still take the responder.
    ///
    /// WHY THIS ONE IS NOT TIMING-DEPENDENT, unlike the scroll-arrest test next door: it does not
    /// need a finger to arrive during motion. It needs output to be flowing, which the
    /// `busyscroll` mock guarantees for as long as the pane is mounted. So it passes or fails on
    /// the guard's behaviour and nothing else.
    func testATapFocusesTheTerminalWhileOutputIsStreaming() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "the raised keyboard this concerns is iPhone-only; iPad's terminal inputView is zero-frame")

        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }
        let app = XCUIApplication.launched(mock: "busyscroll")

        let probe = app.descendants(matching: .any)["terminal-selection-probe"]
        XCTAssertTrue(probe.exists(within: 20), "the terminal never came up")
        XCTAssertTrue(probe.label.contains("fr=0"),
                      "premise: the terminal already holds the responder before any tap. probe[\(probe.label)]")

        // PREMISE: OUTPUT MUST ACTUALLY BE FLOWING, or this test proves nothing about a busy pane.
        //
        // MEASURED FROM THE SCREEN, NOT THE PROBE, and the reason is a defect this test already
        // hit twice. The probe label is only rewritten when a GESTURE HANDLER publishes it, so on
        // an untouched pane it holds whatever was published last — my first two attempts read
        // `ydisp` from it and got the same stale 0 both times, which failed the premise while
        // saying nothing about whether output was flowing. Sampling the probe to detect change
        // that the probe is not sampling is circular.
        //
        // `pixelDiffFraction` looks at the rendered frames instead, which is the thing the claim
        // is actually about: a pane receiving output redraws, a dead one does not. The other
        // tests in this file use the same helper for the same reason, and the `scroll` fixture
        // hides the cursor so a STATIC terminal is byte-identical frame to frame — meaning any
        // measurable diff here is content, not a blinking caret.
        // Polled within the same 2 s: the premise is a redraw, so the first frame showing one
        // ends the wait.
        let busyBefore = app.screenshot()
        var busyAfter = busyBefore
        var flowing = 0.0
        _ = poll(2, every: 0.25) {
            busyAfter = app.screenshot()
            flowing = pixelDiffFraction(busyBefore, busyAfter)
            return flowing > 0.005
        }
        attach(busyBefore, "01-busy-before")
        attach(busyAfter, "02-busy-after")
        XCTAssertGreaterThan(flowing, 0.005,
                             "premise: the terminal did not redraw in 2s (diff=\(flowing)), so output is NOT streaming and this is not a busy pane. A pass here would certify the busy-pane guard against a pane with nothing arriving — vacuous. Check the busyscroll mock's frame type: StreamFrame accepts only reset/data/resize/ping/exited and decoding is strict.")

        // THE ASSERTION. A single tap on a pane that is following output must take the responder.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()
        _ = poll(6, every: 0.25) { probe.exists && probe.label.contains("fr=1") }
        let after = probe.exists ? probe.label : "PROBE ABSENT"
        XCTAssertTrue(after.contains("fr=1"),
                      "a tap on a pane that is merely FOLLOWING OUTPUT did not take the responder, so the terminal is unfocusable while an agent works — the regression the scroll-tap guard introduced. If pub=scrollTapIgnored the guard is treating auto-follow as user scrolling. probe[\(after)]")
        XCTAssertFalse(after.contains("pub=scrollTapIgnored"),
                       "the guard suppressed a tap on a busy pane, i.e. it is counting SwiftTerm's auto-follow writes as user scrolling. probe[\(after)]")
    }

    /// Pull an integer field out of the probe label, e.g. `ydisp=176` -> 176.
    ///
    /// Returns nil rather than a default when the field is absent, so a probe that stops
    /// publishing something degrades into "could not derive" in the failure message instead of
    /// silently asserting against a zero — a default here would be a plausible-looking number
    /// with no measurement behind it, which is the shape of error this whole file exists because
    /// of.
    private func value(of key: String, in reading: String) -> Int? {
        guard let start = reading.range(of: "\(key)=") else { return nil }
        let digits = reading[start.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }
}
