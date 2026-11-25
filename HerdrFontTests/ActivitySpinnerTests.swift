import XCTest
@testable import Herdr

/// The activity spinner (`ActivitySpinner`) steps round only where it can be seen and motion is
/// wanted: Reduce Motion, an off-screen place (`statusMotion` off) and UI tests that hold motion
/// still each leave the wheel at rest.
final class ActivitySpinnerTests: XCTestCase {
    func testItTurnsOnScreenWithMotion() {
        XCTAssertTrue(ActivitySpinner.turns(statusMotion: true, reduceMotion: false, testsHoldStill: false))
    }

    func testReduceMotionHoldsItStill() {
        XCTAssertFalse(ActivitySpinner.turns(statusMotion: true, reduceMotion: true, testsHoldStill: false),
                       "Reduce Motion draws the wheel at rest")
    }

    func testItHoldsStillOffScreenAndInStillUITests() {
        XCTAssertFalse(ActivitySpinner.turns(statusMotion: false, reduceMotion: false, testsHoldStill: false),
                       "a hidden spinner must not drive the clock")
        XCTAssertFalse(ActivitySpinner.turns(statusMotion: true, reduceMotion: false, testsHoldStill: true),
                       "UI tests with animations off must reach idle")
    }
}
