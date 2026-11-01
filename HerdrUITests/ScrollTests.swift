import XCTest
import UIKit
import Vision

/// The automated SCROLL RECEIPT (JARVIS standing-rule 47874: no scroll change ships on
/// static review alone — a real drag must be exercised). Launches the app into a REAL
/// SwiftTerm pane seeded with 200 lines of scrollback (HERDR_SCREENSHOT_MOCK=scroll),
/// then:
///   1. proves the terminal is STATIC when untouched (two screenshots ~identical) — so
///      the scroll assertion can't be faked by ambient animation, and
///   2. swipes the terminal and asserts the rendered pixels MOVED substantially.
/// Dead scroll (the 7-build symptom) = unchanged pixels after the swipe = this fails.
/// Before/after screenshots are attached so the CI artifact is the visual proof.
final class ScrollTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTerminalScrollsWhenSwiped() {
        let app = XCUIApplication.launched(mock: "scroll")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))

        // Let the app launch and the mock stream feed all 200 lines into the real
        // SwiftTerm view (async), so there is scrollback to move.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) STATIC CHECK: with the cursor hidden by the seed, an untouched terminal
        // must render essentially identically frame to frame. If it doesn't, some
        // animation is running and the scroll assertion below would be unreliable.
        let before = viewport.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let beforeAgain = viewport.screenshot()
        let idleDiff = pixelDiffFraction(before, beforeAgain)
        attach(before, "01-before")
        XCTAssertLessThan(idleDiff, 0.02,
            "Terminal is not static when untouched (diff=\(idleDiff)); a moving element would invalidate the scroll check.")

        // (2) SWIPE: drag DOWN on the terminal body (below the header, above the reply
        // bar) to reveal older scrollback. Three firm drags to move a clear distance.
        let high = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low  = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)   // let scroll settle + repaint

        let after = viewport.screenshot()
        attach(after, "02-after-swipe")
        let movedDiff = pixelDiffFraction(before, after)

        // A real scroll shifts ~a screen of distinct numbered lines → a large fraction
        // of pixels change. Dead scroll leaves them identical (movedDiff ~ 0).
        XCTAssertGreaterThan(movedDiff, 0.10,
            "Terminal did NOT scroll: rendered content is unchanged after swiping (diff=\(movedDiff)). This is the dead-scroll symptom.")
    }

    /// The owner terminal's jump button: absent at the tail, shown once a swipe moves into
    /// history, and a tap renders the tail again (pixel-identical to before the swipe) and
    /// hides it.
    func testJumpToLatestReturnsTheOwnerTerminalToItsTail() {
        let app = XCUIApplication.launched(mock: "scroll")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3.0)
        let latest = app.buttons["terminal-jump-latest"]
        XCTAssertFalse(latest.exists, "no jump button at the tail")
        let tail = viewport.screenshot()
        attach(tail, "01-tail")

        let high = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low  = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "scrolled into history, the jump button should show")
        XCTAssertEqual(latest.label, "Jump to latest output")
        Thread.sleep(forTimeInterval: 1.0)
        let history = viewport.screenshot()
        attach(history, "02-history-with-jump-button")
        XCTAssertGreaterThan(pixelDiffFraction(tail, history), 0.10, "the swipe should have moved into history")

        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5), "back at the tail, the button goes")
        Thread.sleep(forTimeInterval: 1.0)
        let back = viewport.screenshot()
        attach(back, "03-after-jump")
        let backDiff = pixelDiffFraction(tail, back)
        XCTAssertLessThan(backDiff, 0.02, "the tap should render the tail again (diff=\(backDiff))")
    }

    /// The CLAUDE CODE receipt. Launches a pane in alt-screen + mouse-mode (Claude Code
    /// fullscreen shape) whose stand-in agent (CCScrollDriver) redraws shifted content
    /// ONLY when the app sends it an SGR wheel event. Swiping must therefore move the
    /// rendered content — which only happens if the app translated the drag into a wheel
    /// event for the mouse-mode agent (the fix). Dead path (the bug: SwiftTerm's mouse-pan
    /// eats the drag, no wheel emitted) = unchanged pixels = this fails.
    func testClaudeCodeScrollsViaWheel() {
        let app = XCUIApplication.launched(mock: "ccscroll")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3.0)   // launch + enter alt-screen/mouse + render

        // Static baseline (cursor hidden by the seed): untouched frames ~identical.
        let before = viewport.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let beforeAgain = viewport.screenshot()
        let idleDiff = pixelDiffFraction(before, beforeAgain)
        attach(before, "cc-01-before")
        XCTAssertLessThan(idleDiff, 0.02,
            "Claude-Code mock not static when untouched (diff=\(idleDiff)); would invalidate the scroll check.")

        // Swipe DOWN → the fix emits wheel-up (SGR 64) → the stand-in agent redraws an
        // earlier window → content moves.
        let high = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low  = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let after = viewport.screenshot()
        attach(after, "cc-02-after-swipe")
        let movedDiff = pixelDiffFraction(before, after)
        XCTAssertGreaterThan(movedDiff, 0.10,
            "Claude Code pane did NOT scroll: content unchanged after swipe (diff=\(movedDiff)). The drag was not translated into an SGR wheel event for the mouse-mode agent.")
    }

    /// The SCROLLBACK-BACKFILL receipt (open/refresh history). On connect the live stream seeds
    /// only the CURRENT screen; this proves the connect-time backfill (agent.read source=recent,
    /// ansi) supplies earlier output so a swipe-up reveals it. The `backfill` mock's LIVE stream
    /// carries ONLY the short one-screen seed while agent.read returns ~1000 numbered lines — so
    /// any scrollback the swipe reveals came from the backfill path, not the stream. RED without
    /// the feature (nothing above the seed to scroll into); GREEN once the backfill fills
    /// SwiftTerm's scrollback.
    func testBackfillMakesHistoryScrollable() {
        let app = XCUIApplication.launched(mock: "backfill")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3.0)   // launch + backfill read + reset seed feed

        // Static baseline (cursor hidden by the fixture): untouched frames ~identical.
        let before = viewport.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let beforeAgain = viewport.screenshot()
        let idleDiff = pixelDiffFraction(before, beforeAgain)
        attach(before, "bf-01-before")
        XCTAssertLessThan(idleDiff, 0.02,
            "Backfill mock not static when untouched (diff=\(idleDiff)); would invalidate the scroll check.")

        // Swipe DOWN on the terminal body to reveal the backfilled history above the current
        // screen (same gesture the omp scroll receipt uses).
        // Longer, more numerous drags than the other two scroll tests so more backfilled
        // history is revealed, giving the assert headroom on the CI sim (see #124).
        let high = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let low  = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        for _ in 0..<5 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let after = viewport.screenshot()
        attach(after, "bf-02-after-swipe")
        let movedDiff = pixelDiffFraction(before, after)
        XCTAssertGreaterThan(movedDiff, 0.10,
            "No backfilled history to scroll into: content unchanged after swiping (diff=\(movedDiff)). The connect-time scrollback backfill did not populate SwiftTerm's scrollback.")
    }

    /// The RECONNECT-HISTORY receipt. The `keyframehistory` mock drops its first stream right
    /// after a screen-only keyframe, and only the keyframe of the in-place reconnect carries
    /// history (`history_b64`); `agent.read` has none. A swipe can therefore reveal earlier
    /// output only if the app seeds scrollback from a reconnect's keyframe. RED before that
    /// (the history prepend ran on the first keyframe only, from the backfill); GREEN after.
    func testReconnectKeyframeRestoresHistory() throws {
        let app = XCUIApplication.launched(mock: "keyframehistory")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        // Launch + the dropped stream + the reconnect's 0.3–0.5 s backoff + its keyframe.
        Thread.sleep(forTimeInterval: 4.0)

        let before = viewport.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let beforeAgain = viewport.screenshot()
        let idleDiff = pixelDiffFraction(before, beforeAgain)
        attach(before, "kh-01-before")
        XCTAssertLessThan(idleDiff, 0.02,
            "Mock not static when untouched (diff=\(idleDiff)); would invalidate the scroll check.")

        let high = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let low  = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        for _ in 0..<5 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let after = viewport.screenshot()
        attach(after, "kh-02-after-swipe")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let historyRow = try NSRegularExpression(pattern: #"history\s+([0-9]+)"#,
                                                options: .caseInsensitive)
        func visibleHistoryRows(in screenshot: XCUIScreenshot) throws -> [Int] {
            let image = try XCTUnwrap(screenshot.image.cgImage)
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string,
                      let match = historyRow.firstMatch(in: text,
                          range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return Int(text[range])
            }
        }
        let beforeRows = try visibleHistoryRows(in: before)
        let afterRows = try visibleHistoryRows(in: after)
        let earliestAfter = try XCTUnwrap(afterRows.min(),
            "No numbered history visible after swiping the reconnected terminal.")
        // The fixture has rows 1...300. If none were visible at the live screen,
        // any historical row is earlier; otherwise the swipe must reveal older rows.
        XCTAssertLessThan(earliestAfter, beforeRows.min() ?? 301,
            "Swipe did not reveal earlier history: before=\(beforeRows), after=\(afterRows)")
    }

    /// The REDUNDANT-HISTORY-READ receipt (#459). On a current server (herdr#301) every keyframe
    /// carries history, so the mount-time history read (agent.read, source=recent) is never used.
    /// That read starts at mount, concurrently with the stream and before any keyframe can
    /// arrive, so "no read is issued" is not something the app can promise; what it can do is
    /// cancel the read once a keyframe with history lands. The `keyframehistoryread` mock holds
    /// each history read for 3 s (shorter than the app's 6 s backfill timeout, which also cancels
    /// it) and counts how it ends. RED without the cancel: the held read runs to its answer
    /// (answered=1). GREEN: the first keyframe cancels it while it is held (answered=0).
    func testKeyframeHistoryCancelsHistoryRead() {
        let app = XCUIApplication.launched(mock: "keyframehistoryread")
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["keyframe-history-reads"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "keyframe-history-reads probe missing")

        // Past the 3 s hold, then until every requested read has ended one way or the other.
        Thread.sleep(forTimeInterval: 4)
        var counts = readCounts(probe.label)
        _ = poll(6, every: 0.25) {
            counts = readCounts(probe.label)
            return counts.requested > 0 && counts.answered + counts.cancelled >= counts.requested
        }
        XCTAssertGreaterThanOrEqual(counts.requested, 1,
            "The mount-time history read never reached the mock (\(probe.label)).")
        XCTAssertEqual(counts.answered, 0,
            "The history read ran to its answer although the keyframe already carried history (\(probe.label)).")
        XCTAssertEqual(counts.cancelled, counts.requested,
            "Every history read should be cancelled once a keyframe with history arrives (\(probe.label)).")
    }

    /// The HISTORY-PAGING receipt. The `historypaging` mock's keyframe carries 300 rows and a
    /// `history_cursor`; `pane.history` serves 2000 older rows a held page at a time. Nothing
    /// may be requested before the reader scrolls; flicking to the top must request the page
    /// above the keyframe's cursor, the loading capsule must show while a page is held, and the
    /// next request must carry the cursor that page returned (hc-2001 → hc-1501).
    func testScrollingToTheTopPagesOlderHistory() {
        let app = XCUIApplication.launched(mock: "historypaging")
        let viewport = app.terminalSurface
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["history-paging-requests"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "history-paging-requests probe missing")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(probe.label.hasPrefix("requests=0"), "paged before any scroll (\(probe.label))")

        let paged = poll(60, every: 0.1) {
            if probe.label.contains("hc-2001") { return true }
            viewport.swipeDown(velocity: .fast)
            return probe.label.contains("hc-2001")
        }
        XCTAssertTrue(paged, "swiping to the top requested no page (\(probe.label))")

        // The first page lands keeping the reader's rows, 500 rows below the new top; jump
        // back to the top rather than swipe through them. Taps while it is held do nothing.
        let top = app.buttons["history-scroll-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 5), "history-scroll-top action missing")
        let chained = poll(20, every: 0.2) {
            if probe.label.contains("hc-1501") { return true }
            top.tap()
            return probe.label.contains("hc-1501")
        }
        XCTAssertTrue(chained, "the second page did not use the first page's cursor (\(probe.label))")
        XCTAssertTrue(probe.label.contains("cursors=hc-2001,hc-1501"), probe.label)
        // The mock holds that page 2 s; the capsule must show while it is held. Checked on
        // this page, not the swiped one: a swipe's deceleration keeps XCTest waiting for
        // the app to idle for about as long as the hold.
        let capsule = app.descendants(matching: .any)["terminal-history-loading"]
        XCTAssertTrue(poll(2, every: 0.1) { capsule.exists },
                      "the loading capsule never showed while a page was held")
    }

    /// The non-drag variant: the Mac's wheel and trackpad move `contentOffset` with neither
    /// `isDragging` nor `isDecelerating` set, and the paging that waited for those flags never
    /// paged there (#523 item 10). `history-scroll-top` writes offset 0 the same way, after the
    /// seed has settled, and with no scroll before it; landing at the top must page.
    func testReachingTheTopWithoutADragPagesOlderHistory() {
        let app = XCUIApplication.launched(mock: "historypaging")
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["history-paging-requests"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "history-paging-requests probe missing")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(probe.label.hasPrefix("requests=0"), "paged before any scroll (\(probe.label))")

        let top = app.buttons["history-scroll-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 5), "history-scroll-top action missing")
        top.tap()
        XCTAssertTrue(poll(10, every: 0.1) { probe.label.contains("hc-2001") },
                      "reaching the top without a drag requested nothing (\(probe.label))")
        XCTAssertTrue(probe.label.hasPrefix("requests=1"), probe.label)
    }

    /// The tap-to-load receipt. A keyframe with five rows of history leaves the pane within a
    /// screen of the top from the start, so nothing pages by itself; the "Load earlier output"
    /// capsule is offered instead, and a tap on it requests the page above the keyframe.
    func testLoadEarlierCapsulePagesOlderHistory() {
        let app = XCUIApplication.launched(mock: "historypaging",
                                           environment: ["HERDR_MOCK_HISTORY_KEYFRAME_ROWS": "5"])
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["history-paging-requests"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "history-paging-requests probe missing")
        let loadEarlier = app.buttons["terminal-load-earlier"]
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 10), "the load-earlier capsule was not offered")
        XCTAssertEqual(loadEarlier.label, "Load earlier output")
        XCTAssertTrue(probe.label.hasPrefix("requests=0"), "paged before anyone asked (\(probe.label))")

        loadEarlier.tap()
        XCTAssertTrue(poll(10, every: 0.1) { probe.label.contains("cursors=hc-2296") },
                      "the tap requested no page (\(probe.label))")
        XCTAssertTrue(probe.label.hasPrefix("requests=1"), probe.label)
    }

    // MARK: - helpers

    /// Parses the `keyframe-history-reads` probe: "requested=N answered=N cancelled=N".
    private func readCounts(_ label: String) -> (requested: Int, answered: Int, cancelled: Int) {
        var values: [String: Int] = [:]
        for field in label.split(separator: " ") {
            let pair = field.split(separator: "=")
            if pair.count == 2, let n = Int(pair[1]) { values[String(pair[0])] = n }
        }
        return (values["requested"] ?? 0, values["answered"] ?? 0, values["cancelled"] ?? 0)
    }
}
