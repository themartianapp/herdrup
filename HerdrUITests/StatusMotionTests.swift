import UIKit
import XCTest

/// Status shapes that nobody can see must not move: a repeating SwiftUI animation drives the
/// display link every frame even behind another view (#427: an idle Mac app at 66% CPU).
/// Ones that can be seen must move, on screen, not just be counted (build 203).
final class StatusMotionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The DEBUG `status-motion` probe: how many `TurningRing`s and `PulsingDot`s are moving
    /// (its label; polled every 250 ms, so read it after a pause).
    private func moving(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["status-motion"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG status-motion probe should be present")
        return Int(probe.label) ?? -1
    }

    private func launchList() -> XCUIApplication {
        let app = XCUIApplication.launched(mock: "list", environment: [
            // The open pane's blinking caret never lets XCUITest's idle wait finish (60 s a tap).
            "HERDR_STEADY_CARET": "1",
        ])
        XCTAssertTrue(app.staticTexts["herdr-app"].firstMatch.waitForExistence(timeout: 15),
                      "the roster should list the working agent")
        return app
    }

    /// Whether `shape` visibly moves on screen. Its frame is read once, after a 0.25 s settle
    /// (so a tab switch's own fade is over); the first photo follows, then four more 0.25 s
    /// apart; it moves when at least two of them differ from the first. A ring that turns once
    /// per 0.9 s, or a dot that pulses every 0.8 s, never comes back to the same pixels; a
    /// stuck one stays put, and a single late redraw cannot pass for motion. Counting the
    /// motion in the view tree (`moving`) cannot see a motion that never starts.
    ///
    /// The photos are of the SCREEN, all cut to that one frame, not `shape.screenshot()`,
    /// which looks the shape up again for every photo. Each lookup runs XCTest's automation
    /// inside the app, which writes stderr lines for every accessibility attribute it fetches,
    /// and xcodebuild drains that pty on its own main thread. The eleven lookups of one check
    /// of the ring, the roster's last element, wrote ~40,000 lines in 5 s; once xcodebuild
    /// fell behind, the app's main thread sat in that write inside XCTest's query past its
    /// 30 s deadline, three times over: "Failed to get matching snapshots: Timed out while
    /// evaluating UI query" (runs 41812896614 and 42376372751: both spindumps hold the main
    /// thread in `writev` → `spec_write` under `-[XCTElementQuery _firstMatchingSnapshot…]`).
    /// One cut still sees both motions: the ring's frame stays 24.5 pt while it turns, and the
    /// dot's frame swells with its pulse (7.0–9.4 pt in run 42376372751) while its opacity
    /// changes inside any of those frames. A stuck shape's pixels stay identical.
    private func moves(_ shape: XCUIElement) -> Bool {
        XCTAssertTrue(shape.waitForExistence(timeout: 10), "the status shape should be on screen")
        usleep(250_000)
        let frame = shape.frame
        let first = XCUIScreen.main.screenshot()
        guard let firstPixels = pixels(of: frame, in: first) else {
            XCTFail("the status shape's frame \(frame) is not on the screen")
            return false
        }
        var changed = 0
        for _ in 0..<4 {
            usleep(250_000)
            guard let photo = pixels(of: frame, in: XCUIScreen.main.screenshot()) else {
                XCTFail("the status shape's frame \(frame) is not on the screen")
                return false
            }
            if photo != firstPixels { changed += 1 }
        }
        if changed >= 2 { return true }
        // Keep the whole first photo in the result bundle: it also shows what was in front.
        attach(first, "\(shape.identifier) at \(frame) held still (\(changed)/4 photos changed)")
        return false
    }

    /// The pixels of `frame` (points) in `shot`, PNG-encoded; nil when none of it is there.
    private func pixels(of frame: CGRect, in shot: XCUIScreenshot) -> Data? {
        guard let image = shot.image.cgImage, shot.image.size.width > 0 else { return nil }
        let scale = CGFloat(image.width) / shot.image.size.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale).integral
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop).pngData()
    }

    /// A status shape by its identifier alone. A string subscript also compares label, value
    /// and placeholder value, so every element before the shape had four attributes fetched
    /// (and logged, see `moves`) instead of one.
    private func shape(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    private func ring(_ app: XCUIApplication) -> XCUIElement {
        shape(app, "status-ring")
    }

    private func dot(_ app: XCUIApplication) -> XCUIElement {
        shape(app, "status-dot")
    }

    /// iPhone: whether the row just tapped brought its pane to the front. Existence cannot
    /// tell: a kept-alive pane's terminal surface and dot stay in the accessibility tree behind
    /// the roster. The tab bar can: it is in the tree exactly while no pane is fronted (every
    /// full tree of run 42376372751). In run 40472854194 the re-tapped row left the roster on
    /// screen, `terminalSurface` was found anyway, `moving` counted the roster's ring as the
    /// pane's dot, and the dot photographed was the hidden pane's: background only.
    private func paneInFront(_ app: XCUIApplication) -> Bool {
        app.tabBars.firstMatch.waitForNonExistence(timeout: 10)
    }

    /// The owner's report (build 203): Agents → Gram → Agents left the working ring stuck.
    /// One launch for the three moments the ring must turn: first open, back from Gram, back
    /// from Settings (each tab switch builds a fresh motion that must start).
    func testRingTurnsOnOpenAndAfterTabSwitches() {
        let app = launchList()
        XCTAssertTrue(moves(ring(app)), "the working row's ring turns")
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(moves(ring(app)), "back from Gram, the working row's ring turns again")
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(moves(ring(app)), "back from Settings, the working row's ring turns again")
        app.terminate()
    }

    /// The working pane's header dot, left for Gram and fronted again (iPhone: back to the
    /// roster and the row again; iPad: the pane stays beside the roster).
    func testPaneDotPulsesAfterGram() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = launchList()
        let row = app.staticTexts["herdr-app"].firstMatch
        row.tap()
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10),
                      "the pane should open")
        XCTAssertTrue(moves(dot(app)), "the working pane's dot pulses")

        if !pad { app.buttons["Back"].firstMatch.tap() }
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        if !pad {
            row.tap()
            XCTAssertTrue(paneInFront(app), "the kept-alive pane should come back to the front")
        }
        XCTAssertTrue(moves(dot(app)), "back from Gram, the working pane's dot pulses again")
        app.terminate()
    }

    /// The list mock has one working agent, herdr-app: its roster ring turns, its open pane's
    /// dot pulses. Covered by the pane (iPhone) the ring stops; behind Gram and Settings the
    /// kept-alive pane's dot stops too. Back on Agents, and back from the Home screen, the
    /// same shapes move again.
    func testHiddenStatusShapesHoldStill() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication.launched(mock: "list", environment: [
            // The open pane's blinking caret never lets XCUITest's idle wait finish (60 s a tap).
            // The status shapes' SwiftUI animations do not hold it up.
            "HERDR_STEADY_CARET": "1",
        ])
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the roster should list the working agent")
        sleep(1)
        XCTAssertEqual(moving(app), 1, "the working row's ring turns on the roster")

        row.tap()
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10),
                      "the pane should open")
        sleep(1)
        // iPad / Mac keep the roster beside the pane: its ring and the pane's dot. iPhone covers
        // the roster: the dot alone.
        XCTAssertEqual(moving(app), pad ? 2 : 1, "only what is on screen moves with the pane open")

        if !pad { app.buttons["Back"].firstMatch.tap() }
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(moving(app), 0, "nothing moves behind Gram: the kept-alive pane holds still")

        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(moving(app), 0, "nothing moves behind Settings")

        app.buttons["Agents"].firstMatch.tap()
        sleep(1)
        // iPad / Mac: the roster and the still-fronted pane come back together. iPhone: the roster.
        XCTAssertEqual(moving(app), pad ? 2 : 1, "back on Agents, what is on screen moves again")
        XCTAssertTrue(moves(ring(app)), "back on Agents, the ring turns on screen")
        if !pad {
            row.tap()
            XCTAssertTrue(paneInFront(app), "the kept-alive pane should come back to the front")
            sleep(1)
            XCTAssertEqual(moving(app), 1, "the kept-alive pane's dot pulses again in front")
            XCTAssertTrue(moves(dot(app)), "the kept-alive pane's dot pulses on screen")
        }

        // Everything holds still while the scene is not active, and resumes together.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        sleep(1)
        XCTAssertEqual(moving(app), pad ? 2 : 1, "back from the Home screen, the same shapes move again")
        XCTAssertTrue(moves(pad ? ring(app) : dot(app)), "back from the Home screen, they move on screen")
        app.terminate()
    }
}
