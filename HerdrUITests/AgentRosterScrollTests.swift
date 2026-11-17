import XCTest

/// Regression receipt for the macOS/iPad agent-list freeze.
///
/// The mock begins with a stable 80-row roster so cold layout is a precondition, not an
/// unrelated 50 ms starvation test. Once a real scroll starts it moves rows between
/// sections, changes the count, and emits a deferred row plus a phase-dependent real row.
/// A fixed top/bottom pair proves that swipes displaced content in both directions; the
/// the complete roster count proves that a different-sized scroll-time snapshot was
/// promoted on idle, while a named existing row changing sections independently proves
/// status redistribution. A separate violation marker makes publication during scrolling
/// fail instead of passing eventually. The pure state tests pin the same transition without UIKit.
final class AgentRosterScrollTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// How long a hittability change may take, DERIVED FROM THE REORDER CADENCE rather
    /// than from whatever makes CI green.
    ///
    /// The stress mock republishes the roster every 50 ms, so a settle costs a small
    /// number of poll cycles. One second is twenty of them — ample headroom on a loaded
    /// runner, and still tight in absolute terms: a roster that cannot bring a row it
    /// has already published into the viewport within a second is exactly the
    /// unresponsiveness this test exists to catch.
    ///
    /// A more generous bound would be safer against flakes and WORSE as a test: five
    /// seconds would pass a roster that is visibly janky to a human.
    private let rosterSettleTimeout: TimeInterval = 1.0

    /// Cold simulator launch gets a separate budget from gesture response. The frozen
    /// production head never made the top row hittable even with a measured ten-second
    /// wait; the fixed head reached it on retry but missed the old one-second cold-start
    /// sample. Keeping movement at one second preserves the responsiveness gate without
    /// making simulator startup the behavior under test.
    private let initialRosterLayoutTimeout: TimeInterval = 10.0

    func testRosterStaysResponsiveWhileRefreshesReorderRows() {
        let app = XCUIApplication.launched(mock: "rosterstress")

        let scroll = app.scrollViews["agent-roster-scroll"]
        XCTAssertTrue(scroll.exists(within: 5), "agent roster scroll view did not appear")
        // Query the actual row Buttons. Their Text children exist in the accessibility
        // tree but are not independently hittable because the parent owns the gesture.
        let topMarker = app.buttons["agent-row-stress:top"]
        let bottomMarker = app.buttons["agent-row-stress:bottom"]
        let deferredMarker = app.buttons["agent-row-stress:deferred"]
        let coalescingViolation = app.buttons["agent-row-stress:coalescing-violation"]
        let eagerStackReceipt = app.buttons["agent-row-stress:eager-stack"]
        let armStress = app.buttons["roster-stress-arm"]
        let stablePhase = app.staticTexts["stable-pre-scroll-phase-marker"]
        let activePhaseOne = app.staticTexts["scroll-refresh-phase-1-marker"]
        let activePhaseTwo = app.staticTexts["scroll-refresh-phase-2-marker"]
        let phaseOneRedistributionRow = app.buttons["agent-row-stress:p000"]
        let phaseTwoRedistributionRow = app.buttons["agent-row-stress:p001"]
        XCTAssertTrue(topMarker.exists(within: 5), "stress roster did not load")
        if !topMarker.waitForHittable(timeout: initialRosterLayoutTimeout) {
            // The first cold launch can expose the hierarchy before its initial scroll
            // offset is usable. Establish the test's top-of-list precondition with real
            // gestures instead of assuming the initial position. The stress driver is
            // not armed yet, so these gestures cannot change the roster. A frozen list
            // still fails because they cannot make its already-present row hittable.
            attach(app, "roster-cold-launch-before-top-normalization")
            let bottomWasHittable = bottomMarker.isHittable
            for _ in 0..<6 { scroll.swipeDown() }
            XCTAssertTrue(
                topMarker.waitForHittable(timeout: rosterSettleTimeout),
                "top marker stayed unreachable after six downward swipes; "
                    + "bottom hittable before normalization: \(bottomWasHittable)"
            )
        }
        XCTAssertTrue(
            eagerStackReceipt.exists(within: 3),
            "stress scenario did not render the eager Mac roster stack"
        )
        XCTAssertFalse(deferredMarker.exists, "deferred marker appeared before scrolling began")
        XCTAssertTrue(stablePhase.exists, "stable pre-scroll roster phase was absent")
        XCTAssertFalse(activePhaseOne.exists || activePhaseTwo.exists, "roster phase changed before scrolling began")
        XCTAssertEqual(agentCount(scroll), 84, "stable rendered roster cardinality was wrong")
        XCTAssertTrue(
            phaseOneRedistributionRow.exists(within: 3),
            "phase-one receipt row did not resolve in the stable roster"
        )
        XCTAssertTrue(
            phaseTwoRedistributionRow.exists(within: 3),
            "phase-two receipt row did not resolve in the stable roster"
        )
        XCTAssertEqual(
            phaseOneRedistributionRow.value as? String,
            "needs you",
            "phase-one receipt row did not begin in needs-you"
        )
        XCTAssertEqual(
            phaseTwoRedistributionRow.value as? String,
            "working",
            "phase-two receipt row did not begin in working"
        )
        XCTAssertFalse(coalescingViolation.exists, "roster published while scrolling before the gesture began")
        XCTAssertTrue(armStress.exists(within: 3), "roster stress arm control was absent")
        armStress.tap()
        // THE STRESS IS ARMED, OR NOTHING BELOW MEANS ANYTHING. An arm tap the system
        // gesture gate cancelled (CI 39116174699) left the driver serving the stable
        // roster for the whole scroll, and the test only noticed 60 s later, as a
        // deferred row that was never promoted. Confirm the arm action ran here, where
        // the failure names its real cause.
        XCTAssertTrue(poll(3, every: 0.25) { (armStress.value as? String) == "armed" },
                      "the roster stress arm tap did not reach its action (value: \(armStress.value ?? "nil"))")

        for _ in 0..<18 {
            scroll.swipeUp()
        }
        XCTAssertTrue(
            topMarker.waitForNotHittable(timeout: rosterSettleTimeout),
            "upward swipes did not move the initial row off-screen within \(rosterSettleTimeout)s"
        )
        XCTAssertTrue(bottomMarker.exists(within: 3), "bottom marker was absent from the roster")
        XCTAssertTrue(
            bottomMarker.waitForHittable(timeout: rosterSettleTimeout),
            "upward swipes did not reach different visible content within \(rosterSettleTimeout)s"
        )

        // Return to the top without involving the software keyboard. A tap made while
        // momentum is still settling can be consumed only to stop deceleration, leaving
        // a text field visible but unfocused and making `typeText` fail for the wrong
        // reason. The final snapshot pins its sentinel first, so reaching that row is a
        // direct receipt for both continued gesture handling and deferred-state catch-up.
        for _ in 0..<18 {
            scroll.swipeDown()
        }

        XCTAssertTrue(
            topMarker.waitForHittable(timeout: rosterSettleTimeout),
            "downward swipes did not return to the original visible content within \(rosterSettleTimeout)s"
        )
        XCTAssertTrue(
            deferredMarker.exists(within: 3),
            "scroll-time snapshot was not promoted after returning to idle"
        )
        XCTAssertTrue(
            deferredMarker.waitForHittable(timeout: rosterSettleTimeout),
            "deferred marker was not visible after returning to the top"
        )
        XCTAssertFalse(stablePhase.exists, "stable pre-scroll phase survived scroll-time promotion")
        let activePhase: Int
        if activePhaseOne.exists(within: rosterSettleTimeout) {
            activePhase = 1
        } else if activePhaseTwo.exists(within: rosterSettleTimeout) {
            activePhase = 2
        } else {
            activePhase = 0
        }
        XCTAssertNotEqual(activePhase, 0, "no actual scroll-refresh phase was promoted after returning to idle")

        XCTAssertNotNil(
            waitForAgentCount(scroll, allowed: [86, 87], timeout: rosterSettleTimeout),
            "promoted roster cardinality did not change from 84 to 86 or 87"
        )
        let redistributed: Bool
        switch activePhase {
        case 1:
            redistributed = phaseOneRedistributionRow.exists(within: rosterSettleTimeout)
                && (phaseOneRedistributionRow.value as? String) == "working"
        case 2:
            redistributed = phaseTwoRedistributionRow.exists(within: rosterSettleTimeout)
                && (phaseTwoRedistributionRow.value as? String) == "needs you"
        default:
            redistributed = false
        }
        XCTAssertTrue(redistributed, "no existing row changed status section after scroll-time promotion")
        XCTAssertFalse(
            coalescingViolation.exists,
            "a refresh changed the displayed roster while scrolling instead of being coalesced"
        )

        attach(app, "roster-responsive-after-refresh-stress")
    }

    private func agentCount(_ element: XCUIElement) -> Int? {
        guard let value = element.value as? String,
              let firstField = value.split(separator: " ").first else { return nil }
        return Int(firstField)
    }

    private func waitForAgentCount(
        _ element: XCUIElement,
        allowed: Set<Int>,
        timeout: TimeInterval
    ) -> Int? {
        var observed: Int?
        _ = poll(timeout, every: 0.1) {
            observed = agentCount(element)
            return observed.map(allowed.contains) ?? false
        }
        return observed.flatMap { allowed.contains($0) ? $0 : nil }
    }
}
